import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct MLXStoreTests {
    @MainActor
    @Test func delayedOldRefreshCannotReplaceNewConfiguration() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: true)
        let store = MLXStore(service: service, defaults: defaults)
        await service.waitForInitialReads()

        await store.updateExecutableOverride("/tmp/mlx-new-executable")
        #expect(store.capability.available)
        #expect(store.capability.mlxLMVersion == "new-config")
        #expect(store.models.map(\.id) == ["new-model"])

        await service.releaseInitialReads()
        for _ in 0..<10 { await Task.yield() }

        #expect(store.capability.mlxLMVersion == "new-config")
        #expect(store.models.map(\.id) == ["new-model"])
    }

    @MainActor
    @Test func modelChatIsBoundedAndWindowScoped() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" }
        await store.refresh()
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_080, maxTokens: 64, temperature: 0)
        let server = try #require(store.runningServers.first)
        let sceneA = "window-a"
        let sceneB = "window-b"

        for index in 0..<23 {
            await store.sendChat(serverID: server.id, sceneID: sceneA, text: "prompt \(index)", maxTokens: 32, temperature: 0)
        }

        let turns = store.conversation(serverID: server.id, sceneID: sceneA)
        #expect(turns.count <= 40)
        #expect(turns.reduce(0) { $0 + $1.content.utf8.count } <= 96_000)
        #expect(!turns.isEmpty)
        #expect(store.conversation(serverID: server.id, sceneID: sceneB).isEmpty)

        let recordedRequests = await service.recordedChatRequests()
        let rollingWindowRequest = try #require(recordedRequests.dropFirst(20).first)
        #expect(rollingWindowRequest.count <= 40)
        #expect(rollingWindowRequest.reduce(0) { $0 + $1.content.utf8.count } <= 96_000)
        #expect(rollingWindowRequest.first?.role == .user)
        #expect(rollingWindowRequest.enumerated().allSatisfy { index, message in
            message.role == (index.isMultiple(of: 2) ? .user : .assistant)
        })

        let keysBefore = Set(defaults.dictionaryRepresentation().keys)
        #expect(!keysBefore.contains(where: { $0.localizedCaseInsensitiveContains("chat") || $0.localizedCaseInsensitiveContains("prompt") }))
        await store.shutdown()
    }

    @MainActor
    @Test func chatContextEvictionPreservesCompleteExchangesUnderBytePressure() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        await store.refresh()
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_088, maxTokens: 64, temperature: 0)
        let server = try #require(store.runningServers.first)
        let sceneID = "byte-pressure-history"

        for index in 0..<3 {
            await store.sendChat(serverID: server.id, sceneID: sceneID, text: String(repeating: "p", count: 1_000) + "\(index)", maxTokens: 32, temperature: 0)
        }
        await service.returnNextChatReply(String(repeating: "r", count: 92_000))
        await store.sendChat(serverID: server.id, sceneID: sceneID, text: String(repeating: "p", count: 1_000) + "large reply", maxTokens: 32, temperature: 0)
        await store.sendChat(serverID: server.id, sceneID: sceneID, text: "after pressure", maxTokens: 32, temperature: 0)

        let requests = await service.recordedChatRequests()
        let afterPressureRequest = try #require(requests.last)
        #expect(afterPressureRequest.count <= 40)
        #expect(afterPressureRequest.reduce(0) { $0 + $1.content.utf8.count } <= 96_000)
        #expect(afterPressureRequest.first?.role == .user)
        #expect(afterPressureRequest.enumerated().allSatisfy { index, message in
            message.role == (index.isMultiple(of: 2) ? .user : .assistant)
        })
        await store.shutdown()
    }

    @MainActor
    @Test func staleServerSnapshotDoesNotOverwriteNewerEvent() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        await store.refresh()
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_081, maxTokens: 64, temperature: 0)
        let starting = try #require(store.runningServers.first)

        await service.emitState(for: starting.id, state: .starting)
        try await waitUntil { store.runningServers.first(where: { $0.id == starting.id })?.state == .starting }
        await service.holdNextServerSnapshot()
        let refresh = Task { await store.refresh() }
        await service.waitForHeldServerSnapshot()
        await service.emitState(for: starting.id, state: .running)
        try await waitUntil { store.runningServers.first(where: { $0.id == starting.id })?.state == .running }
        await service.releaseHeldServerSnapshot()
        await refresh.value

        #expect(store.runningServers.first(where: { $0.id == starting.id })?.state == .running)
        await store.shutdown()
    }

    @MainActor
    @Test func ownedModelAndServerControlsSurviveManagedDirectoryChange() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_084, maxTokens: 64, temperature: 0)
        let session = try #require(store.runningServers.first)
        let newDirectory = URL(fileURLWithPath: "/tmp/other-mlx-models", isDirectory: true)
        await service.hideModelWhenManagedDirectoryIs(newDirectory)

        await store.updateManagedModelsDirectory(newDirectory)

        #expect(store.models.contains(where: { $0.id == model.id }))
        #expect(store.isModelInUse(model.id))
        #expect(store.runningServers.first(where: { $0.id == session.id })?.state == .running)
        #expect(store.runningServers.first(where: { $0.id == session.id })?.port == 18_084)

        try await store.stopServer(session)

        #expect(!store.isModelInUse(model.id))
        #expect(!store.models.contains(where: { $0.id == model.id }))
        await store.shutdown()
    }

    @MainActor
    @Test func serverStateAndChatArePrunedWhenServiceForgetsSession() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_089, maxTokens: 64, temperature: 0)
        let session = try #require(store.runningServers.first)
        let sceneID = "forgotten-server-window"

        await service.waitForServerSubscription(id: session.id)
        await service.emitOutput(for: session.id, text: "useful server output")
        try await waitUntil { (store.serverOutput[session.id] ?? "").contains("useful server output") }
        await store.sendChat(serverID: session.id, sceneID: sceneID, text: "keep useful history", maxTokens: 32, temperature: 0)
        #expect(!store.conversation(serverID: session.id, sceneID: sceneID).isEmpty)

        await service.holdNextChat()
        let request = Task { @MainActor in
            await store.sendChat(serverID: session.id, sceneID: sceneID, text: "cancel when forgotten", maxTokens: 32, temperature: 0)
        }
        await service.waitForHeldChat()
        try await waitUntil { store.isChatStreaming(for: session.id, sceneID: sceneID) }

        await service.forgetServer(id: session.id)
        await store.refresh()

        let sessionWasPruned = !store.runningServers.contains(where: { $0.id == session.id })
        let outputWasPruned = store.serverOutput[session.id] == nil
        let conversationWasPruned = store.conversation(serverID: session.id, sceneID: sceneID).isEmpty
        let chatErrorWasPruned = store.chatError(serverID: session.id, sceneID: sceneID) == nil
        let chatWasCancelled = !store.isChatStreaming(for: session.id, sceneID: sceneID)
        #expect(sessionWasPruned)
        #expect(outputWasPruned)
        #expect(conversationWasPruned)
        #expect(chatErrorWasPruned)
        #expect(chatWasCancelled)

        // Unblock the mock even when the regression leaves its child chat task alive,
        // so the red test reports the failed expectation instead of hanging.
        await service.finishHeldChat()
        await request.value
        await service.waitForChatTermination()
        await store.shutdown()
    }

    @MainActor
    @Test func lateEventCannotResurrectForgottenSession() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_090, maxTokens: 64, temperature: 0)
        let session = try #require(store.runningServers.first)

        await service.forgetServer(id: session.id)
        await store.refresh()
        #expect(!store.runningServers.contains(where: { $0.id == session.id }))

        await service.emitLateState(for: session, state: .running)
        for _ in 0..<10 { await Task.yield() }
        #expect(!store.runningServers.contains(where: { $0.id == session.id }))
        await store.shutdown()
    }

    @MainActor
    @Test func laterSuccessfulStartPrunesNaturallyFailedSessionState() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        let model = try #require(store.models.first)

        let ports: [UInt16] = [18_093, 18_094, 18_095]
        try await store.startServer(for: model, port: ports[0], maxTokens: 64, temperature: 0)
        var current = try #require(store.runningServers.first(where: { $0.port == ports[0] }))
        for replacementPort in ports.dropFirst() {
            await service.waitForServerSubscription(id: current.id)
            await service.emitOutput(for: current.id, text: "failure output on \(current.port)")
            try await waitUntil { (store.serverOutput[current.id] ?? "").contains("failure output") }
            await store.sendChat(serverID: current.id, sceneID: "failed-model-window", text: "history for \(current.port)", maxTokens: 32, temperature: 0)

            await service.emitState(for: current.id, state: .failed)
            try await waitUntil { store.runningServers.first(where: { $0.id == current.id })?.state == .failed }
            try await store.startServer(for: model, port: replacementPort, maxTokens: 64, temperature: 0)

            let failedSessionWasPruned = !store.runningServers.contains(where: { $0.id == current.id })
            let failedOutputWasPruned = store.serverOutput[current.id] == nil
            let failedChatWasPruned = store.conversation(serverID: current.id, sceneID: "failed-model-window").isEmpty
            #expect(failedSessionWasPruned)
            #expect(failedOutputWasPruned)
            #expect(failedChatWasPruned)
            current = try #require(store.runningServers.first(where: { $0.port == replacementPort }))
        }
        await store.shutdown()
    }

    @MainActor
    @Test func lateEventDuringSnapshotCannotRestoreForgottenSession() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_091, maxTokens: 64, temperature: 0)
        let session = try #require(store.runningServers.first)
        await service.waitForServerSubscription(id: session.id)

        await service.forgetServer(id: session.id)
        await service.holdNextServerSnapshot()
        let refresh = Task { await store.refresh() }
        await service.waitForHeldServerSnapshot()
        await service.emitLateState(for: session, state: .starting)
        try await waitUntil { store.runningServers.first(where: { $0.id == session.id })?.state == .starting }
        await service.releaseHeldServerSnapshot()
        await refresh.value

        let sessionStayedPruned = !store.runningServers.contains(where: { $0.id == session.id })
        #expect(sessionStayedPruned)
        await store.shutdown()
    }

    @MainActor
    @Test func discardingSceneClearsOnlyItsChatAndCancelsItsRequest() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_092, maxTokens: 64, temperature: 0)
        let session = try #require(store.runningServers.first)
        let closingScene = "closed-window"
        let retainedScene = "other-window"

        await service.failNextChat(after: 0)
        await store.sendChat(serverID: session.id, sceneID: closingScene, text: "closing history", maxTokens: 32, temperature: 0)
        await service.failNextChat(after: 0)
        await store.sendChat(serverID: session.id, sceneID: retainedScene, text: "retained history", maxTokens: 32, temperature: 0)
        #expect(store.chatError(serverID: session.id, sceneID: closingScene) != nil)
        #expect(store.conversation(serverID: session.id, sceneID: retainedScene).count >= 2)
        #expect(store.chatError(serverID: session.id, sceneID: retainedScene) != nil)

        await service.holdNextChat()
        let request = Task { @MainActor in
            await store.sendChat(serverID: session.id, sceneID: closingScene, text: "cancel on close", maxTokens: 32, temperature: 0)
        }
        await service.waitForHeldChat()
        try await waitUntil { store.isChatStreaming(for: session.id, sceneID: closingScene) }
        store.discardChatState(forScene: closingScene)

        let closingHistoryCleared = store.conversation(serverID: session.id, sceneID: closingScene).isEmpty
        let closingErrorCleared = store.chatError(serverID: session.id, sceneID: closingScene) == nil
        let closingRequestStoppedImmediately = !store.isChatStreaming(for: session.id, sceneID: closingScene)
        let retainedHistoryPreserved = store.conversation(serverID: session.id, sceneID: retainedScene).count >= 2
        let retainedErrorPreserved = store.chatError(serverID: session.id, sceneID: retainedScene) != nil
        #expect(closingHistoryCleared)
        #expect(closingErrorCleared)
        #expect(closingRequestStoppedImmediately)
        #expect(retainedHistoryPreserved)
        #expect(retainedErrorPreserved)

        await service.finishHeldChat()
        await request.value
        await service.waitForChatTermination()
        try await waitUntil { !store.isChatStreaming(for: session.id, sceneID: closingScene) }
        await store.shutdown()
    }

    @MainActor
    @Test func chatStreamCancelsWhenItsWindowLeavesThePlayground() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        await store.refresh()
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_082, maxTokens: 64, temperature: 0)
        let server = try #require(store.runningServers.first)
        let sceneID = "closing-window"

        await service.holdNextChat()
        let request = Task { @MainActor in
            await store.sendChat(serverID: server.id, sceneID: sceneID, text: "wait for cancellation", maxTokens: 32, temperature: 0)
        }
        await service.waitForHeldChat()
        try await waitUntil { store.isChatStreaming(for: server.id, sceneID: sceneID) }
        store.cancelChats(forScene: sceneID)
        await request.value
        await service.waitForChatTermination()

        #expect(!store.isChatStreaming(for: server.id, sceneID: sceneID))
        #expect(store.conversation(serverID: server.id, sceneID: sceneID).first?.role == .user)
        await store.shutdown()
    }

    @MainActor
    @Test func stoppedChatKeepsPairedContextAndOldTaskCannotClearFollowup() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_096, maxTokens: 64, temperature: 0)
        let session = try #require(store.runningServers.first)
        let sceneID = "stop-followup"

        await service.holdNextChat()
        let firstRequest = Task { @MainActor in
            await store.sendChat(serverID: session.id, sceneID: sceneID, text: "first prompt", maxTokens: 32, temperature: 0)
        }
        await service.waitForHeldChat(prompt: "first prompt")
        store.cancelChat(serverID: session.id, sceneID: sceneID)

        let historyAfterStop = store.conversation(serverID: session.id, sceneID: sceneID)
        let stoppedExchangeIsPaired = historyAfterStop.count == 2
            && historyAfterStop[0].role == .user
            && historyAfterStop[1].role == .assistant
            && historyAfterStop.allSatisfy { !$0.content.isEmpty }
        #expect(stoppedExchangeIsPaired)

        await service.holdNextChat()
        let followupRequest = Task { @MainActor in
            await store.sendChat(serverID: session.id, sceneID: sceneID, text: "follow-up prompt", maxTokens: 32, temperature: 0)
        }
        await service.waitForHeldChat(prompt: "follow-up prompt")
        await service.waitForChatTermination(prompt: "first prompt")

        let followupStillStreaming = store.isChatStreaming(for: session.id, sceneID: sceneID)
        let requests = await service.recordedChatRequests()
        let followupContext = try #require(requests.last)
        let contextIsPaired = followupContext.map(\.role) == [.user, .assistant, .user]
            && followupContext.allSatisfy { !$0.content.isEmpty }
            && followupContext[0].content == "first prompt"
            && followupContext[1].content == "Generation stopped."
        #expect(followupStillStreaming)
        #expect(contextIsPaired)

        await service.finishHeldChat(prompt: "follow-up prompt")
        await followupRequest.value
        await firstRequest.value
        await store.shutdown()
    }

    @MainActor
    @Test func oversizedModelReplyIsRetainedWithExplicitLimitError() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        await store.refresh()
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_083, maxTokens: 64, temperature: 0)
        let server = try #require(store.runningServers.first)
        await service.useOversizedNextChatReply()

        await store.sendChat(serverID: server.id, sceneID: "large-reply", text: "return a long response", maxTokens: 32, temperature: 0)

        let turns = store.conversation(serverID: server.id, sceneID: "large-reply")
        #expect(turns.last?.role == .assistant)
        #expect(turns.last?.content.contains("Response truncated at 96 KB") == true)
        #expect(turns.reduce(0) { $0 + $1.content.utf8.count } <= 96_000)
        #expect(store.chatError(serverID: server.id, sceneID: "large-reply")?.contains("96 KB") == true)
        await store.shutdown()
    }

    @MainActor
    @Test func chatCanRecoverWhenFirstRequestFailsBeforeProducingAToken() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        await store.refresh()
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_085, maxTokens: 64, temperature: 0)
        let server = try #require(store.runningServers.first)
        let sceneID = "recover-before-first-token"
        await service.failNextChat(after: 0)

        await store.sendChat(serverID: server.id, sceneID: sceneID, text: "first prompt", maxTokens: 32, temperature: 0)
        #expect(store.chatError(serverID: server.id, sceneID: sceneID) != nil)
        #expect(!store.conversation(serverID: server.id, sceneID: sceneID).contains(where: { $0.role == .assistant && $0.content.isEmpty }))

        await store.sendChat(serverID: server.id, sceneID: sceneID, text: "try again", maxTokens: 32, temperature: 0)

        let requests = await service.recordedChatRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.allSatisfy { !$0.content.isEmpty } })
        #expect(requests.last?.first?.content == "first prompt")
        #expect(requests.last?.last?.content == "try again")
        #expect(requests.last?.contains(where: { $0.role == .assistant && $0.content.contains("failed before producing") }) == true)
        #expect(store.conversation(serverID: server.id, sceneID: sceneID).last?.content == "sample answer")
        await store.shutdown()
    }

    @MainActor
    @Test func partialChatFailureKeepsUsefulReplyAndAllowsFollowup() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        await store.refresh()
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_086, maxTokens: 64, temperature: 0)
        let server = try #require(store.runningServers.first)
        let sceneID = "recover-after-partial-reply"
        await service.failNextChat(after: 1)

        await store.sendChat(serverID: server.id, sceneID: sceneID, text: "partial prompt", maxTokens: 32, temperature: 0)
        let firstTurns = store.conversation(serverID: server.id, sceneID: sceneID)
        #expect(firstTurns.last?.role == .assistant)
        #expect(firstTurns.last?.content == "partial reply")
        #expect(store.chatError(serverID: server.id, sceneID: sceneID) != nil)

        await store.sendChat(serverID: server.id, sceneID: sceneID, text: "follow up", maxTokens: 32, temperature: 0)

        let requests = await service.recordedChatRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.allSatisfy { !$0.content.isEmpty } })
        #expect(requests.last?.last?.content == "follow up")
        #expect(requests.last?.map(\.content) == ["partial prompt", "partial reply", "follow up"])
        #expect(store.conversation(serverID: server.id, sceneID: sceneID).last?.content == "sample answer")
        await store.shutdown()
    }

    @MainActor
    @Test func emptySuccessfulChatStreamDoesNotLeaveAnEmptyAssistantTurn() async throws {
        let suiteName = "ContainerDeskTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TestMLXModelService(suspendInitialReads: false)
        let store = MLXStore(service: service, defaults: defaults)
        try await waitUntil { store.models.first?.id == "model" && store.capability.available }
        await store.refresh()
        let model = try #require(store.models.first)
        try await store.startServer(for: model, port: 18_087, maxTokens: 64, temperature: 0)
        let server = try #require(store.runningServers.first)
        await service.returnEmptyNextChat()

        await store.sendChat(serverID: server.id, sceneID: "empty-success", text: "prompt", maxTokens: 32, temperature: 0)

        #expect(!store.conversation(serverID: server.id, sceneID: "empty-success").contains(where: { $0.role == .assistant && $0.content.isEmpty }))
        await store.sendChat(serverID: server.id, sceneID: "empty-success", text: "next prompt", maxTokens: 32, temperature: 0)
        let requests = await service.recordedChatRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.allSatisfy { !$0.content.isEmpty } })
        #expect(requests.last?.last?.content == "next prompt")
        await store.shutdown()
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the MLX store condition.")
    }
}

private actor TestMLXModelService: MLXModelService {
    private var configuration = MLXConfiguration()
    private var hiddenModelManagedDirectory: URL?
    private let suspendInitialReads: Bool
    private var capabilityCalls = 0
    private var listCalls = 0
    private var initialReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var initialCapability: CheckedContinuation<MLXCapability, Never>?
    private var initialModels: CheckedContinuation<[MLXModelRecord], any Error>?
    private var serverSessions: [UUID: MLXServerSession] = [:]
    private var serverEventContinuations: [UUID: AsyncStream<MLXServerEvent>.Continuation] = [:]
    private var serverSubscriptionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var shouldHoldNextSnapshot = false
    private var heldSnapshot: CheckedContinuation<[MLXServerSession], Never>?
    private var heldSnapshotValue: [MLXServerSession]?
    private var heldSnapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldHoldChat = false
    private var shouldReturnOversizedChat = false
    private var shouldReturnEmptyChat = false
    private var nextChatFailureAfterTokenCount: Int?
    private var nextChatReply: String?
    private var chatRequests: [[MLXChatMessage]] = []
    private var heldChatContinuations: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var heldChatWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var anyHeldChatWaiters: [CheckedContinuation<Void, Never>] = []
    private var chatTerminationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var anyChatTerminationWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminatedChatPrompts: Set<String> = []

    init(suspendInitialReads: Bool) { self.suspendInitialReads = suspendInitialReads }

    func configure(_ configuration: MLXConfiguration) async { self.configuration = configuration }

    func hideModelWhenManagedDirectoryIs(_ directory: URL) {
        hiddenModelManagedDirectory = directory.standardizedFileURL
    }

    func capability() async -> MLXCapability {
        capabilityCalls += 1
        if suspendInitialReads, capabilityCalls == 1 {
            return await withCheckedContinuation { continuation in
                initialCapability = continuation
                signalInitialReadsIfReady()
            }
        }
        let version = configuration.executableOverride == nil ? "default-config" : "new-config"
        return MLXCapability(available: true, mlxLMVersion: version, executableURL: configuration.executableOverride)
    }

    func listLocalModels() async throws -> [MLXModelRecord] {
        listCalls += 1
        if suspendInitialReads, listCalls == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                initialModels = continuation
                signalInitialReadsIfReady()
            }
        }
        if configuration.managedModelsDirectory == hiddenModelManagedDirectory { return [] }
        return [model(id: configuration.executableOverride == nil ? "model" : "new-model")]
    }

    func validateModelDirectory(_ url: URL) async throws -> MLXModelRecord { model(id: "import:\(url.path)") }

    func download(_ request: MLXModelDownloadRequest) async -> AsyncThrowingStream<MLXDownloadEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func startServer(modelID: String, options: MLXServerOptions) async throws -> MLXServerSession {
        let retiredIDs = serverSessions.values
            .filter { $0.modelID == modelID && ($0.state == .stopped || $0.state == .failed) }
            .map(\.id)
        for id in retiredIDs {
            serverSessions[id] = nil
            serverEventContinuations.removeValue(forKey: id)?.finish()
        }
        let session = MLXServerSession(id: UUID(), modelID: modelID, port: options.port, state: .running)
        serverSessions[session.id] = session
        serverEventContinuations[session.id]?.yield(.state(session))
        return session
    }

    func stopServer(id: UUID) async throws {
        guard let old = serverSessions[id] else { throw MLXError.unknownServer }
        let stopped = MLXServerSession(id: old.id, modelID: old.modelID, port: old.port, state: .stopped)
        serverSessions[id] = stopped
        serverEventContinuations[id]?.yield(.state(stopped))
    }

    func serverEvents(id: UUID) async -> AsyncStream<MLXServerEvent> {
        let (stream, continuation) = AsyncStream<MLXServerEvent>.makeStream()
        serverEventContinuations[id] = continuation
        let subscriptionWaiters = serverSubscriptionWaiters.removeValue(forKey: id) ?? []
        subscriptionWaiters.forEach { $0.resume() }
        if let current = serverSessions[id] { continuation.yield(.state(current)) }
        return stream
    }

    func waitForServerSubscription(id: UUID) async {
        guard serverEventContinuations[id] == nil else { return }
        await withCheckedContinuation { serverSubscriptionWaiters[id, default: []].append($0) }
    }

    func ownedServers() async -> [MLXServerSession] {
        let snapshot = Array(serverSessions.values)
        guard shouldHoldNextSnapshot else { return snapshot }
        shouldHoldNextSnapshot = false
        heldSnapshotValue = snapshot
        return await withCheckedContinuation { continuation in
            heldSnapshot = continuation
            let waiters = heldSnapshotWaiters
            heldSnapshotWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func trashManagedModel(id: String) async throws { }
    func forgetImportedModel(at url: URL) async { }

    func chat(serverID: UUID, messages: [MLXChatMessage], options: MLXChatOptions) async -> AsyncThrowingStream<String, Error> {
        chatRequests.append(messages)
        let hasInvalidContent = messages.contains { $0.content.isEmpty }
        if hasInvalidContent {
            return AsyncThrowingStream { $0.finish(throwing: TestChatError.emptyMessage) }
        }
        if shouldHoldChat {
            shouldHoldChat = false
            let prompt = messages.last(where: { $0.role == .user })?.content ?? ""
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            heldChatContinuations[prompt] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.signalChatTermination(prompt: prompt) }
            }
            let waiters = heldChatWaiters.removeValue(forKey: prompt) ?? []
            waiters.forEach { $0.resume() }
            let anyWaiters = anyHeldChatWaiters
            anyHeldChatWaiters.removeAll()
            anyWaiters.forEach { $0.resume() }
            return stream
        }
        if shouldReturnOversizedChat {
            shouldReturnOversizedChat = false
            return AsyncThrowingStream { continuation in
                continuation.yield(String(repeating: "x", count: 100_000))
                continuation.finish()
            }
        }
        if shouldReturnEmptyChat {
            shouldReturnEmptyChat = false
            return AsyncThrowingStream { $0.finish() }
        }
        if let tokenCount = nextChatFailureAfterTokenCount {
            nextChatFailureAfterTokenCount = nil
            return AsyncThrowingStream { continuation in
                if tokenCount > 0 { continuation.yield("partial reply") }
                continuation.finish(throwing: TestChatError.requestFailed)
            }
        }
        if let reply = nextChatReply {
            nextChatReply = nil
            return AsyncThrowingStream { continuation in
                continuation.yield(reply)
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("sample answer")
            continuation.finish()
        }
    }

    func stopAllOwnedServers() async { }
    func shutdown() async { }

    func waitForInitialReads() async {
        if initialCapability != nil, initialModels != nil { return }
        await withCheckedContinuation { initialReadWaiters.append($0) }
    }

    func releaseInitialReads() {
        initialCapability?.resume(returning: MLXCapability(available: true, mlxLMVersion: "old-config"))
        initialCapability = nil
        initialModels?.resume(returning: [model(id: "old-model")])
        initialModels = nil
    }

    func holdNextServerSnapshot() { shouldHoldNextSnapshot = true }

    func holdNextChat() { shouldHoldChat = true }
    func useOversizedNextChatReply() { shouldReturnOversizedChat = true }
    func failNextChat(after tokenCount: Int) { nextChatFailureAfterTokenCount = tokenCount }
    func returnEmptyNextChat() { shouldReturnEmptyChat = true }
    func returnNextChatReply(_ reply: String) { nextChatReply = reply }
    func finishHeldChat() {
        let continuations = Array(heldChatContinuations.values)
        continuations.forEach { $0.finish() }
    }
    func finishHeldChat(prompt: String) { heldChatContinuations[prompt]?.finish() }
    func recordedChatRequests() -> [[MLXChatMessage]] { chatRequests }

    func waitForHeldChat() async {
        guard heldChatContinuations.isEmpty else { return }
        await withCheckedContinuation { anyHeldChatWaiters.append($0) }
    }

    func waitForHeldChat(prompt: String) async {
        guard heldChatContinuations[prompt] == nil else { return }
        await withCheckedContinuation { heldChatWaiters[prompt, default: []].append($0) }
    }

    func waitForChatTermination(prompt: String? = nil) async {
        if let prompt, terminatedChatPrompts.contains(prompt) { return }
        if prompt == nil, !terminatedChatPrompts.isEmpty { return }
        await withCheckedContinuation {
            if let prompt { chatTerminationWaiters[prompt, default: []].append($0) }
            else { anyChatTerminationWaiters.append($0) }
        }
    }

    func waitForHeldServerSnapshot() async {
        guard heldSnapshot == nil else { return }
        await withCheckedContinuation { heldSnapshotWaiters.append($0) }
    }

    func releaseHeldServerSnapshot() {
        heldSnapshot?.resume(returning: heldSnapshotValue ?? Array(serverSessions.values))
        heldSnapshot = nil
        heldSnapshotValue = nil
    }

    func emitState(for id: UUID, state: MLXServerState) {
        guard let old = serverSessions[id] else { return }
        let updated = MLXServerSession(id: old.id, modelID: old.modelID, port: old.port, state: state)
        serverSessions[id] = updated
        serverEventContinuations[id]?.yield(.state(updated))
    }

    func emitOutput(for id: UUID, text: String) {
        serverEventContinuations[id]?.yield(.output(text))
    }

    func finishServerEvents(for id: UUID) {
        serverEventContinuations.removeValue(forKey: id)?.finish()
    }

    func forgetServer(id: UUID) {
        serverSessions[id] = nil
        heldSnapshotValue?.removeAll(where: { $0.id == id })
    }

    func emitLateState(for session: MLXServerSession, state: MLXServerState) {
        let updated = MLXServerSession(id: session.id, modelID: session.modelID, port: session.port, state: state)
        serverEventContinuations[session.id]?.yield(.state(updated))
    }

    private func signalChatTermination(prompt: String) {
        heldChatContinuations[prompt] = nil
        terminatedChatPrompts.insert(prompt)
        let waiters = chatTerminationWaiters.removeValue(forKey: prompt) ?? []
        waiters.forEach { $0.resume() }
        let anyWaiters = anyChatTerminationWaiters
        anyChatTerminationWaiters.removeAll()
        anyWaiters.forEach { $0.resume() }
    }

    private func signalInitialReadsIfReady() {
        guard initialCapability != nil, initialModels != nil else { return }
        let waiters = initialReadWaiters
        initialReadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func model(id: String) -> MLXModelRecord {
        MLXModelRecord(id: id, displayName: id, path: URL(fileURLWithPath: "/tmp/\(id)"), source: .importedDirectory, diskBytes: 1, fileCount: 1)
    }
}

private enum TestChatError: LocalizedError {
    case emptyMessage
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .emptyMessage: "Chat request contained an empty message."
        case .requestFailed: "The test chat request failed."
        }
    }
}
