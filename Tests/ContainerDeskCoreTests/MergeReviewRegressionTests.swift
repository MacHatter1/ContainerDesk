import Foundation
import Testing
@testable import ContainerDeskCore

struct MergeReviewCoreRegressionTests {
    @Test func shutdownAdmissionRejectsLateProcessesWithoutPreventingExistingCleanup() async throws {
        let registry = ProcessRegistry()
        let client = ProcessExecutableClient(executableURL: URL(fileURLWithPath: "/bin/sleep"), registry: registry)
        let existing = try client.launch(.init(arguments: ["30"]))
        registry.beginShutdown()
        #expect(throws: ContainerClientError.self) { try client.launch(.init(arguments: ["30"])) }
        await #expect(throws: ContainerClientError.self) { try await client.run(.init(arguments: ["30"])) }
        await existing.terminateAndWait()
        #expect(!existing.isLeaderRunning)
    }

    @Test func partialLineEvictionInvalidatesTheVisibleLogRevision() {
        var buffer = ContainerLogBuffer(maxEntries: 2_000, maxBytes: 120_000)
        for _ in 0..<7 { buffer.append(String(repeating: "x", count: 16_000) + "\n", containerID: "web") }
        let revision = buffer.revision
        let before = buffer.entries
        buffer.append(String(repeating: "y", count: 9_000), containerID: "worker")
        #expect(before.count == 7 && buffer.entries.count == 6)
        #expect(buffer.revision != revision, "A display cache must refresh after eviction even if no new line is complete.")
    }

    @Test func replacingTheLogSessionInvalidatesItsRevisionEvenAtTheSameLineCount() {
        var first = ContainerLogBuffer()
        first.append("old session\n", containerID: "web")
        var next = ContainerLogBuffer()
        next.append("new session\n", containerID: "web")
        #expect(first.revision != next.revision)
    }

    @Test func partialTextWithoutVisibleEntryChangesDoesNotInvalidateTheLogRevision() {
        var buffer = ContainerLogBuffer()
        buffer.append("complete\n", containerID: "web")
        let revision = buffer.revision
        let previous = buffer
        buffer.append("partial", containerID: "worker")
        #expect(buffer.revision == revision)
        #expect(previous.entries == buffer.entries)
        buffer.finishAll()
        #expect(buffer.revision != revision)
        #expect(previous.revision == revision && previous.entries.count == 1)
    }
}
