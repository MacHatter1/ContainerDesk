import Foundation
import Testing
@testable import ContainerDeskCore

struct ContainerMetricSeriesTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func sample(_ seconds: Double, cpu: Double?, memory: Int64? = 1_048_576) -> ContainerHistorySample {
        .init(date: start.addingTimeInterval(seconds), metric: .init(cpuPercent: cpu, memoryUsageBytes: memory), cpuLimit: 2, memoryLimit: 4_194_304)
    }
    private func event(_ seconds: Double, _ kind: ContainerHistoryEvent.Kind) -> ContainerHistoryEvent {
        .init(date: start.addingTimeInterval(seconds), containerID: "web", kind: kind, detail: "fixture", unexpected: false)
    }

    @Test func segmentationPreservesGapsMissingValuesAndEventBoundarySemantics() {
        let samples = [sample(0, cpu: -5), sample(1, cpu: nil), sample(2, cpu: 40), sample(3, cpu: .infinity), sample(20, cpu: 80), sample(21, cpu: 20)]
        // Deliberately unordered: events at the previous sample don't split it again.
        let events = [event(21, .limits), event(20, .restart), event(0, .exit), event(2, .exit)]
        let series = ContainerMetricSeries.build(samples: samples, events: events, metric: .cpu(normalized: false))
        #expect(series.points.map(\.segment) == [0, 2, 4, 4])
        #expect(series.points.map(\.value) == [0, 40, 80, 20])
        #expect(series.peak == 80 && series.average == 35 && series.sampleCount == 4)
        let normalized = ContainerMetricSeries.build(samples: samples, events: events, metric: .cpu(normalized: true))
        #expect(normalized.peak == 40 && normalized.average == 70.0 / 3 && normalized.sampleCount == 3)
        let memory = ContainerMetricSeries.build(samples: samples, events: [], metric: .memory)
        #expect(memory.points.count == samples.count && memory.average == 1)
    }

    @Test func downsamplingRetainsSpikesEndpointsAndBothSidesOfDiscontinuities() {
        let samples = (0..<3_600).map { sample(Double($0), cpu: $0 == 1_234 ? 900 : ($0 == 2_345 ? 0 : 10)) }
        let events = [event(2_000, .exit)]
        let full = ContainerMetricSeries.build(samples: samples, events: events, metric: .cpu(normalized: false))
        let plot = ContainerMetricSeries.build(samples: samples, events: events, metric: .cpu(normalized: false), maximumPoints: 300)
        #expect(plot.points.count <= 304)
        #expect(plot.points.first == full.points.first && plot.points.last == full.points.last)
        #expect(plot.points.contains { $0.value == 900 })
        #expect(plot.points.contains { $0.date == start.addingTimeInterval(1_999) })
        #expect(plot.points.contains { $0.date == start.addingTimeInterval(2_000) })
        #expect(plot.peak == full.peak && plot.average == full.average && plot.sampleCount == 3_600)
        #expect(zip(plot.points, plot.points.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    @Test func linearProjectionMatchesTheOriginalTransformAcrossMixedEventsAndMetrics() {
        var date = 0.0
        let samples = (0..<300).map { index -> ContainerHistorySample in
            date += index.isMultiple(of: 31) ? 15 : 1
            return sample(date, cpu: index.isMultiple(of: 17) ? nil : Double(index % 80), memory: index.isMultiple(of: 23) ? nil : Int64(index * 1_048_576))
        }
        let kinds: [ContainerHistoryEvent.Kind] = [.limits, .restart, .exit]
        let events = (0..<100).reversed().map { event(Double($0) * 4.7, kinds[$0 % 3]) }
        for metric in [ContainerChartMetric.cpu(normalized: false), .cpu(normalized: true), .memory] {
            var previous: Date?
            var segment = 0
            var original: [ContainerChartPoint] = []
            for sample in samples {
                guard let value = metric.value(sample), value.isFinite else { segment += 1; continue }
                if let previous, sample.date.timeIntervalSince(previous) > 10 || events.contains(where: { $0.date > previous && $0.date <= sample.date && $0.kind != .limits }) { segment += 1 }
                original.append(.init(date: sample.date, value: max(0, value), segment: segment))
                previous = sample.date
            }
            #expect(ContainerMetricSeries.build(samples: samples, events: events, metric: metric).points == original)
        }
    }

    @MainActor @Test func hoverReusesSeriesAndEveryRelevantInputInvalidatesIt() {
        let projection = ContainerMetricSeriesProjection()
        let samples = [sample(0, cpu: 20), sample(1, cpu: 40)]
        for _ in 0..<20 { _ = projection.value(samples: samples, events: [], metric: .cpu(normalized: false)) }
        #expect(projection.buildCount == 1)
        _ = projection.value(samples: samples, events: [event(1, .exit)], metric: .cpu(normalized: false))
        _ = projection.value(samples: samples, events: [], metric: .memory)
        _ = projection.value(samples: samples, events: [], metric: .memory, maximumPoints: 64)
        _ = projection.value(samples: samples + [sample(2, cpu: 60)], events: [], metric: .memory, maximumPoints: 64)
        #expect(projection.buildCount == 5)
        #expect(ContainerMetricSeries.build(samples: [], events: [], metric: .memory).points.isEmpty)
    }

    @Test func boundedHistoryQueuePreservesSnapshotsPrunesAndRejectsDuplicateDates() {
        var history = ContainerMetricsHistory()
        let containers = [ResourceSummary(id: "web", title: "Web", state: "running")]
        for tick in 0..<5_000 { history.append(["web": .init(cpuPercent: Double(tick))], containers: containers, at: start.addingTimeInterval(Double(tick))) }
        let snapshot = history.samples(for: "web")
        #expect(snapshot.count == 3_601 && snapshot.first?.metric.cpuPercent == 1_399)
        var copy = history
        history.append(["web": .init(cpuPercent: -1)], containers: containers, at: start.addingTimeInterval(4_999))
        #expect(history.samples(for: "web") == snapshot)
        history.append(["web": .init(cpuPercent: 5_000)], containers: containers, at: start.addingTimeInterval(5_000))
        #expect(history.latestSample(for: "web")?.metric.cpuPercent == 5_000)
        #expect(copy.samples(for: "web") == snapshot)
        copy.prune(at: start.addingTimeInterval(10_000))
        #expect(copy.containerCount == 0 && copy.samples.isEmpty)
        #expect(history.containerCount == 1 && snapshot.count == 3_601)
    }
}
