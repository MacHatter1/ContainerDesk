import Charts
import ContainerDeskCore
import SwiftUI

struct ContainerMetricChart: View {
    enum Metric: Equatable {
        case cpu(normalized: Bool), memory
        var title: String { switch self { case .cpu: "CPU"; case .memory: "Memory" } }
        var symbol: String { switch self { case .cpu: "cpu"; case .memory: "memorychip" } }
        var unit: String { switch self { case .cpu: "%"; case .memory: "MiB" } }
        var subtitle: String {
            switch self { case .cpu(let normalized): normalized ? "of configured limit" : "of one core"; case .memory: "memory in use" }
        }
        var tint: Color { switch self { case .cpu: .blue; case .memory: .purple } }
        func value(_ sample: ContainerHistorySample) -> Double? {
            switch self {
            case .cpu(let normalized): normalized ? sample.cpuOfLimit : sample.metric.cpuPercent
            case .memory: sample.metric.memoryUsageBytes.map { Double($0) / 1_048_576 }
            }
        }
    }

    let metric: Metric
    let samples: [ContainerHistorySample]
    let events: [ContainerHistoryEvent]
    let start: Date
    let end: Date
    @Binding var selectedDate: Date?
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var projection = ContainerMetricSeriesProjection()
    @State private var plotWidth = 600

    private var chartMetric: ContainerChartMetric {
        switch metric { case .cpu(let normalized): .cpu(normalized: normalized); case .memory: .memory }
    }

    var body: some View {
        let series = projection.value(samples: samples, events: events, metric: chartMetric, maximumPoints: max(64, plotWidth * 2))
        let points = series.points
        let peak = series.peak
        let average = series.average
        let unitSuffix = metric.unit == "%" ? "%" : " \(metric.unit)"
        let upper = max(1, peak * 1.12)
        VStack(alignment: .leading, spacing: 14) {
            ContainerMetricReadout(metric: metric, samples: samples, latest: points.last, selectedDate: $selectedDate)
            ContainerMetricPlot(metric: metric, points: points, events: events, start: start, end: end, upper: upper, sampleCount: series.sampleCount)
                .equatable()
                .chartOverlay { proxy in
                    ContainerMetricCursor(metric: metric, samples: samples, latest: points.last, proxy: proxy, selectedDate: $selectedDate)
                }
                .frame(height: 112)
                .onGeometryChange(for: Int.self) { max(1, Int($0.size.width.rounded())) } action: { plotWidth = $0 }
            HStack {
                Text(String(format: "Avg %.1f%@", average, unitSuffix))
                Spacer()
                Text(String(format: "Peak %.1f%@", peak, unitSuffix))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [metric.tint.opacity(0.055), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
        }
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : metric.tint.opacity(0.16)) }
    }

}

/// Cursor state stays outside the static Swift Charts content. Equality covers
/// every plot input, so new samples, events, domains and CPU mode still redraw.
private struct ContainerMetricPlot: View, Equatable {
    let metric: ContainerMetricChart.Metric
    let points: [ContainerChartPoint]
    let events: [ContainerHistoryEvent]
    let start: Date
    let end: Date
    let upper: Double
    let sampleCount: Int

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date), y: .value(metric.title, point.value), series: .value("Segment", point.segment))
                    .foregroundStyle(LinearGradient(colors: [metric.tint.opacity(0.24), metric.tint.opacity(0.025)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value), series: .value("Segment", point.segment))
                    .foregroundStyle(metric.tint).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(events) { event in
                RuleMark(x: .value("Event", event.date)).foregroundStyle(event.kind.chartColor.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...upper)
        .chartXAxis {
            AxisMarks(values: [start, start.addingTimeInterval(end.timeIntervalSince(start) / 2), end]) { tick in
                let date = tick.as(Date.self) ?? start
                AxisValueLabel(centered: false, anchor: date == end ? .topTrailing : date == start ? .topLeading : .top) {
                    Text(date, format: .dateTime.hour().minute())
                }
                    .font(.caption2.monospacedDigit())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel().font(.caption2.monospacedDigit())
            }
        }
        .overlay {
            if points.isEmpty { Text("Collecting samples…").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityLabel("\(metric.title) over the last \(Int(end.timeIntervalSince(start) / 60)) minutes, \(sampleCount) samples, \(events.count) events")
    }

}

/// A shared interpretation for the readout and marker, including collection gaps.
struct ContainerMetricSelection {
    let date: Date?
    let value: Double?
    let isSelected: Bool

    init(metric: ContainerMetricChart.Metric, samples: [ContainerHistorySample], latest: ContainerChartPoint?, selectedDate: Date?) {
        isSelected = selectedDate != nil
        if let selectedDate {
            let sample = ContainerMetricsHistory.nearestSample(to: selectedDate, in: samples)
            date = sample?.date ?? selectedDate
            value = sample.flatMap(metric.value).flatMap { $0.isFinite ? max(0, $0) : nil }
        } else {
            date = latest?.date
            value = latest?.value
        }
    }
}

private struct ContainerMetricReadout: View {
    let metric: ContainerMetricChart.Metric
    let samples: [ContainerHistorySample]
    let latest: ContainerChartPoint?
    @Binding var selectedDate: Date?

    var body: some View {
        let selection = ContainerMetricSelection(metric: metric, samples: samples, latest: latest, selectedDate: selectedDate)
        let value = selection.value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Label(metric.title, systemImage: metric.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(metric.tint)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                    Text(metric.unit).font(.callout).foregroundStyle(.secondary)
                }
                Text(metric.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(selection.isSelected ? "SELECTED" : "LATEST")
                .font(.caption2.weight(.semibold)).tracking(0.7).foregroundStyle(metric.tint)
                .padding(.horizontal, 7).padding(.vertical, 4).background(metric.tint.opacity(0.09), in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) \(selection.isSelected ? "selected" : "latest"), \(value) \(metric.unit), \(metric.subtitle)")
    }
}

private struct ContainerMetricCursor: View {
    let metric: ContainerMetricChart.Metric
    let samples: [ContainerHistorySample]
    let latest: ContainerChartPoint?
    let proxy: ChartProxy
    @Binding var selectedDate: Date?

    var body: some View {
        let selection = ContainerMetricSelection(metric: metric, samples: samples, latest: latest, selectedDate: selectedDate)
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let frame = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    if let date = selection.date, let x = proxy.position(forX: date) {
                        if selection.isSelected {
                            Path { path in
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: frame.height))
                            }
                            .stroke(.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        }
                        if let value = selection.value, let y = proxy.position(forY: value) {
                            Circle().fill(metric.tint)
                                .frame(width: selection.isSelected ? 6 : 5, height: selection.isSelected ? 6 : 5)
                                .padding(selection.isSelected ? 2 : 0)
                                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                                .position(x: x, y: y)
                        }
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): inspect(location, frame: proxy.plotFrame.map { geometry[$0] })
                    case .ended: selectedDate = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { inspect($0.location, frame: proxy.plotFrame.map { geometry[$0] }) })
        }
    }

    private func inspect(_ location: CGPoint, frame: CGRect?) {
        guard let frame, frame.contains(location), let date = proxy.value(atX: location.x - frame.minX, as: Date.self) else {
            selectedDate = nil
            return
        }
        selectedDate = ContainerMetricsHistory.nearestSample(to: date, in: samples)?.date ?? date
    }
}

extension ContainerHistoryEvent.Kind {
    var chartColor: Color { switch self { case .restart: .blue; case .exit: .red; case .limits: .orange } }
}
