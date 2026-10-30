import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct UnifiedLogsStoreTests {
    @MainActor @Test func mergesSourcesPausesWithoutLosingLinesAndCancelsOwnedStreams() async throws {
        let client = LogStreamTestClient()
        let logs = UnifiedLogsStore()
        logs.configure(ids: ["web", "db"], client: client)
        try await waitUntil { client.requestCount == 2 }
        client.emit("web one\n", id: "web")
        client.emit("db one\n", id: "db")
        try await waitUntil { logs.entries.count == 2 }
        #expect(Set(logs.entries.map(\.containerID)) == ["web", "db"])
        logs.setPaused(true)
        client.emit("web two\n", id: "web")
        try await waitUntil { logs.pendingCount == 1 }
        #expect(logs.entries.count == 2)
        logs.setPaused(false)
        #expect(logs.entries.count == 3)
        #expect(logs.pendingCount == 0)
        logs.configure(ids: ["web"], client: client)
        try await waitUntil { client.cancelledIDs.contains("db") }
        #expect(logs.streamingIDs == ["web"])
        logs.stop()
        try await waitUntil { client.cancelledIDs.contains("web") }
        #expect(logs.streamingIDs.isEmpty)
    }

    @MainActor @Test func failedStreamFinishesPartialLineAndAllowsReconnect() async throws {
        let client = LogStreamTestClient()
        let logs = UnifiedLogsStore()
        logs.configure(ids: ["web"], client: client)
        try await waitUntil { client.requestCount == 1 }
        client.emit("last partial", id: "web")
        client.fail(id: "web")
        try await waitUntil { logs.errors["web"] != nil && logs.entries.count == 1 }
        #expect(logs.entries.first?.message == "last partial")
        logs.retry(id: "web", client: client)
        try await waitUntil { client.requestCount == 2 }
        #expect(logs.errors["web"] == nil)
        logs.stop()
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
}

private final class LogStreamTestClient: ContainerClient, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: AsyncThrowingStream<CommandEvent, Error>.Continuation] = [:]
    private var requests = 0
    private var cancelled = Set<String>()
    var requestCount: Int { lock.withLock { requests } }
    var cancelledIDs: Set<String> { lock.withLock { cancelled } }
    func run(_ request: CommandRequest) async throws -> CommandResult {
        CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        let id = request.arguments.last!
        let (stream, continuation) = AsyncThrowingStream<CommandEvent, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in _ = self?.lock.withLock { self?.cancelled.insert(id) } }
        lock.withLock { continuations[id] = continuation; requests += 1 }
        return stream
    }
    func emit(_ text: String, id: String) { _ = lock.withLock { continuations[id] }?.yield(.standardOutput(text)) }
    func fail(id: String) { lock.withLock { continuations[id] }?.finish(throwing: ContainerClientError.launchFailed("fixture failure")) }
}
