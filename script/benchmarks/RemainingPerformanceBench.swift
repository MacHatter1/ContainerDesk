import Foundation

nonisolated(unsafe) private var checksum = 0
private func milliseconds(_ start: ContinuousClock.Instant) -> Double {
    let parts = start.duration(to: .now).components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}
@inline(never) private func measure(_ operation: () -> Int) -> [Double] {
    checksum &+= operation()
    return (0..<7).map { _ in
        let start = ContinuousClock.now
        let value = operation()
        let duration = milliseconds(start)
        checksum &+= value
        return duration
    }
}

#if !OPTIMIZED_REMAINING
// Exact pre-fix segmentation semantics, plus the same statistics read by the chart body.
@inline(never) private func originalChart(_ samples: [ContainerHistorySample], _ events: [ContainerHistoryEvent]) -> Int {
    var segment = 0
    var previous: Date?
    var points: [(Date, Double, Int)] = []
    for sample in samples {
        guard let value = sample.metric.cpuPercent, value.isFinite else { segment += 1; continue }
        if let previous, sample.date.timeIntervalSince(previous) > 10 || events.contains(where: { $0.date > previous && $0.date <= sample.date && $0.kind != .limits }) { segment += 1 }
        points.append((sample.date, max(0, value), segment))
        previous = sample.date
    }
    let peak = points.map { $0.1 }.max() ?? 0
    let average = points.isEmpty ? 0 : points.reduce(0) { $0 + $1.1 } / Double(points.count)
    return points.count + Int(peak + average) + (points.last?.2 ?? 0)
}
#endif

@main struct RemainingPerformanceBench {
    @MainActor static func main() async throws {
        var results: [[String: Any]] = []
        let start = Date(timeIntervalSince1970: 1_000_000)
        let samples = (0..<3_600).map { ContainerHistorySample(date: start.addingTimeInterval(Double($0)), metric: .init(cpuPercent: 20, memoryUsageBytes: 1_024), cpuLimit: 2, memoryLimit: 4_096) }
        for count in [100, 1_000, 5_000] {
            let events = (0..<count).map { ContainerHistoryEvent(date: start.addingTimeInterval(Double($0) * 3_600 / Double(count)), containerID: "web", kind: .limits, detail: "Limit changed", unexpected: false) }
            #if OPTIMIZED_REMAINING
            let projection = ContainerMetricSeriesProjection()
            #endif
            for cached in [false, true] {
                let times = measure {
                    var value = 0
                    for _ in 0..<(cached ? 5 : 1) {
                        #if OPTIMIZED_REMAINING
                        let series = cached ? projection.value(samples: samples, events: events, metric: .cpu(normalized: false)) : ContainerMetricSeries.build(samples: samples, events: events, metric: .cpu(normalized: false))
                        value += series.points.count + Int(series.peak + series.average) + (series.points.last?.segment ?? 0)
                        #else
                        value += originalChart(samples, events)
                        #endif
                    }
                    return value
                }
                results.append(["name": "chart_\(cached ? "5_hover_reads" : "rebuild")_3600_samples_\(count)_events", "milliseconds": times])
            }
        }
        for count in [1, 10, 100] {
            var history = ContainerMetricsHistory()
            let containers = (0..<count).map { ResourceSummary(id: "id\($0)", title: "name\($0)", state: "running") }
            let metrics = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, ContainerMetric(cpuPercent: 20, memoryUsageBytes: 1_024)) })
            for tick in 0..<3_600 { history.append(metrics, containers: containers, at: start.addingTimeInterval(Double(tick))) }
            var tick = 3_600
            let times = measure {
                history.append(metrics, containers: containers, at: start.addingTimeInterval(Double(tick)))
                tick += 1
                #if OPTIMIZED_REMAINING
                return history.containerCount
                #else
                return history.samples.count
                #endif
            }
            // Semantic checks run outside the timed append.
            let retained = history.samples["id0"] ?? []
            checksum &+= retained.count + Int(retained.last?.metric.cpuPercent ?? 0) + Int(retained.first?.date.timeIntervalSince(start) ?? 0)
            results.append(["name": "history_append_3600_samples_\(count)_containers", "milliseconds": times])
        }

        var buffer = ContainerLogBuffer()
        buffer.append(String(repeating: "request processed successfully; response=200 latency=25ms\n", count: 20_000), containerID: "web", at: start)
        let entries = buffer.entries
        let projection = ContainerLogProjection()
        let filter = ContainerLogFilter(sources: ["web"], query: "response")
        var elapsed: [Double] = []
        var actorDelay: [Double] = []
        for iteration in 0..<8 {
            let snapshot = ContainerLogSnapshot(entries: entries)
            let begin = ContinuousClock.now
            let heartbeat = Task { @MainActor in milliseconds(begin) }
            #if OPTIMIZED_REMAINING
            let rows = try await projection.rowsAsync(in: snapshot, matching: filter)
            #else
            let rows = projection.rows(in: snapshot, matching: filter)
            #endif
            let total = milliseconds(begin)
            let delay = await heartbeat.value
            checksum &+= rows.count + (rows.first?.id ?? 0) + (rows.last?.id ?? 0) + (rows.last?.message.utf8.count ?? 0)
            if iteration > 0 { elapsed.append(total); actorDelay.append(delay) }
        }
        results.append(["name": "fresh_log_filter_completion_20000", "milliseconds": elapsed])
        results.append(["name": "fresh_log_filter_main_actor_delay_20000", "milliseconds": actorDelay])
        let data = try JSONSerialization.data(withJSONObject: ["results": results, "checksum": checksum], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
