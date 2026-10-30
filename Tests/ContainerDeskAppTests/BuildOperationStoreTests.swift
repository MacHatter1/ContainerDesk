import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct BuildOperationStoreTests {
    @MainActor @Test func cancellationFromActivityDoesNotBecomeAViewError() async throws {
        let client = BlockingBuildClient()
        let appStore = AppStore(client: client)
        let build = BuildOperationStore()
        build.start(CommandRequest(arguments: ["build", "/fixture"]), title: "Build", store: appStore)
        try await waitUntil { await client.started }
        let id = try #require(build.operationID)
        appStore.cancelOperation(id)
        try await waitUntil { await client.cancelled }
        try await waitUntil { !build.isRunning }
        #expect(build.error == nil)
        #expect(appStore.operations.first?.state == .cancelled)
    }

    @MainActor @Test(arguments: [["build", "/fixture"], ["builder", "start"], ["builder", "stop"], ["builder", "delete"]])
    func cancelTargetsTheActiveBuildOrBuilderAndRecordsCancellation(_ arguments: [String]) async throws {
        let client = BlockingBuildClient()
        let appStore = AppStore(client: client)
        let build = BuildOperationStore()
        build.start(CommandRequest(arguments: arguments), title: "Fixture operation", store: appStore)
        try await waitUntil { await client.started }
        let id = try #require(build.operationID)
        build.cancel()
        #expect(appStore.operations.first(where: { $0.id == id })?.state == .cancelled)
        try await waitUntil { await client.cancelled }
        try await waitUntil { !build.isRunning }
        #expect(build.operationID == nil)
        #expect(build.error == nil)
        #expect(appStore.operations.first(where: { $0.id == id })?.state == .cancelled)
    }

    @MainActor @Test func aFinishedBuildCannotStealCancellationFromTheNextBuilderCommand() async throws {
        let client = BlockingBuildClient()
        let appStore = AppStore(client: client)
        let build = BuildOperationStore()
        build.start(CommandRequest(arguments: ["build", "/fixture"]), title: "Build", store: appStore)
        try await waitUntil { await client.started }
        await client.succeed()
        try await waitUntil { !build.isRunning }
        #expect(appStore.operations.first?.state == .succeeded)
        await client.reset()
        build.start(CommandRequest(arguments: ["builder", "start"]), title: "Start builder", store: appStore)
        try await waitUntil { await client.started }
        build.cancel()
        try await waitUntil { await client.cancelled }
        #expect(appStore.operations.first?.state == .cancelled)
        #expect(appStore.operations.last?.state == .succeeded)
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }
}

private actor BlockingBuildClient: ContainerClient {
    private var continuation: AsyncThrowingStream<CommandEvent, Error>.Continuation?
    private(set) var started = false
    private(set) var cancelled = false
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason { Task { await self.didCancel() } }
            }
            Task { await self.begin(continuation) }
        }
    }
    func run(_ request: CommandRequest) async throws -> CommandResult {
        for try await event in stream(request) { if case .completed(let result) = event { return result } }
        throw CancellationError()
    }
    private func begin(_ continuation: AsyncThrowingStream<CommandEvent, Error>.Continuation) {
        self.continuation = continuation
        started = true
    }
    private func didCancel() { cancelled = true; continuation = nil }
    func reset() { started = false; cancelled = false }
    func succeed() {
        continuation?.yield(.completed(CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)))
        continuation?.finish()
        continuation = nil
    }
}
