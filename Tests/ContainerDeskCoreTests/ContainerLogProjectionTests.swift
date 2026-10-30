import Foundation
import Testing
@testable import ContainerDeskCore

struct ContainerLogProjectionTests {
    @MainActor @Test func asynchronousFiltersPreserveUnicodeSourcesRangesAndExportSelection() async throws {
        let date = Date(timeIntervalSince1970: 1_000)
        var buffer = ContainerLogBuffer()
        buffer.append("READY café\nTIMEOUT 🌍\n", containerID: "web", at: date)
        buffer.append("timeout db\n", containerID: "db", at: date.addingTimeInterval(10))
        let snapshot = ContainerLogSnapshot(entries: buffer.entries)
        let projection = ContainerLogProjection()
        for filter in [ContainerLogFilter(sources: ["web", "db"], query: "CAFE"), .init(sources: ["web", "db"], query: "timeout"), .init(sources: ["web", "db"], containerID: "web", query: "timeout", range: date...date.addingTimeInterval(5)), .init(sources: [])] {
            let rows = try await projection.rowsAsync(in: snapshot, matching: filter)
            #expect(rows == snapshot.entries.filter(filter.includes))
            #expect(projection.cachedRows(in: snapshot, matching: filter) == rows)
            #expect(ContainerLogBuffer.export(rows) == ContainerLogBuffer.export(snapshot.entries.filter(filter.includes)))
        }
    }
    @MainActor @Test func publicationsStayVisibleDuringFilteringButFilterAndSessionChangesHideThem() async throws {
        let projection = ContainerLogProjection()
        var buffer = ContainerLogBuffer()
        buffer.append("old\n", containerID: "web")
        let session = UUID()
        let first = ContainerLogSnapshot(entries: buffer.entries, sessionID: session)
        let filter = ContainerLogFilter(sources: ["web"])
        _ = try await projection.rowsAsync(in: first, matching: filter)
        buffer.append("new\n", containerID: "web")
        let second = ContainerLogSnapshot(entries: buffer.entries, sessionID: session)
        #expect(projection.cachedRows(in: second, matching: filter).isEmpty)
        #expect(projection.displayRows(in: second, matching: filter).map(\.message) == ["old"])
        #expect(projection.displayRows(in: second, matching: .init(sources: ["web"], query: "new")).isEmpty)
        #expect(projection.displayRows(in: .init(entries: buffer.entries), matching: filter).isEmpty)
        _ = try await projection.rowsAsync(in: second, matching: filter)
        #expect(projection.displayRows(in: second, matching: filter).map(\.message) == ["old", "new"])
    }
    @MainActor @Test func asynchronousProjectionRejectsLateResultsAndNeverExportsOldFilterRows() async throws {
        let gate = ProjectionGate()
        let projection = ContainerLogProjection(filtering: { snapshot, filter in
            await gate.wait(filter.query)
            return snapshot.entries.filter(filter.includes)
        })
        var buffer = ContainerLogBuffer()
        buffer.append("old\nnew\n", containerID: "web")
        let snapshot = ContainerLogSnapshot(entries: buffer.entries)
        let oldFilter = ContainerLogFilter(sources: ["web"], query: "old")
        let newFilter = ContainerLogFilter(sources: ["web"], query: "new")
        let old = Task { try await projection.rowsAsync(in: snapshot, matching: oldFilter) }
        while await !gate.started("old") { await Task.yield() }
        let new = Task { try await projection.rowsAsync(in: snapshot, matching: newFilter) }
        while await !gate.started("new") { await Task.yield() }
        #expect(projection.cachedRows(in: snapshot, matching: newFilter).isEmpty)
        await gate.release("new")
        #expect(try await new.value.map(\.message) == ["new"])
        await gate.release("old")
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(projection.cachedRows(in: snapshot, matching: newFilter).map(\.message) == ["new"])
        #expect(projection.cachedRows(in: snapshot, matching: oldFilter).isEmpty)
        #expect(ContainerLogBuffer.export(projection.cachedRows(in: snapshot, matching: newFilter)).contains("new"))
        #expect(projection.filterPassCount == 1 && !projection.isFiltering)
    }

    @MainActor @Test func cancellingAsyncFilterDoesNotPublishAndNewSessionCannotReuseIt() async throws {
        let gate = ProjectionGate()
        let projection = ContainerLogProjection(filtering: { snapshot, filter in
            await gate.wait(filter.query)
            return snapshot.entries.filter(filter.includes)
        })
        var buffer = ContainerLogBuffer()
        buffer.append("secret fixture\n", containerID: "web")
        let snapshot = ContainerLogSnapshot(entries: buffer.entries)
        let filter = ContainerLogFilter(sources: ["web"], query: "fixture")
        let pending = Task { try await projection.rowsAsync(in: snapshot, matching: filter) }
        while await !gate.started("fixture") { await Task.yield() }
        pending.cancel()
        await gate.release("fixture")
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(projection.cachedRows(in: snapshot, matching: filter).isEmpty)
        #expect(!projection.isFiltering)
        let production = ContainerLogProjection()
        #expect(try await production.rowsAsync(in: snapshot, matching: filter).count == 1)
        #expect(production.cachedRows(in: .init(entries: []), matching: filter).isEmpty)
    }
    @MainActor @Test func repeatedConsoleCountScrollAndExportReadsFilterOnlyOnce() {
        let date = Date(timeIntervalSince1970: 1_000)
        var buffer = ContainerLogBuffer()
        buffer.append("ready\nTIMEOUT 🌍\n", containerID: "web", at: date)
        buffer.append("timeout db\n", containerID: "db", at: date.addingTimeInterval(10))
        let snapshot = ContainerLogSnapshot(entries: buffer.entries)
        let projection = ContainerLogProjection()
        let filter = ContainerLogFilter(sources: ["web", "db"], query: "timeout")
        for _ in 0..<20 {
            #expect(projection.rows(in: snapshot, matching: filter).map(\.message) == ["TIMEOUT 🌍", "timeout db"])
        }
        #expect(projection.filterPassCount == 1)
        let narrowed = ContainerLogFilter(sources: ["web", "db"], containerID: "web", query: "timeout", range: date...date.addingTimeInterval(5))
        let rows = projection.rows(in: snapshot, matching: narrowed)
        #expect(rows.count == 1)
        #expect(ContainerLogBuffer.export(rows).contains("TIMEOUT 🌍"))
        #expect(!ContainerLogBuffer.export(rows).contains("timeout db"))
        #expect(projection.filterPassCount == 2)
        #expect(projection.rows(in: snapshot, matching: .init(sources: [])).isEmpty)
        #expect(projection.filterPassCount == 3)
    }

    @MainActor @Test func newSnapshotsAndRenamedSourcesCannotReuseStaleProjectionData() {
        let projection = ContainerLogProjection()
        var first = ContainerLogBuffer(maxEntries: 1)
        first.append("old\n", containerID: "web")
        let old = ContainerLogSnapshot(entries: first.entries)
        let filter = ContainerLogFilter(sources: ["web"])
        #expect(projection.rows(in: old, matching: filter).first?.message == "old")
        first.append("new\n", containerID: "web")
        let new = ContainerLogSnapshot(entries: first.entries)
        #expect(projection.rows(in: new, matching: filter).first?.message == "new")
        #expect(projection.filterPassCount == 2)
        // A new Logs session may reuse entry IDs but always has a distinct snapshot identity.
        var replacement = ContainerLogBuffer()
        replacement.append("replacement\n", containerID: "web")
        #expect(projection.rows(in: .init(entries: replacement.entries), matching: filter).first?.message == "replacement")
        #expect(projection.sourceNames(for: [.init(id: "web", title: "Before")])["web"] == "Before")
        #expect(projection.sourceNames(for: [.init(id: "web", title: "After")])["web"] == "After")
        #expect(projection.sourceNames(for: []).isEmpty)
    }
}

private actor ProjectionGate {
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    func wait(_ key: String) async { await withCheckedContinuation { waiters[key] = $0 } }
    func started(_ key: String) -> Bool { waiters[key] != nil }
    func release(_ key: String) { waiters.removeValue(forKey: key)?.resume() }
}
