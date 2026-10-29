import Foundation
import Testing
@testable import ContainerDeskCore

@Suite(.serialized)
struct MLXModelServiceTests {
    @Test func startsOnlyOwnedLoopbackServerAndReplaysReadyState() async throws {
        let fixture = try makeServiceFixture(processBehavior: .holdServer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.service.validateModelDirectory(fixture.modelDirectory)
        await fixture.service.configure(MLXConfiguration(managedModelsDirectory: fixture.managed, importedModelDirectories: [fixture.modelDirectory]))
        let options = try MLXServerOptions(port: 18_321)
        let session = try await fixture.service.startServer(modelID: model.id, options: options)
        #expect(session.state == .starting)

        let eventStream = await fixture.service.serverEvents(id: session.id)
        var replayedRunning = false
        let deadline = Date.now.addingTimeInterval(3)
        while Date.now < deadline {
            let sessions = await fixture.service.ownedServers()
            if sessions.first(where: { $0.id == session.id })?.state == .running {
                replayedRunning = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replayedRunning)
        var iterator = eventStream.makeAsyncIterator()
        let firstEvent = await iterator.next()
        #expect(firstEvent == .state(MLXServerSession(id: session.id, modelID: model.id, port: options.port, state: .running, detail: "Listening on 127.0.0.1:\(options.port)")) || firstEvent == .state(session))

        let requests = fixture.factory.requests
        let arguments = try #require(requests.first?.arguments)
        #expect(arguments.contains("127.0.0.1"))
        #expect(arguments.contains(model.path.path))
        #expect(arguments.contains(String(options.port)))
        #expect(!arguments.contains("--trust-remote-code"))
        #expect(requests.first?.environment["HF_HUB_OFFLINE"] == "1")

        // Changing catalog roots must not detach the already-owned process from its controls.
        await fixture.service.configure(MLXConfiguration(managedModelsDirectory: fixture.root.appendingPathComponent("other-managed")))
        #expect(await fixture.service.ownedServers().first(where: { $0.id == session.id })?.state == .running)
        try await fixture.service.stopServer(id: session.id)
        #expect(await fixture.service.ownedServers().first(where: { $0.id == session.id })?.state == .stopped)
        await fixture.service.shutdown()
    }

    @Test func failedStartAndUnknownStopNeverClaimAnExternalServer() async throws {
        let fixture = try makeServiceFixture(processBehavior: .failServer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.service.validateModelDirectory(fixture.modelDirectory)
        await fixture.service.configure(MLXConfiguration(managedModelsDirectory: fixture.managed, importedModelDirectories: [fixture.modelDirectory]))
        await #expect(throws: MLXError.unknownServer) { try await fixture.service.stopServer(id: UUID()) }
        let session = try await fixture.service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_322))
        let events = await fixture.service.serverEvents(id: session.id)
        let terminalEvents = await collectUntilStreamFinishes(events, timeout: .seconds(2))
        #expect(terminalEvents != nil)
        #expect(terminalEvents?.contains { if case .state(let value) = $0 { return value.state == .failed }; return false } == true)
        await fixture.service.shutdown()
    }

    @Test func stoppedExecutionsReleaseMockHandlesAndInactiveHistoryStaysBounded() async throws {
        let fixture = try makeRetentionFixture(modelCount: 13)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var models: [MLXModelRecord] = []
        for directory in fixture.modelDirectories {
            models.append(try await fixture.service.validateModelDirectory(directory))
        }
        let activeSession = try await fixture.service.startServer(modelID: models[0].id, options: try MLXServerOptions(port: 18_329))
        try await waitUntilRunning(fixture.service, id: activeSession.id)

        var latest: MLXServerSession?
        for cycle in 0..<12 {
            let session = try await fixture.service.startServer(modelID: models[cycle + 1].id, options: try MLXServerOptions(port: 18_330 + UInt16(cycle)))
            try await waitUntilRunning(fixture.service, id: session.id)
            try await fixture.service.stopServer(id: session.id)
            latest = session

            // The factory keeps only weak references. A live weak token here means that the
            // service still owns the stopped execution (or its event monitor) after stop returns.
            #expect(fixture.factory.handleToken(at: cycle + 1) == nil)
            let sessions = await fixture.service.ownedServers()
            #expect(sessions.contains(where: { $0.id == activeSession.id && $0.state == .running }))
            #expect(sessions.filter { $0.state == .stopped || $0.state == .failed }.count <= 8)
        }

        let sessions = await fixture.service.ownedServers()
        let latestID = try #require(latest?.id)
        let latestSession = try #require(sessions.first(where: { $0.id == latestID }))
        #expect(latestSession.state == .stopped)
        #expect(latestSession.detail == "Stopped by ContainerDesk.")
        await fixture.service.shutdown()
    }

    @Test func oneActiveServerPerModelIsEnforcedUntilTheFirstStops() async throws {
        let fixture = try makeServiceFixture(processBehavior: .holdServer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.service.validateModelDirectory(fixture.modelDirectory)
        let first = try await fixture.service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_350))
        try await waitUntilRunning(fixture.service, id: first.id)
        let launchCount = fixture.factory.requests.count

        var duplicate: MLXServerSession?
        do {
            duplicate = try await fixture.service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_351))
        } catch MLXError.operationFailed {
            // Expected model-level exclusivity.
        } catch {
            Issue.record("A second active server failed with an unexpected error: \(error)")
        }
        if let duplicate {
            Issue.record("A second active server for the same model should be rejected.")
            try await fixture.service.stopServer(id: duplicate.id)
        }
        #expect(duplicate == nil)
        #expect(fixture.factory.requests.count == launchCount)
        await #expect(throws: MLXError.serverAlreadyOwnsPort(18_350)) {
            try await fixture.service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_350))
        }
        #expect(fixture.factory.requests.count == launchCount)

        try await fixture.service.stopServer(id: first.id)
        let replacement = try await fixture.service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_351))
        #expect(replacement.id != first.id)
        await fixture.service.shutdown()
    }

    @Test func stoppedServerSubscribersFinishWithFinalState() async throws {
        let fixture = try makeServiceFixture(processBehavior: .holdServer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.service.validateModelDirectory(fixture.modelDirectory)
        let session = try await fixture.service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_340))
        let stream = await fixture.service.serverEvents(id: session.id)

        try await fixture.service.stopServer(id: session.id)
        let events = await collectUntilStreamFinishes(stream, timeout: .seconds(2))
        #expect(events != nil)
        #expect(events?.contains { if case .state(let value) = $0 { return value.state == .stopped }; return false } == true)
        await fixture.service.shutdown()
    }

    @Test func successfulServerExitFinishesSubscribersWithStoppedState() async throws {
        let fixture = try makeServiceFixture(processBehavior: .successServer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = try await fixture.service.validateModelDirectory(fixture.modelDirectory)
        let session = try await fixture.service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_341))
        let stream = await fixture.service.serverEvents(id: session.id)

        let events = await collectUntilStreamFinishes(stream, timeout: .seconds(2))
        #expect(events != nil)
        #expect(events?.contains { if case .state(let value) = $0 { return value.state == .stopped && value.detail == "Server exited." }; return false } == true)
        #expect(fixture.factory.handleToken(at: 0) == nil)
        await fixture.service.shutdown()
    }

    @Test func shutdownRejectsServerStartSuspendedDuringCapabilityProbe() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try makeModel(at: modelDirectory)
        let gate = CapabilityProbeGate()
        let factory = TestProcessFactory(behavior: .holdServer)
        let service = DefaultMLXModelService(
            configuration: MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed"), importedModelDirectories: [modelDirectory]),
            environment: ["PATH": ""],
            capabilityProbe: SuspendedCapabilityProbe(executable: root.appendingPathComponent("mlx_lm"), gate: gate),
            processFactory: factory
        )
        let model = try await service.validateModelDirectory(modelDirectory)
        let pendingStart = Task {
            try await service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_325))
        }

        await gate.waitUntilEntered()
        await service.shutdown()
        await gate.release()

        var startFailed = false
        do { _ = try await pendingStart.value }
        catch { startFailed = true }
        // On the pre-fix implementation, the task succeeds and this cleanup stops its fake child.
        // The factory is always a local test double, so this can never launch a real process.
        await service.shutdown()

        #expect(startFailed)
        #expect(factory.requests.filter { $0.arguments.first == "server" }.isEmpty)
        #expect(await service.ownedServers().isEmpty)
    }

    @Test func serverStartAfterShutdownIsRejectedWithoutLaunching() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try makeModel(at: modelDirectory)
        let factory = TestProcessFactory(behavior: .holdServer)
        let service = DefaultMLXModelService(
            configuration: MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed"), importedModelDirectories: [modelDirectory]),
            environment: ["PATH": ""],
            capabilityProbe: FixedCapabilityProbe(executable: root.appendingPathComponent("mlx_lm"), python: nil),
            processFactory: factory
        )
        let model = try await service.validateModelDirectory(modelDirectory)
        await service.shutdown()

        var startFailed = false
        do { _ = try await service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_326)) }
        catch { startFailed = true }
        await service.shutdown()

        #expect(startFailed)
        #expect(factory.requests.filter { $0.arguments.first == "server" }.isEmpty)
        #expect(await service.ownedServers().isEmpty)
    }

    @Test func cancellingServerStartAtCapabilityProbeDoesNotLaunch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try makeModel(at: modelDirectory)
        let gate = CapabilityProbeGate()
        let factory = TestProcessFactory(behavior: .holdServer)
        let service = DefaultMLXModelService(
            configuration: MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed"), importedModelDirectories: [modelDirectory]),
            environment: ["PATH": ""],
            capabilityProbe: SuspendedCapabilityProbe(executable: root.appendingPathComponent("mlx_lm"), gate: gate),
            processFactory: factory
        )
        let model = try await service.validateModelDirectory(modelDirectory)
        let pendingStart = Task {
            try await service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_327))
        }

        await gate.waitUntilEntered()
        pendingStart.cancel()
        await gate.release()

        var startFailed = false
        do { _ = try await pendingStart.value }
        catch { startFailed = true }
        // Stop any fake child if a regression lets the cancelled start reach the factory.
        await service.shutdown()

        #expect(startFailed)
        #expect(factory.requests.filter { $0.arguments.first == "server" }.isEmpty)
        #expect(await service.ownedServers().isEmpty)
    }

    @Test func shutdownRejectsDownloadSuspendedDuringCapabilityProbe() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let gate = CapabilityProbeGate()
        let factory = TestProcessFactory(behavior: .holdDownload, managedDirectory: managed)
        let service = DefaultMLXModelService(
            configuration: MLXConfiguration(managedModelsDirectory: managed),
            environment: ["PATH": ""],
            capabilityProbe: SuspendedCapabilityProbe(executable: root.appendingPathComponent("mlx_lm"), python: root.appendingPathComponent("python"), gate: gate),
            processFactory: factory
        )
        let request = try MLXModelDownloadRequest(repositoryID: "owner/shutdown-model")
        let pendingDownload = Task { await service.download(request) }

        await gate.waitUntilEntered()
        await service.shutdown()
        await gate.release()

        let stream = await pendingDownload.value
        var streamFailed = false
        do {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        } catch { streamFailed = true }
        // The old path emits one partial-output event, then waits on this fake process forever.
        // Shutdown terminates it before checking that no download was started.
        await service.shutdown()

        #expect(streamFailed)
        #expect(factory.requests.filter { $0.arguments.first != "server" }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
    }

    @Test func chatUsesOnlyAnOwnedRunningLoopbackServerAndCancelsItsStream() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try makeModel(at: modelDirectory)
        let factory = TestProcessFactory(behavior: .holdServer)
        let transport = TestChatTransport()
        let service = DefaultMLXModelService(
            configuration: MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed"), importedModelDirectories: [modelDirectory]),
            environment: ["PATH": ""],
            capabilityProbe: FixedCapabilityProbe(executable: root.appendingPathComponent("mlx_lm"), python: nil),
            processFactory: factory,
            chatTransport: transport
        )
        let model = try await service.validateModelDirectory(modelDirectory)
        let session = try await service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_323))
        try await waitUntilRunning(service, id: session.id)
        let options = try MLXChatOptions(maxTokens: 16, temperature: 0)
        let chat = await service.chat(serverID: session.id, messages: [MLXChatMessage(role: .user, content: "private prompt")], options: options)
        let (firstChunks, firstChunkContinuation) = AsyncStream<String>.makeStream()
        let chatConsumer = Task {
            do { for try await chunk in chat { firstChunkContinuation.yield(chunk) } } catch {}
        }
        var firstChunkIterator = firstChunks.makeAsyncIterator()
        let firstChunk = await firstChunkIterator.next()
        chatConsumer.cancel()
        await chatConsumer.value
        firstChunkContinuation.finish()
        let cancelDeadline = Date.now.addingTimeInterval(1)
        while !transport.cancelled && Date.now < cancelDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(firstChunk == "ok")
        #expect(transport.url?.host == "127.0.0.1")
        #expect(transport.url?.path == "/v1/chat/completions")
        #expect(transport.body?.contains(Data("default_model".utf8)) == true)
        #expect(transport.body?.contains(Data(model.path.path.utf8)) == false)
        #expect(transport.cancelled)
        #expect(await service.ownedServers().first(where: { $0.id == session.id })?.state == .running)

        let unknownChat = await service.chat(serverID: UUID(), messages: [MLXChatMessage(role: .user, content: "x")], options: options)
        var unknownFailed = false
        do { _ = try await unknownChat.firstValue() } catch { unknownFailed = true }
        #expect(unknownFailed)
        await service.shutdown()
    }

    @Test func managedProcessTerminateAndWaitWaitsForChildCompletion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mlx-test")
        try Data("#!/bin/sh\ntrap 'printf TERM-DEFAULT; exit 0' TERM\nprintf 'READY\\n'\nwhile :; do sleep 0.1; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let execution = try ProcessExecutableClient(executableURL: executable).launch(CommandRequest(arguments: [], captureLimit: 4_096, timeout: .seconds(5)))
        let (readiness, readinessContinuation) = AsyncStream<Void>.makeStream()
        let monitor = Task { () -> [CommandEvent] in
            var events: [CommandEvent] = []
            do {
                for try await event in execution.events {
                    events.append(event)
                    if case .standardOutput(let text) = event, text.contains("READY") { readinessContinuation.yield(()) }
                }
            } catch {}
            readinessContinuation.finish()
            return events
        }
        var readinessIterator = readiness.makeAsyncIterator()
        #expect(await readinessIterator.next() != nil)
        #expect(execution.isLeaderRunning)
        await execution.terminateAndWait()
        let events = await monitor.value
        #expect(!execution.isLeaderRunning)
        #expect(events.contains { if case .completed = $0 { return true }; return false })
        #expect(events.contains { if case .standardOutput(let text) = $0 { return text.contains("TERM-DEFAULT") }; return false })
    }

    @Test func terminateAndWaitReapsProcessThatIgnoresTerm() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mlx-term-resistant")
        try Data("#!/bin/sh\ntrap '' TERM\nprintf 'READY\\n'\nwhile :; do sleep 0.1; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let execution = try ProcessExecutableClient(executableURL: executable).launch(CommandRequest(arguments: [], timeout: .seconds(5)))
        let (readiness, readinessContinuation) = AsyncStream<Void>.makeStream()
        let monitor = Task { () -> Bool in
            do {
                for try await event in execution.events {
                    if case .standardOutput(let text) = event, text.contains("READY") { readinessContinuation.yield(()) }
                    if case .completed = event { readinessContinuation.finish(); return true }
                }
            } catch {}
            readinessContinuation.finish()
            return false
        }
        var readinessIterator = readiness.makeAsyncIterator()
        #expect(await readinessIterator.next() != nil)
        let start = ContinuousClock.now
        await execution.terminateAndWait()
        let elapsed = start.duration(to: .now)
        #expect(await monitor.value)
        #expect(!execution.isLeaderRunning)
        #expect(elapsed >= .milliseconds(450))
    }

    @Test func downloadUsesFixedPythonHelperAndMarksOnlyValidatedModels() async throws {
        let fixture = try makeServiceFixture(processBehavior: .downloadSuccess)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let downloadRequest = try MLXModelDownloadRequest(repositoryID: "owner/tiny-model")
        let stream = await fixture.service.download(downloadRequest)
        var completed: MLXModelRecord?
        for try await event in stream {
            if case .completed(let model) = event { completed = model }
        }
        #expect(completed?.id == "managed:owner/tiny-model")
        #expect(completed?.source == .appManagedDownload)
        let args = try #require(fixture.factory.requests.first?.arguments)
        #expect(args.count == 4)
        #expect(args[0] == "-c")
        #expect(args[1].contains("snapshot_download"))
        #expect(args[2] == "owner/tiny-model")
        #expect(URL(fileURLWithPath: args[3]).deletingLastPathComponent() == fixture.managed)
        let models = try await fixture.service.listLocalModels()
        #expect(models.contains(where: { $0.id == "managed:owner/tiny-model" }))
    }

    @Test func cancellingDownloadWaitsForOwnedProcessAndLeavesPartialDataUnlisted() async throws {
        let fixture = try makeServiceFixture(processBehavior: .holdDownload)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stream = await fixture.service.download(try MLXModelDownloadRequest(repositoryID: "owner/partial-model"))
        let consumer = Task {
            for try await _ in stream { try await Task.sleep(for: .seconds(60)) }
        }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        do { try await consumer.value }
        catch is CancellationError { }
        catch { throw error }
        await fixture.service.shutdown()
        #expect(await fixture.service.ownedServers().isEmpty)
        let catalog = MLXModelCatalog(
            configuration: MLXConfiguration(managedModelsDirectory: fixture.managed, importedModelDirectories: [fixture.modelDirectory]),
            environment: ["HF_HUB_CACHE": fixture.root.appendingPathComponent("hf-cache", isDirectory: true).path]
        )
        let models = await catalog.listLocalModels()
        #expect(!models.contains(where: { $0.id == "managed:owner/partial-model" }))
        let target = try MLXModelCatalog.managedPath(for: "owner/partial-model", root: fixture.managed)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(MLXModelCatalog.managedManifest(at: target)?.complete == false)
    }

    @Test func chatRequestLimitsRejectLargeOrInvalidHistories() throws {
        #expect(throws: MLXError.invalidChatOptions) { _ = try MLXChatOptions(maxTokens: 0) }
        #expect(throws: MLXError.invalidChatOptions) { _ = try MLXChatOptions(temperature: .infinity) }
    }

    @Test func chatPreservesEveryChunkForSlowConsumerWithinOutputBound() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try makeModel(at: modelDirectory)
        let chatChunks = Array(repeating: "x", count: 256)
        let transport = TestChatTransport(chunks: chatChunks, finishAfterYield: true)
        let service = DefaultMLXModelService(
            configuration: MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed"), importedModelDirectories: [modelDirectory]),
            environment: ["PATH": ""],
            capabilityProbe: FixedCapabilityProbe(executable: root.appendingPathComponent("mlx_lm"), python: nil),
            processFactory: TestProcessFactory(behavior: .holdServer),
            chatTransport: transport
        )
        let model = try await service.validateModelDirectory(modelDirectory)
        let session = try await service.startServer(modelID: model.id, options: MLXServerOptions(port: 18_324))
        try await waitUntilRunning(service, id: session.id)
        let chat = await service.chat(serverID: session.id, messages: [MLXChatMessage(role: .user, content: "slow consumer")], options: try MLXChatOptions(maxTokens: 512))
        var received = 0
        for try await chunk in chat {
            try await Task.sleep(for: .milliseconds(1))
            if chunk == "x" { received += 1 }
        }
        #expect(received == chatChunks.count)
        await service.shutdown()
    }

    private func makeServiceFixture(processBehavior: TestProcessBehavior) throws -> ServiceFixture {
        let root = temporaryDirectory()
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try makeModel(at: modelDirectory)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let factory = TestProcessFactory(behavior: processBehavior, managedDirectory: managed)
        let service = DefaultMLXModelService(
            configuration: MLXConfiguration(managedModelsDirectory: managed, importedModelDirectories: [modelDirectory]),
            environment: ["PATH": ""],
            capabilityProbe: FixedCapabilityProbe(executable: root.appendingPathComponent("mlx_lm"), python: root.appendingPathComponent("python")),
            processFactory: factory
        )
        return ServiceFixture(root: root, modelDirectory: modelDirectory, managed: managed, service: service, factory: factory)
    }

    private func makeRetentionFixture(modelCount: Int) throws -> RetentionFixture {
        let root = temporaryDirectory()
        let modelDirectories = (0..<modelCount).map { root.appendingPathComponent("model-\($0)", isDirectory: true) }
        for directory in modelDirectories { try makeModel(at: directory) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let factory = TestProcessFactory(behavior: .holdServer, managedDirectory: managed)
        let service = DefaultMLXModelService(
            configuration: MLXConfiguration(managedModelsDirectory: managed, importedModelDirectories: modelDirectories),
            environment: ["PATH": ""],
            capabilityProbe: FixedCapabilityProbe(executable: root.appendingPathComponent("mlx_lm"), python: root.appendingPathComponent("python")),
            processFactory: factory
        )
        return RetentionFixture(root: root, modelDirectories: modelDirectories, service: service, factory: factory)
    }

    private func waitUntilRunning(_ service: DefaultMLXModelService, id: UUID) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while Date.now < deadline {
            if await service.ownedServers().first(where: { $0.id == id })?.state == .running { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Fake local server did not reach its running state.")
    }

    private func collectUntilStreamFinishes(
        _ stream: AsyncStream<MLXServerEvent>,
        timeout: Duration
    ) async -> [MLXServerEvent]? {
        await withTaskGroup(of: [MLXServerEvent]?.self) { group in
            group.addTask {
                var events: [MLXServerEvent] = []
                for await event in stream { events.append(event) }
                return events
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func makeModel(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"model_type":"tiny"}"#.utf8).write(to: url.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: url.appendingPathComponent("tokenizer.json"))
        try Data(repeating: 1, count: 16).write(to: url.appendingPathComponent("model.safetensors"))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesk-mlx-service-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct ServiceFixture {
    let root: URL
    let modelDirectory: URL
    let managed: URL
    let service: DefaultMLXModelService
    let factory: TestProcessFactory
}

private struct RetentionFixture {
    let root: URL
    let modelDirectories: [URL]
    let service: DefaultMLXModelService
    let factory: TestProcessFactory
}

private struct FixedCapabilityProbe: MLXCapabilityProbing {
    let executable: URL
    let python: URL?
    func detect(configuration: MLXConfiguration, environment: [String: String]) async -> MLXCapability {
        MLXCapability(available: true, mlxLMVersion: "0.32.2", executableURL: executable, pythonURL: python)
    }
}

private struct SuspendedCapabilityProbe: MLXCapabilityProbing {
    let executable: URL
    var python: URL? = nil
    let gate: CapabilityProbeGate

    func detect(configuration: MLXConfiguration, environment: [String: String]) async -> MLXCapability {
        await gate.suspend()
        return MLXCapability(available: true, mlxLMVersion: "0.32.2", executableURL: executable, pythonURL: python)
    }
}

private actor CapabilityProbeGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum TestProcessBehavior: Equatable {
    case holdServer
    case failServer
    case successServer
    case downloadSuccess
    case holdDownload
}

private final class TestProcessFactory: MLXExecutableProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let behavior: TestProcessBehavior
    private let managedDirectory: URL?
    private var recordedRequests: [CommandRequest] = []
    private var weakHandleTokens: [WeakMockExecutionHandleToken] = []

    init(behavior: TestProcessBehavior, managedDirectory: URL? = nil) {
        self.behavior = behavior
        self.managedDirectory = managedDirectory
    }

    var requests: [CommandRequest] { lock.lock(); defer { lock.unlock() }; return recordedRequests }
    func handleToken(at index: Int) -> MockExecutionHandleToken? {
        lock.lock(); defer { lock.unlock() }
        guard weakHandleTokens.indices.contains(index) else { return nil }
        return weakHandleTokens[index].value
    }

    func record(_ request: CommandRequest) {
        lock.lock(); defer { lock.unlock() }; recordedRequests.append(request)
    }

    func launch(executableURL: URL, request: CommandRequest) throws -> ManagedProcessExecution {
        record(request)
        let token = MockExecutionHandleToken()
        lock.lock(); weakHandleTokens.append(WeakMockExecutionHandleToken(token)); lock.unlock()
        if request.arguments.first == "server", behavior == .holdServer {
            let port = request.arguments.firstIndex(of: "--port").flatMap { request.arguments.indices.contains($0 + 1) ? request.arguments[$0 + 1] : nil } ?? "0"
            return TestProcessExecution(output: "Starting httpd at127.0.0.1 on port \(port)", leaderRunning: true, token: token).managed()
        }
        if request.arguments.first == "server" {
            let succeeded = behavior == .successServer
            let result = CommandResult(standardOutput: "", standardError: succeeded ? "" : "address already in use", exitCode: succeeded ? 0 : 1, terminationReason: .exit, duration: .zero)
            return TestProcessExecution(result: result, leaderRunning: false, token: token).managed()
        }
        if behavior == .downloadSuccess, let path = request.arguments.last {
            let destination = URL(fileURLWithPath: path)
            try prepareDownload(at: destination)
            return TestProcessExecution(output: "download complete", result: CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero), leaderRunning: false, token: token).managed()
        }
        return TestProcessExecution(output: "partial download", leaderRunning: true, token: token).managed()
    }

    func prepareDownload(at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(#"{"model_type":"tiny"}"#.utf8).write(to: destination.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: destination.appendingPathComponent("tokenizer.json"))
        try Data(repeating: 1, count: 16).write(to: destination.appendingPathComponent("model.safetensors"))
    }
}

private final class MockExecutionHandleToken: @unchecked Sendable {}

private final class WeakMockExecutionHandleToken {
    weak var value: MockExecutionHandleToken?
    init(_ value: MockExecutionHandleToken) { self.value = value }
}

private final class TestProcessExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    init(running: Bool) { self.running = running }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func stop() { lock.lock(); running = false; lock.unlock() }
}

private struct TestProcessExecution {
    let output: String?
    let result: CommandResult?
    let state: TestProcessExecutionState
    let stream: AsyncThrowingStream<CommandEvent, Error>

    init(output: String? = nil, result: CommandResult? = nil, leaderRunning: Bool, token: MockExecutionHandleToken? = nil) {
        self.output = output
        self.result = result
        self.capturedToken = token
        let processState = TestProcessExecutionState(running: leaderRunning)
        self.state = processState
        let (stream, continuation) = AsyncThrowingStream<CommandEvent, Error>.makeStream()
        self.stream = stream
        if let output { continuation.yield(.standardOutput(output)) }
        if let result { continuation.yield(.completed(result)); continuation.finish() }
        continuation.onTermination = { @Sendable _ in }
        if leaderRunning {
            self.stopBody = {
                _ = token
                processState.stop()
                continuation.yield(.completed(CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)))
                continuation.finish()
            }
        } else {
            self.stopBody = { _ = token; processState.stop() }
        }
    }

    let stopBody: @Sendable () -> Void

    func managed() -> ManagedProcessExecution {
        let processState = state
        let eventStream = self.stream
        let stopBody = self.stopBody
        let token = self.token
        return ManagedProcessExecution(events: eventStream, isLeaderRunning: { _ = token; return processState.isRunning }) {
            _ = token
            stopBody()
        }
    }

    private var token: MockExecutionHandleToken? { capturedToken }
    private var capturedToken: MockExecutionHandleToken?
}

private final class TestChatTransport: MLXChatStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURL: URL?
    private var recordedBody: Data?
    private var didCancel = false
    private let chunks: [String]
    private let finishAfterYield: Bool
    init(chunks: [String] = ["ok"], finishAfterYield: Bool = false) {
        self.chunks = chunks
        self.finishAfterYield = finishAfterYield
    }
    var url: URL? { lock.lock(); defer { lock.unlock() }; return recordedURL }
    var body: Data? { lock.lock(); defer { lock.unlock() }; return recordedBody }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return didCancel }

    func stream(url: URL, body: Data) -> AsyncThrowingStream<String, Error> {
        lock.lock(); recordedURL = url; recordedBody = body; lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if finishAfterYield { continuation.finish() }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.lock.lock(); self?.didCancel = true; self?.lock.unlock()
            }
        }
    }
}

private extension AsyncThrowingStream where Element == String, Failure == Error {
    func firstValue() async throws -> String? {
        for try await value in self { return value }
        return nil
    }
}
