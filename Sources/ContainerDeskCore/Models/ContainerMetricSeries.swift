import Foundation

public enum ContainerChartMetric: Hashable, Sendable {
    case cpu(normalized: Bool), memory
    public func value(_ sample: ContainerHistorySample) -> Double? {
        switch self {
        case .cpu(let normalized): normalized ? sample.cpuOfLimit : sample.metric.cpuPercent
        case .memory: sample.metric.memoryUsageBytes.map { Double($0) / 1_048_576 }
        }
    }
}

public struct ContainerChartPoint: Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let value: Double
    public let segment: Int
}

public struct ContainerMetricSeries: Sendable {
    public let points: [ContainerChartPoint]
    public let sampleCount: Int
    public let peak: Double
    public let average: Double

    public static func build(samples: [ContainerHistorySample], events: [ContainerHistoryEvent], metric: ContainerChartMetric, maximumPoints: Int = .max) -> Self {
        let breaks = events.filter { $0.kind != .limits }.map(\.date).sorted()
        var cursor = 0
        var previous: Date?
        var segment = 0
        var points: [ContainerChartPoint] = []
        points.reserveCapacity(samples.count)
        var total = 0.0
        var peak = 0.0
        for sample in samples {
            guard let raw = metric.value(sample), raw.isFinite else { segment += 1; continue }
            if let previous {
                while cursor < breaks.count, breaks[cursor] <= previous { cursor += 1 }
                if sample.date.timeIntervalSince(previous) > 10 || (cursor < breaks.count && breaks[cursor] <= sample.date) { segment += 1 }
            }
            let value = max(0, raw)
            points.append(.init(date: sample.date, value: value, segment: segment))
            total += value
            peak = max(peak, value)
            previous = sample.date
        }
        return Self(points: downsample(points, maximumPoints: maximumPoints), sampleCount: points.count, peak: peak, average: points.isEmpty ? 0 : total / Double(points.count))
    }

    /// Preserve segment boundaries and each bucket's extrema; hover still uses raw history.
    private static func downsample(_ points: [ContainerChartPoint], maximumPoints: Int) -> [ContainerChartPoint] {
        let limit = max(4, maximumPoints)
        guard points.count > limit else { return points }
        let width = Int(ceil(Double(points.count) / Double(max(1, (limit - 2) / 2))))
        var indices: Set<Int> = [0, points.count - 1]
        for start in stride(from: 0, to: points.count, by: width) {
            let end = min(points.count, start + width)
            var minimum = start
            var maximum = start
            for index in start..<end {
                if points[index].value < points[minimum].value { minimum = index }
                if points[index].value > points[maximum].value { maximum = index }
                if index > 0, points[index].segment != points[index - 1].segment { indices.insert(index - 1); indices.insert(index) }
            }
            indices.insert(minimum); indices.insert(maximum)
        }
        return indices.sorted().map { points[$0] }
    }
}

/// View-owned derived data. Cursor changes reuse the same plot and statistics.
@MainActor public final class ContainerMetricSeriesProjection {
    private var samples: [ContainerHistorySample] = []
    private var events: [ContainerHistoryEvent] = []
    private var metric: ContainerChartMetric?
    private var maximumPoints = 0
    private var series: ContainerMetricSeries?
    private(set) var buildCount = 0
    public init() {}

    public func value(samples: [ContainerHistorySample], events: [ContainerHistoryEvent], metric: ContainerChartMetric, maximumPoints: Int = .max) -> ContainerMetricSeries {
        if self.samples != samples || self.events != events || self.metric != metric || self.maximumPoints != maximumPoints || series == nil {
            self.samples = samples; self.events = events; self.metric = metric; self.maximumPoints = maximumPoints
            series = ContainerMetricSeries.build(samples: samples, events: events, metric: metric, maximumPoints: maximumPoints)
            buildCount += 1
        }
        return series!
    }
}
