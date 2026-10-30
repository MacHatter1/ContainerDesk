import Foundation
import Observation

public struct ContainerLogSnapshot: Sendable {
    public let id = UUID()
    public let sessionID: UUID
    public let entries: [ContainerLogEntry]
    public init(entries: [ContainerLogEntry], sessionID: UUID = UUID()) { self.entries = entries; self.sessionID = sessionID }
}

public struct ContainerLogFilter: Hashable, Sendable {
    public var sources: Set<String>
    public var containerID: String
    public var query: String
    public var range: ClosedRange<Date>?

    public init(sources: Set<String>, containerID: String = "", query: String = "", range: ClosedRange<Date>? = nil) {
        self.sources = sources; self.containerID = containerID; self.query = query; self.range = range
    }

    public func includes(_ entry: ContainerLogEntry) -> Bool {
        sources.contains(entry.containerID) && (containerID.isEmpty || entry.containerID == containerID)
            && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
            && (range == nil || range!.contains(entry.receivedAt))
    }
}

/// A scene-owned projection. Selection, scrolling and export reuse the same filtered rows.
@MainActor @Observable public final class ContainerLogProjection {
    private var snapshotID: UUID?
    private var sessionID: UUID?
    private var filter: ContainerLogFilter?
    private var result: [ContainerLogEntry] = []
    private var containers: [ResourceSummary] = []
    private var names: [String: String] = [:]
    private(set) var filterPassCount = 0
    public private(set) var isFiltering = false
    @ObservationIgnored private var worker: Task<[ContainerLogEntry], Error>?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private let filtering: @Sendable (ContainerLogSnapshot, ContainerLogFilter) async throws -> [ContainerLogEntry]

    public init() { filtering = Self.filterRows }

    init(filtering: @escaping @Sendable (ContainerLogSnapshot, ContainerLogFilter) async throws -> [ContainerLogEntry]) {
        self.filtering = filtering
    }

    /// A nonblocking read. A changed query/session never displays or exports old matching rows.
    public func cachedRows(in snapshot: ContainerLogSnapshot, matching filter: ContainerLogFilter) -> [ContainerLogEntry] {
        snapshotID == snapshot.id && self.filter == filter ? result : []
    }

    /// Keep the last coherent publication visible while newer lines are filtered.
    /// A query/source/range or runtime/session change hides it immediately.
    public func displayRows(in snapshot: ContainerLogSnapshot, matching filter: ContainerLogFilter) -> [ContainerLogEntry] {
        sessionID == snapshot.sessionID && self.filter == filter ? result : []
    }

    public func rowsAsync(in snapshot: ContainerLogSnapshot, matching filter: ContainerLogFilter) async throws -> [ContainerLogEntry] {
        try Task.checkCancellation()
        if snapshotID == snapshot.id, self.filter == filter { return result }
        worker?.cancel()
        let id = UUID()
        requestID = id
        isFiltering = true
        let filtering = filtering
        let task = Task.detached(priority: .userInitiated) { try await filtering(snapshot, filter) }
        worker = task
        defer {
            if requestID == id { worker = nil; requestID = nil; isFiltering = false }
        }
        let rows = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
        snapshotID = snapshot.id
        sessionID = snapshot.sessionID
        self.filter = filter
        result = rows
        filterPassCount += 1
        return rows
    }

    nonisolated private static func filterRows(_ snapshot: ContainerLogSnapshot, _ filter: ContainerLogFilter) async throws -> [ContainerLogEntry] {
        var rows: [ContainerLogEntry] = []
        for (index, entry) in snapshot.entries.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if filter.includes(entry) { rows.append(entry) }
        }
        try Task.checkCancellation()
        return rows
    }

    public func rows(in snapshot: ContainerLogSnapshot, matching filter: ContainerLogFilter) -> [ContainerLogEntry] {
        worker?.cancel()
        worker = nil
        requestID = nil
        isFiltering = false
        if snapshotID != snapshot.id || self.filter != filter {
            if filter.containerID.isEmpty, filter.range == nil {
                let sources = filter.sources
                let query = filter.query
                result = snapshot.entries.filter {
                    sources.contains($0.containerID) && (query.isEmpty || $0.message.localizedCaseInsensitiveContains(query))
                }
            } else {
                result = snapshot.entries.filter(filter.includes)
            }
            snapshotID = snapshot.id
            sessionID = snapshot.sessionID
            self.filter = filter
            filterPassCount += 1
        }
        return result
    }

    public func sourceNames(for containers: [ResourceSummary]) -> [String: String] {
        if self.containers != containers {
            names = Dictionary(containers.map { ($0.id, $0.title) }, uniquingKeysWith: { _, last in last })
            self.containers = containers
        }
        return names
    }
}
