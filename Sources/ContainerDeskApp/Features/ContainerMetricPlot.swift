import Accessibility
import ContainerDeskCore
import SwiftUI

/// Static chart drawing stays independent of the shared cursor. No per-datum
/// SwiftUI/Charts graph is rebuilt when a snapshot or range changes.
struct ContainerMetricPlot: View, Equatable {
    let metric: ContainerMetricChart.Metric
    let points: [ContainerChartPoint]
    let events: [ContainerHistoryEvent]
    let start: Date
    let end: Date
    let upper: Double
    let sampleCount: Int
    let cache: ContainerMetricPlotPathCache

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cache === rhs.cache && lhs.metric == rhs.metric && lhs.points == rhs.points && lhs.events == rhs.events &&
        lhs.start == rhs.start && lhs.end == rhs.end && lhs.upper == rhs.upper && lhs.sampleCount == rhs.sampleCount
    }

    var body: some View {
        let paths = cache.value(points: points, events: events, start: start, end: end, upper: upper)
        let ticks = ContainerMetricPlotAxis.ticks(upper: upper)
        Canvas { context, size in
            let coordinates = ContainerMetricPlotCoordinates(start: start, end: end, upper: upper, size: size)
            let frame = coordinates.frame
            var plot = context
            plot.clip(to: Path(frame))
            for tick in ticks {
                if let y = coordinates.y(for: tick) {
                    var grid = Path()
                    grid.move(to: CGPoint(x: frame.minX, y: y)); grid.addLine(to: CGPoint(x: frame.maxX, y: y))
                    plot.stroke(grid, with: .color(.secondary.opacity(0.2)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
            }
            let transform = CGAffineTransform(a: frame.width, b: 0, c: 0, d: frame.height, tx: frame.minX, ty: frame.minY)
            plot.fill(paths.area.applying(transform), with: .linearGradient(
                Gradient(colors: [metric.tint.opacity(0.24), metric.tint.opacity(0.025)]),
                startPoint: CGPoint(x: frame.minX, y: frame.minY), endPoint: CGPoint(x: frame.minX, y: frame.maxY)))
            plot.stroke(paths.line.applying(transform), with: .color(metric.tint), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            for rule in paths.eventRules {
                plot.stroke(rule.path.applying(transform), with: .color(rule.kind.chartColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            for tick in ticks {
                if let y = coordinates.y(for: tick) {
                    context.draw(Text(tick, format: .number.precision(.fractionLength(0...2)))
                        .font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                        at: CGPoint(x: frame.minX - 6, y: y), anchor: .trailing)
                }
            }
            let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            context.draw(Text(start, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: frame.minX, y: frame.maxY + 4), anchor: .topLeading)
            context.draw(Text(middle, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: frame.midX, y: frame.maxY + 4), anchor: .top)
            context.draw(Text(end, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: frame.maxX, y: frame.maxY + 4), anchor: .topTrailing)
            if points.isEmpty {
                context.draw(Text("Collecting samples…").font(.caption).foregroundColor(.secondary), at: CGPoint(x: frame.midX, y: frame.midY))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) over the last \(Int(end.timeIntervalSince(start) / 60)) minutes, \(sampleCount) samples, \(events.count) events")
        .accessibilityChartDescriptor(ContainerMetricPlotDescriptor(title: metric.title, unit: metric.unit, points: points, events: events, start: start, end: end, upper: upper, sampleCount: sampleCount))
    }
}

enum ContainerMetricPlotAxis {
    static func ticks(upper: Double) -> [Double] {
        guard upper > 0, upper.isFinite else { return [0] }
        let raw = upper / 2
        let magnitude = pow(10, floor(log10(raw)))
        let fraction = raw / magnitude
        let step = magnitude * (fraction < 1.5 ? 1 : fraction < 3 ? 2 : fraction < 7 ? 5 : 10)
        guard step > 0, step.isFinite else { return [0] }
        return (0...min(4, Int(upper / step))).map { Double($0) * step }
    }
}

/// VoiceOver receives the plotted values and explicit discontinuities, not just
/// a bitmap. Descriptors are built on accessibility demand, outside rendering.
struct ContainerMetricPlotDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let unit: String
    let points: [ContainerChartPoint]
    let events: [ContainerHistoryEvent]
    let start: Date
    let end: Date
    let upper: Double
    let sampleCount: Int

    func makeChartDescriptor() -> AXChartDescriptor {
        let start = start.timeIntervalSince1970, end = end.timeIntervalSince1970
        let x = AXNumericDataAxisDescriptor(title: "Time", range: start...end, gridlinePositions: [start, (start + end) / 2, end]) {
            Date(timeIntervalSince1970: $0).formatted(.dateTime.month().day().hour().minute().second())
        }
        let unit = unit
        let y = AXNumericDataAxisDescriptor(title: title, range: 0...upper, gridlinePositions: ContainerMetricPlotAxis.ticks(upper: upper)) {
            $0.formatted(.number.precision(.fractionLength(0...2))) + " " + unit
        }
        var series = ContainerMetricPlotPaths.segments(points).map { segment in
            AXDataSeriesDescriptor(name: title, isContinuous: true, dataPoints: segment.map {
                AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value)
            })
        }
        for kind in [ContainerHistoryEvent.Kind.restart, .exit, .limits] {
            let matching = events.filter { $0.kind == kind }
            if !matching.isEmpty {
                series.append(AXDataSeriesDescriptor(name: kind.rawValue, isContinuous: false, dataPoints: matching.map {
                    AXDataPoint(x: $0.date.timeIntervalSince1970, y: 0, label: $0.detail)
                }))
            }
        }
        return AXChartDescriptor(title: title, summary: "\(sampleCount) samples, \(events.count) events. Gaps indicate missing samples.", xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let updated = makeChartDescriptor()
        descriptor.title = updated.title; descriptor.summary = updated.summary
        descriptor.xAxis = updated.xAxis; descriptor.yAxis = updated.yAxis; descriptor.series = updated.series
    }
}
