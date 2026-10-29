import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct AppStoreOperationPolicyTests {
    @Test func onlyAllowlistedReadCommandsCanBeRetried() {
        for arguments in [["delete", "container-1"], ["prune"], ["image", "delete", "image:tag"], ["volume", "prune"], ["stop", "container-1"], ["copy", "a", "b"], ["exec", "container-1", "rm", "-rf", "/"]] {
            #expect(!CommandRequest(arguments: arguments).isSafeToRetry)
        }
        #expect(CommandRequest(arguments: ["builder", "status", "--format", "json"]).isSafeToRetry)
        #expect(CommandRequest(arguments: ["logs", "container-1"]).isSafeToRetry)
        #expect(CommandRequest(arguments: ["system", "dns", "list"]).isSafeToRetry)
    }

    @MainActor
    @Test func slowActivityConsumerGetsExplicitBufferFailure() async throws {
        let store = AppStore(client: BurstPolicyTestClient())
        let operation = store.streamWithID(CommandRequest(arguments: ["logs", "container-1"]), title: "Read logs")
        try await waitForRelayFailure(operation.operationID, in: store)

        var sawOverflow = false
        do {
            for try await _ in operation.events {}
        } catch ContainerClientError.outputBufferExceeded {
            sawOverflow = true
        }
        #expect(sawOverflow)
        #expect(store.operations.first(where: { $0.id == operation.operationID })?.state == .failed)
        #expect(store.operations.first(where: { $0.id == operation.operationID })?.canRetry == false)
    }

    @MainActor
    @Test func relayCannotSilentlyDropFinalResult() async throws {
        let store = AppStore(client: BurstPolicyTestClient(outputCount: 256))
        let operation = store.streamWithID(CommandRequest(arguments: ["logs", "container-1"]), title: "Read logs")
        try await waitForRelayFailure(operation.operationID, in: store)

        var sawOverflow = false
        do {
            for try await _ in operation.events {}
        } catch ContainerClientError.outputBufferExceeded {
            sawOverflow = true
        }
        #expect(sawOverflow)
        let record = store.operations.first(where: { $0.id == operation.operationID })
        #expect(record?.state == .failed)
        #expect(record?.exitCode == 0)
        #expect(record?.error == ContainerClientError.outputBufferExceeded.localizedDescription)
    }

    @MainActor
    private func waitForRelayFailure(_ id: UUID, in store: AppStore) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while store.operations.first(where: { $0.id == id })?.state != .failed, Date.now < deadline {
            await Task.yield()
        }
        #expect(store.operations.first(where: { $0.id == id })?.state == .failed, "The relay did not reach its explicit output-buffer failure state.")
    }

    @MainActor
    @Test func reviewedDeletionUsesCapturedClientAndCannotBeRetriedOrInterrupted() async throws {
        let currentClient = PolicyTestClient(blocked: false)
        let reviewedClient = PolicyTestClient(blocked: true)
        let store = AppStore(client: currentClient)
        let request = CommandRequest(arguments: ["image", "delete", "--", "example:reviewed"])
        let operation = Task {
            try await store.execute(request, title: "Reviewed cleanup", using: reviewedClient, allowRetry: false, allowCancellation: false)
        }
        await reviewedClient.waitUntilStarted()
        let record = try #require(store.operations.first)
        #expect(!record.canRetry)
        #expect(!record.canCancel)
        store.cancelOperation(record.id)
        #expect(store.operations.first?.state == .running)
        await reviewedClient.finish()
        _ = try await operation.value
        #expect(await reviewedClient.requests() == [request.arguments])
        #expect(await currentClient.requests().isEmpty)
        #expect(store.operations.first?.state == .succeeded)
        await #expect(throws: (any Error).self) { try await store.retryOperation(record.id) }
    }

    @MainActor
    @Test func retryRequestsAreBoundedByVisibleFailedActivity() async throws {
        let client = ChurningPolicyTestClient(failuresBeforeSuccess: 260)
        let store = AppStore(client: client)
        var evictedID: UUID?

        for index in 0..<260 {
            let request = CommandRequest(arguments: ["logs", "container-\(index)"])
            do {
                _ = try await store.execute(request, title: "Read \(index)")
            } catch {
                if index == 0 { evictedID = store.operations.first(where: { $0.commandPreview == request.preview })?.id }
            }
        }

        let visibleFailed = try #require(store.operations.first)
        let cached = try #require(retryRequestCache(in: store))
        let visibleIDs = Set(store.operations.map(\.id))
        #expect(store.operations.count == 250)
        #expect(cached.count <= 250)
        #expect(Set(cached.keys).isSubset(of: visibleIDs))
        #expect(cached.keys.contains(visibleFailed.id))
        #expect(evictedID.map { !visibleIDs.contains($0) } == true)
        if let evictedID { #expect(!cached.keys.contains(evictedID)) }

        let retryResult = try await store.retryOperation(visibleFailed.id)
        #expect(retryResult.succeeded)

        let callsBeforeEvictedRetry = await client.requests().count
        if let evictedID {
            await #expect(throws: (any Error).self) { try await store.retryOperation(evictedID) }
        }
        #expect(await client.requests().count == callsBeforeEvictedRetry)
    }

    @MainActor
    @Test func blockedActiveOperationSurvivesHistoryChurnAndCleansRetryAfterCompletion() async {
        let activeRequest = CommandRequest(arguments: ["logs", "active-container"])
        let client = ActiveBlockingPolicyTestClient(blockedArguments: activeRequest.arguments)
        let store = AppStore(client: client)
        let activeTask = Task {
            try? await store.execute(activeRequest, title: "Blocked read")
        }
        // The deferred release also runs if an assertion below fails early, so the fake
        // client can never leave this test suspended.
        defer { Task { await client.finish() } }

        await client.waitUntilStarted()
        guard let activeID = store.operations.first(where: { $0.commandPreview == activeRequest.preview })?.id else {
            await client.finish()
            _ = await activeTask.value
            #expect(Bool(false), "The blocked operation was not recorded.")
            return
        }

        for index in 0..<260 {
            let request = CommandRequest(arguments: ["logs", "churn-\(index)"])
            _ = try? await store.execute(request, title: "Churn \(index)")
        }

        let activeOperationIsVisible = store.operations.contains(where: { $0.id == activeID })
        #expect(activeOperationIsVisible)
        #expect(store.operations.first(where: { $0.id == activeID })?.state == .running)
        #expect(store.operations.first(where: { $0.id == activeID })?.canCancel == true)
        store.cancelOperation(activeID)
        #expect(store.operations.first(where: { $0.id == activeID })?.state == .cancelled)

        await client.finish()
        _ = await activeTask.value
        #expect(retryRequestCache(in: store)?.keys.contains(activeID) == false)
    }

    @MainActor
    @Test func executeCancellationStaysCancelledAfterLateSuccess() async {
        let request = CommandRequest(arguments: ["logs", "late-success-container"])
        let client = ActiveBlockingPolicyTestClient(blockedArguments: request.arguments)
        let store = AppStore(client: client)
        let task = Task { try? await store.execute(request, title: "Cancelled read") }
        defer { Task { await client.finish() } }

        await client.waitUntilStarted()
        guard let id = store.operations.first?.id else {
            await client.finish()
            _ = await task.value
            #expect(Bool(false), "The command was not recorded.")
            return
        }
        store.cancelOperation(id)
        #expect(store.operations.first(where: { $0.id == id })?.state == .cancelled)

        await client.finish()
        _ = await task.value
        #expect(store.operations.first(where: { $0.id == id })?.state == .cancelled)
        #expect(retryRequestCache(in: store)?.keys.contains(id) == false)
    }

    @MainActor
    @Test func streamedCancellationStaysCancelledAfterLateSuccess() async {
        let request = CommandRequest(arguments: ["logs", "late-stream-container"])
        let client = LateStreamCompletionPolicyTestClient()
        let store = AppStore(client: client)
        let operation = store.streamWithID(request, title: "Cancelled stream")
        let consumer = Task {
            do { for try await _ in operation.events {} } catch {}
        }
        defer { Task { await client.finish() } }

        await client.waitUntilStarted()
        store.cancelOperation(operation.operationID)
        #expect(store.operations.first(where: { $0.id == operation.operationID })?.state == .cancelled)

        await client.finish()
        await consumer.value
        #expect(store.operations.first(where: { $0.id == operation.operationID })?.state == .cancelled)
        #expect(retryRequestCache(in: store)?.keys.contains(operation.operationID) == false)

        for index in 0..<260 {
            _ = try? await store.execute(
                CommandRequest(arguments: ["logs", "stream-churn-\(index)"]),
                title: "Stream churn \(index)"
            )
        }
        let cancelledStreamAgedOut = !store.operations.contains(where: { $0.id == operation.operationID })
        #expect(cancelledStreamAgedOut)
    }

    @MainActor
    @Test func streamWithoutCompletionFinalizesActivity() async {
        let request = CommandRequest(arguments: ["logs", "empty-stream-container"])
        let store = AppStore(client: EmptyStreamPolicyTestClient())
        let operation = store.streamWithID(request, title: "Empty stream")
        do { for try await _ in operation.events {} } catch {}

        let record = store.operations.first(where: { $0.id == operation.operationID })
        #expect(record?.state == .failed)
        #expect(record?.canRetry == true)
        let noRunningActivity = !store.operations.contains(where: { $0.state == .running })
        #expect(noRunningActivity)
        #expect(retryRequestCache(in: store)?.keys.contains(operation.operationID) == true)
    }

    @MainActor
    @Test func queuedStreamKeepsItsSubmissionClientAfterCLISelectionChanges() async throws {
        let suiteName = "AppStoreOperationPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let submittedClient = StreamRoutingPolicyTestClient()
        let store = AppStore(client: submittedClient, defaults: defaults)
        let request = CommandRequest(arguments: ["logs", "captured-client"])
        let submittedOperation = store.streamWithID(request, title: "Captured client")

        // streamWithID schedules its worker. Change the selection in the same MainActor turn,
        // before yielding, so the queued worker must use the client captured above.
        store.cliPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("containerdesk-missing-\(UUID().uuidString)")
            .path

        var submittedEvents: [CommandEvent] = []
        for try await event in submittedOperation.events { submittedEvents.append(event) }
        await submittedClient.waitUntilStarted()
        #expect(await submittedClient.requests() == [request.arguments])
        #expect(submittedEvents.contains { if case .completed(let result) = $0 { return result.succeeded }; return false })
        #expect(store.operations.first(where: { $0.id == submittedOperation.operationID })?.state == .succeeded)

        // Future work must still honor the new CLI selection. Its deliberately missing path
        // is resolved fail-closed and cannot launch any executable.
        let laterOperation = store.streamWithID(CommandRequest(arguments: ["logs", "new-selection"]), title: "New selection")
        do { for try await _ in laterOperation.events {} } catch {}
        #expect(store.operations.first(where: { $0.id == laterOperation.operationID })?.state == .failed)
        #expect(await submittedClient.requests() == [request.arguments])
    }

    @MainActor
    private func retryRequestCache(in store: AppStore) -> [UUID: CommandRequest]? {
        Mirror(reflecting: store).children.first(where: { $0.label == "retryRequests" })?.value as? [UUID: CommandRequest]
    }
}

private actor StreamRoutingPolicyTestClient: ContainerClient {
    private var recorded: [[String]] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func requests() -> [[String]] { recorded }

    func waitUntilStarted() async {
        if !recorded.isEmpty { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        recorded.append(request.arguments)
        startedWaiter?.resume()
        startedWaiter = nil
        return CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let result = try await run(request)
                continuation.yield(.completed(result))
                continuation.finish()
            }
        }
    }
}

private struct BurstPolicyTestClient: ContainerClient {
    var outputCount: Int = 2_000

    func run(_ request: CommandRequest) async throws -> CommandResult {
        CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            for index in 0..<outputCount { continuation.yield(.standardOutput("chunk-\(index)")) }
            continuation.yield(.completed(CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)))
            continuation.finish()
        }
    }
}

private struct EmptyStreamPolicyTestClient: ContainerClient {
    func run(_ request: CommandRequest) async throws -> CommandResult {
        CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor PolicyTestClient: ContainerClient {
    private let blocked: Bool
    private var recorded: [[String]] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    init(blocked: Bool) { self.blocked = blocked }

    func requests() -> [[String]] { recorded }

    func waitUntilStarted() async {
        if !recorded.isEmpty { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finish() { finishWaiter?.resume(); finishWaiter = nil }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        recorded.append(request.arguments)
        startedWaiter?.resume()
        startedWaiter = nil
        if blocked { await withCheckedContinuation { finishWaiter = $0 } }
        return CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor ChurningPolicyTestClient: ContainerClient {
    private let failuresBeforeSuccess: Int
    private var callCount = 0
    private var recorded: [[String]] = []

    init(failuresBeforeSuccess: Int) { self.failuresBeforeSuccess = failuresBeforeSuccess }

    func requests() -> [[String]] { recorded }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        callCount += 1
        recorded.append(request.arguments)
        let exitCode: Int32 = callCount <= failuresBeforeSuccess ? 1 : 0
        return CommandResult(standardOutput: "", standardError: "", exitCode: exitCode, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor LateStreamCompletionPolicyTestClient: ContainerClient {
    private var eventContinuation: AsyncThrowingStream<CommandEvent, Error>.Continuation?
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if eventContinuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func install(_ continuation: AsyncThrowingStream<CommandEvent, Error>.Continuation) {
        eventContinuation = continuation
        startedWaiter?.resume()
        startedWaiter = nil
    }

    func finish() {
        eventContinuation?.yield(.completed(CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await install(continuation) }
        }
    }
}

private actor ActiveBlockingPolicyTestClient: ContainerClient {
    private let blockedArguments: [String]
    private var recorded: [[String]] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    init(blockedArguments: [String]) { self.blockedArguments = blockedArguments }

    func waitUntilStarted() async {
        if recorded.contains(blockedArguments) { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finish() { finishWaiter?.resume(); finishWaiter = nil }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        recorded.append(request.arguments)
        if request.arguments == blockedArguments {
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { finishWaiter = $0 }
        }
        return CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
