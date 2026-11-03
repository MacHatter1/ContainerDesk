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
    @State private var presentation = ContainerMetricChartPresentation()
    @State private var plotWidth = 600

    private var chartMetric: ContainerChartMetric {
        switch metric { case .cpu(let normalized): .cpu(normalized: normalized); case .memory: .memory }
    }

    var body: some View {
        let projection = presentation.series
        let series = projection.value(samples: samples, events: events, metric: chartMetric, maximumPoints: max(64, plotWidth * 2))
        let points = series.points
        let formatting = presentation.formatting.prepared(points: points, locale: .current)
        let peak = series.peak
        let average = series.average
        let unitSuffix = metric.unit == "%" ? "%" : " \(metric.unit)"
        let domain = ContainerMetricPlotDomain(start: start, end: end, upper: max(1, peak * 1.12))
        VStack(alignment: .leading, spacing: 14) {
            ContainerMetricReadout(metric: metric, samples: samples, latest: points.last, selectedDate: $selectedDate, formatting: formatting)
            ContainerMetricPlot(metric: metric, points: points, events: events, domain: domain, sampleCount: series.sampleCount, cache: presentation.paths)
                .equatable()
                .overlay {
                    ContainerMetricCursor(metric: metric, samples: samples, latest: points.last, domain: domain, selectedDate: $selectedDate)
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

    let formatting: ContainerMetricReadoutFormatting

    var body: some View {
        let selection = ContainerMetricSelection(metric: metric, samples: samples, latest: latest, selectedDate: selectedDate)
        let value = formatting.string(selection.value, locale: .current)
        ContainerMetricReadoutValue(metric: metric, value: value, isSelected: selection.isSelected)
            .equatable()
    }
}

/// A cursor can move between samples with the same displayed value. Only the
/// formatted value, mode and metric affect this readout's layout/accessibility.
private struct ContainerMetricReadoutValue: View, Equatable {
    let metric: ContainerMetricChart.Metric
    let value: String
    let isSelected: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metric == rhs.metric && lhs.value == rhs.value && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
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
            Text(isSelected ? "SELECTED" : "LATEST")
                .font(.caption2.weight(.semibold)).tracking(0.7).foregroundStyle(metric.tint)
                .padding(.horizontal, 7).padding(.vertical, 4).background(metric.tint.opacity(0.09), in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) \(isSelected ? "selected" : "latest"), \(value) \(metric.unit), \(metric.subtitle)")
    }
}

private struct ContainerMetricCursor: View {
    let metric: ContainerMetricChart.Metric
    let samples: [ContainerHistorySample]
    let latest: ContainerChartPoint?
    let domain: ContainerMetricPlotDomain
    @Binding var selectedDate: Date?

    var body: some View {
        let selection = ContainerMetricSelection(metric: metric, samples: samples, latest: latest, selectedDate: selectedDate)
        GeometryReader { geometry in
            let coordinates = ContainerMetricPlotCoordinates(domain: domain, size: geometry.size)
            let frame = coordinates.frame
            if frame.width > 0 && frame.height > 0 {
                ZStack(alignment: .topLeading) {
                    if let date = selection.date, let x = coordinates.x(for: date) {
                        if selection.isSelected {
                            Path { path in
                                path.move(to: CGPoint(x: x, y: frame.minY))
                                path.addLine(to: CGPoint(x: x, y: frame.maxY))
                            }
                            .stroke(.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        }
                        if let value = selection.value, let y = coordinates.y(for: value) {
                            Circle().fill(metric.tint)
                                .frame(width: selection.isSelected ? 6 : 5, height: selection.isSelected ? 6 : 5)
                                .padding(selection.isSelected ? 2 : 0)
                                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                                .position(x: x, y: y)
                        }
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): inspect(location, coordinates: coordinates)
                    case .ended: selectedDate = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { inspect($0.location, coordinates: coordinates) })
        }
    }

    private func inspect(_ location: CGPoint, coordinates: ContainerMetricPlotCoordinates) {
        guard let date = coordinates.date(at: location) else {
            selectedDate = nil
            return
        }
        selectedDate = ContainerMetricsHistory.nearestSample(to: date, in: samples)?.date ?? date
    }
}

extension ContainerHistoryEvent.Kind {
    var chartColor: Color { switch self { case .restart: .blue; case .exit: .red; case .limits: .orange } }
}

/// Keep the formatter with the readout rather than resolving a format style on
/// every cursor update. Creation is lazy because SwiftUI recreates view values.
/// Snapshot changes prepare at most 128 recent plotted values. Full-resolution
/// cursor misses format on demand, with at most 256 cached strings per card.
@MainActor final class ContainerMetricReadoutFormatting {
    private var formatter: NumberFormatter?
    private var locale: Locale?
    private var cached: [UInt64: String] = [:]
    private var preparedPoints: [ContainerChartPoint] = []
    private var preparedLocale: Locale?

    /// Returns the receiver with the plotted values' text ready, so a body can
    /// hand the warmed formatter to its readout without a bare side effect.
    @discardableResult
    func prepared(points: [ContainerChartPoint], locale: Locale) -> ContainerMetricReadoutFormatting {
        guard preparedPoints != points || preparedLocale != locale else { return self }
        preparedPoints = points; preparedLocale = locale
        var recent: [UInt64: String] = [:]
        for point in points.suffix(128) {
            recent[point.value.bitPattern] = string(point.value, locale: locale)
        }
        cached = recent
        return self
    }

    func string(_ value: Double?, locale: Locale) -> String {
        guard let value, value.isFinite else { return "—" }
        if formatter == nil {
            let number = NumberFormatter()
            number.numberStyle = .decimal
            number.minimumFractionDigits = 1
            number.maximumFractionDigits = 1
            number.maximumIntegerDigits = 309
            number.roundingMode = .halfEven
            formatter = number
        }
        if self.locale != locale {
            formatter?.locale = locale
            self.locale = locale
            cached.removeAll(keepingCapacity: true)
        }
        if let text = cached[value.bitPattern] { return text }
        let text = formatter?.string(from: NSNumber(value: value)) ?? "—"
        if cached.count >= 256 { cached.removeAll(keepingCapacity: true) }
        cached[value.bitPattern] = text
        return text
    }
}

/// One state owner per card. Leaf views receive stable caches without adding
/// dynamic state/locale properties to every cursor-driven readout update.
@MainActor private final class ContainerMetricChartPresentation {
    lazy var series = ContainerMetricSeriesProjection()
    lazy var paths = ContainerMetricPlotPathCache()
    lazy var formatting = ContainerMetricReadoutFormatting()
}
