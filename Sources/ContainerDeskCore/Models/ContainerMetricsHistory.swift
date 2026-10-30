import Foundation

public struct ContainerHistorySample: Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let metric: ContainerMetric
    public let cpuLimit: Int?
    public let memoryLimit: Int64?
    public var cpuOfLimit: Double? {
        ContainerCPUUsage.allocationPercent(oneCorePercent: metric.cpuPercent, allocatedCPUs: cpuLimit)
    }
    public var memoryOfLimit: Double? {
        guard let usage = metric.memoryUsageBytes, let memoryLimit, memoryLimit > 0 else { return nil }
        return Double(usage) / Double(memoryLimit) * 100
    }
}

public struct ContainerHistoryEvent: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case restart = "Restart", exit = "Exit", limits = "Limit change" }
    public let id = UUID()
    public let date: Date
    public let containerID: String
    public let kind: Kind
    public let detail: String
    public let unexpected: Bool
}

/// Session history from successful reads only. Missing/failed reads never synthesize zero usage.
public struct ContainerMetricsHistory: Sendable {
    private var sampleBuffers: [String: HistorySamples] = [:]
    /// Compatibility/export snapshot. Interactive callers request only their container.
    public var samples: [String: [ContainerHistorySample]] { sampleBuffers.mapValues { $0.snapshot } }
    public var containerCount: Int { sampleBuffers.count }
    public func samples(for id: String) -> [ContainerHistorySample] { sampleBuffers[id]?.snapshot ?? [] }
    public func latestSample(for id: String) -> ContainerHistorySample? { sampleBuffers[id]?.last }

    public private(set) var events: [ContainerHistoryEvent] = []
    private var inventory: [String: ResourceSummary] = [:]
    private var hasRun = Set<String>()
    private var recordedRestarts: [String: Date] = [:]
    private var knownLimits: [String: String] = [:]
    private var lastSeen: [String: Date] = [:]
    public static let retention: TimeInterval = 3_600

    public init() {}

    /// History is chronological. A cursor in a collection gap must not show an unrelated sample.
    public static func nearestSample(to date: Date, in samples: [ContainerHistorySample], maximumDistance: TimeInterval = 10) -> ContainerHistorySample? {
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        let candidates = [lower - 1, lower].filter { samples.indices.contains($0) }.map { samples[$0] }
        guard let sample = candidates.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(sample.date.timeIntervalSince(date)) <= maximumDistance else { return nil }
        return sample
    }

    @discardableResult
    public mutating func observe(_ containers: [ResourceSummary], expectedExits: Set<String> = [], at date: Date = .now) -> [ContainerHistoryEvent] {
        prune(at: date)
        let next = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var added: [ContainerHistoryEvent] = []
        for old in inventory.values where Self.running(old) && !Self.running(next[old.id]) {
            added.append(event(old.id, .exit, expectedExits.contains(old.id) ? "Container stopped by an app action" : "Container stopped or disappeared from the runtime", at: date, unexpected: !expectedExits.contains(old.id)))
        }
        for item in containers {
            lastSeen[item.id] = date
            if Self.running(item) {
                if hasRun.contains(item.id), !Self.running(inventory[item.id]) {
                    if recordedRestarts.removeValue(forKey: item.id).map({ date.timeIntervalSince($0) < 30 }) != true {
                        added.append(event(item.id, .restart, "Container is running again", at: date))
                    }
                }
                recordedRestarts[item.id] = nil
                hasRun.insert(item.id)
            }
            if let old = knownLimits[item.id], old != Self.limits(item) {
                let cpu = (item.details.cpuCount ?? item.details.cpuAllocation).map(String.init) ?? "unknown"
                let memory = (item.details.memoryLimitBytes ?? item.details.memoryBytes).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "unknown"
                added.append(event(item.id, .limits, "CPU limit: \(cpu) · Memory limit: \(memory)", at: date))
            }
            knownLimits[item.id] = Self.limits(item)
        }
        inventory = next
        events.append(contentsOf: added)
        return added
    }

    /// Captures fast app restarts that can happen entirely between inventory polls.
    public mutating func recordRestart(_ id: String, at date: Date = .now) {
        prune(at: date)
        guard hasRun.contains(id) else { return }
        if events.last(where: { $0.containerID == id && $0.kind == .restart }).map({ date.timeIntervalSince($0.date) < 2 }) == true { return }
        events.append(event(id, .restart, "Container restarted by an app action", at: date))
        recordedRestarts[id] = date
    }

    public mutating func append(_ metrics: [String: ContainerMetric], containers: [ResourceSummary], at date: Date = .now) {
        prune(at: date)
        for container in containers {
            guard let metric = metrics[container.id], Self.running(container) else { continue }
            let sample = ContainerHistorySample(date: date, metric: metric, cpuLimit: container.details.cpuCount ?? container.details.cpuAllocation, memoryLimit: container.details.memoryLimitBytes ?? container.details.memoryBytes)
            sampleBuffers[container.id, default: HistorySamples()].append(sample)
        }
    }

    public mutating func prune(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        for id in Array(sampleBuffers.keys) {
            sampleBuffers[id]?.prune(before: cutoff)
            if sampleBuffers[id]?.isEmpty == true { sampleBuffers[id] = nil }
        }
        events.removeAll { $0.date < cutoff }
        if events.count > 5_000 { events.removeFirst(events.count - 5_000) }
        recordedRestarts = recordedRestarts.filter { date.timeIntervalSince($0.value) < 30 }
        lastSeen = lastSeen.filter { $0.value >= cutoff }
        hasRun.formIntersection(Set(lastSeen.keys))
        knownLimits = knownLimits.filter { lastSeen[$0.key] != nil }
    }

    private func event(_ id: String, _ kind: ContainerHistoryEvent.Kind, _ detail: String, at date: Date, unexpected: Bool = false) -> ContainerHistoryEvent {
        ContainerHistoryEvent(date: date, containerID: id, kind: kind, detail: detail, unexpected: unexpected)
    }
    private static func running(_ item: ResourceSummary?) -> Bool { item?.state?.lowercased() == "running" }
    private static func limits(_ item: ResourceSummary) -> String {
        "\(item.details.cpuCount ?? item.details.cpuAllocation ?? 0):\(item.details.memoryLimitBytes ?? item.details.memoryBytes ?? 0)"
    }
}

/// Value-semantic bounded queue; published arrays never share mutable storage with it.
private struct HistorySamples: Sendable {
    private var storage: [ContainerHistorySample] = []
    private var head = 0
    var isEmpty: Bool { head == storage.count }
    var last: ContainerHistorySample? { isEmpty ? nil : storage.last }
    var snapshot: [ContainerHistorySample] { Array(storage[head...]) }

    mutating func append(_ sample: ContainerHistorySample) {
        if let last, sample.date <= last.date { return }
        storage.append(sample)
        head = max(head, storage.count - 3_601)
        compactIfNeeded()
    }

    mutating func prune(before date: Date) {
        while head < storage.count, storage[head].date < date { head += 1 }
        compactIfNeeded()
    }

    private mutating func compactIfNeeded() {
        if head == storage.count { storage.removeAll(keepingCapacity: false); head = 0 }
        else if head >= 1_024, head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
    }
}
