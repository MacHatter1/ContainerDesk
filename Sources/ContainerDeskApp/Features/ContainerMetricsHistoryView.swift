import ContainerDeskCore
import AppKit
import SwiftUI

struct ContainerMetricsHistoryView: View {
    let containerID: String
    let monitoring: ContainerMonitoringStore
    @State private var minutes = 15
    @State private var hoveredDate: Date?
    @State private var snapshot: ContainerHistorySnapshot?
    @State private var windows = ContainerHistoryWindowCache()
    @Environment(\.scenePhase) private var scenePhase
    var isActive = true
    // Tests may shorten the cadence; collection and alerts retain their own schedule.
    var refreshInterval: Duration = .seconds(5)

    /// Identifies one presentation loop. Changing it cancels the running loop,
    /// so an inactive or background destination stops publishing.
    private struct PresentationKey: Equatable {
        let containerID: String
        let isActive: Bool
    }

    private var presentationKey: PresentationKey { .init(containerID: containerID, isActive: isActive && scenePhase != .background) }

    private var displayedSnapshot: ContainerHistorySnapshot? {
        guard let snapshot, snapshot.containerID == containerID else { return nil }
        return snapshot
    }

    var body: some View {
        let presentationKey = self.presentationKey
        let window = displayedSnapshot.map { windows.value(for: $0, minutes: minutes) } ?? .empty(endingAt: Date.now, minutes: minutes)
        let start = window.start, end = window.end
        let samples = window.samples, events = window.events
        LazyVStack(alignment: .leading, spacing: 12) {
            ContainerHistoryHeader(minutes: $minutes)
            let normalizedCPU = samples.allSatisfy { ($0.cpuLimit ?? 0) > 0 }
            ContainerHistoryHoverReadout(hoveredDate: $hoveredDate, samples: samples, events: events, normalizedCPU: normalizedCPU)
            ContainerMetricPairLayout {
                metricChart(.cpu(normalized: normalizedCPU), samples: samples, events: events, start: start, end: end)
                metricChart(.memory, samples: samples, events: events, start: start, end: end)
            }
            HStack(spacing: 16) {
                legend("Restart", color: .blue)
                legend("Exit", color: .red)
                legend("Limit change", color: .orange)
                Spacer()
                Text("\(samples.count) samples").monospacedDigit().foregroundStyle(.tertiary)
            }.font(.caption)
            Text("Session history is collected while ContainerDesk is visible. Gaps indicate missing samples. Events reflect observed state changes and app actions.")
                .font(.caption).foregroundStyle(.secondary)
            if events.isEmpty {
                Text("No events in this window").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(events.reversed()) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(event.kind.chartColor).frame(width: 6, height: 6).padding(.top, 5)
                        Text(event.date, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.rawValue + (event.unexpected ? " · unexpected" : "")).fontWeight(.medium)
                            Text(event.detail).foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
            }
        }
        .task(id: presentationKey) {
            guard presentationKey.isActive else { return }
            while !Task.isCancelled {
                snapshot = monitoring.history.snapshot(for: containerID, at: .now)
                do { try await Task.sleep(for: refreshInterval) }
                catch { return }
            }
        }
        .onChange(of: minutes) { _, _ in hoveredDate = nil }
        .onChange(of: containerID) { _, _ in hoveredDate = nil }
    }

    private func metricChart(_ metric: ContainerMetricChart.Metric, samples: [ContainerHistorySample], events: [ContainerHistoryEvent], start: Date, end: Date) -> some View {
        ContainerMetricChart(metric: metric, samples: samples, events: events, start: start, end: end, selectedDate: $hoveredDate)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(title).foregroundStyle(.secondary) }
    }
}

/// The summary line above the charts: the only part of the history view that
/// interprets the shared cursor itself.
private struct ContainerHistoryHoverReadout: View {
    @Binding var hoveredDate: Date?
    let samples: [ContainerHistorySample]
    let events: [ContainerHistoryEvent]
    let normalizedCPU: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: hoveredDate == nil ? "cursorarrow.rays" : "scope")
                .font(.body).foregroundStyle(hoveredDate == nil ? Color.secondary : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                if let hoveredDate {
                    let sample = ContainerMetricsHistory.nearestSample(to: hoveredDate, in: samples)
                    let date = sample?.date ?? hoveredDate
                    Text(date, format: .dateTime.month().day().hour().minute().second()).fontWeight(.medium)
                    if let sample {
                        let cpu = (normalizedCPU ? sample.cpuOfLimit : sample.metric.cpuPercent).map { String(format: "%.1f%%", $0) } ?? "—"
                        let memory = sample.metric.memoryUsageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—"
                        Text("CPU \(cpu) \(normalizedCPU ? "of limit" : "of one core") · RAM \(memory)")
                    } else {
                        Text("No sample at this time").foregroundStyle(.secondary)
                    }
                    let nearby = events.filter { abs($0.date.timeIntervalSince(date)) <= 10 }
                    if !nearby.isEmpty {
                        Text(nearby.map { "\($0.kind.rawValue): \($0.detail)" }.joined(separator: " · "))
                            .foregroundStyle(.secondary).lineLimit(1).help(nearby.map(\.detail).joined(separator: "\n"))
                    }
                } else {
                    Text("Hover over either chart to inspect CPU, RAM and nearby events.").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption.monospacedDigit())
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// Keep the native picker's observation lifetime independent of chart snapshots
/// and hover updates. Rebuilding its tagged bindings accumulates observations.
private struct ContainerHistoryHeader: View {
    @Binding var minutes: Int

    var body: some View {
        HStack {
            Label("History & Events", systemImage: "chart.xyaxis.line").font(.headline)
            Spacer()
            ContainerHistoryWindowPicker(minutes: $minutes).frame(width: 220)
        }
    }
}

/// Keep one native control/coordinator for the view's lifetime. Updating a range
/// must not create another SwiftUI tagged-binding observation graph.
private struct ContainerHistoryWindowPicker: NSViewRepresentable {
    /// Selectable windows in minutes; segments follow this order.
    static let ranges = [15, 60]

    @Binding var minutes: Int

    func makeCoordinator() -> Coordinator { Coordinator(minutes: $minutes) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: Self.ranges.map { "\($0) minutes" }, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("History window")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.minutes = $minutes
        control.selectedSegment = Self.ranges.firstIndex(of: minutes) ?? 0
    }

    @MainActor final class Coordinator: NSObject {
        var minutes: Binding<Int>
        init(minutes: Binding<Int>) { self.minutes = minutes }

        @objc func choose(_ sender: NSSegmentedControl) {
            guard ContainerHistoryWindowPicker.ranges.indices.contains(sender.selectedSegment) else { return }
            minutes.wrappedValue = ContainerHistoryWindowPicker.ranges[sender.selectedSegment]
        }
    }
}

/// An immutable, bounded publication. Collection never becomes a dependency of
/// the chart's native controls or its marks; only this five-second snapshot does.
private struct ContainerHistorySnapshot: Identifiable {
    let id = UUID()
    let containerID: String
    let samples: [ContainerHistorySample]
    let events: [ContainerHistoryEvent]
    let end: Date
}

/// The selected range of one snapshot.
private struct ContainerHistoryWindow {
    let start: Date
    let end: Date
    let samples: [ContainerHistorySample]
    let events: [ContainerHistoryEvent]

    init(snapshot: ContainerHistorySnapshot, minutes: Int) {
        let start = snapshot.end.addingTimeInterval(-Double(minutes * 60))
        self.start = start
        end = snapshot.end
        samples = snapshot.samples.filter { $0.date >= start }
        events = snapshot.events.filter { $0.date >= start }
    }

    static func empty(endingAt end: Date, minutes: Int) -> Self {
        .init(start: end.addingTimeInterval(-Double(minutes * 60)), end: end, samples: [], events: [])
    }

    private init(start: Date, end: Date, samples: [ContainerHistorySample], events: [ContainerHistoryEvent]) {
        self.start = start; self.end = end; self.samples = samples; self.events = events
    }
}

/// Cursor changes re-evaluate the history view, which must not re-filter the
/// hour each time. The window is built once per publication or range change,
/// and reusing its arrays lets the chart caches recognise unchanged inputs
/// by storage identity rather than comparing every element.
@MainActor private final class ContainerHistoryWindowCache {
    private var key: (snapshot: ContainerHistorySnapshot.ID, minutes: Int)?
    private var window: ContainerHistoryWindow?

    func value(for snapshot: ContainerHistorySnapshot, minutes: Int) -> ContainerHistoryWindow {
        if let window, let key, key.snapshot == snapshot.id, key.minutes == minutes { return window }
        let window = ContainerHistoryWindow(snapshot: snapshot, minutes: minutes)
        key = (snapshot.id, minutes)
        self.window = window
        return window
    }
}

private extension ContainerMetricsHistory {
    /// The retained hour for one container, read at a single instant so samples
    /// and events stay coherent with each other.
    func snapshot(for containerID: String, at date: Date) -> ContainerHistorySnapshot {
        let end = max(date, latestSample(for: containerID)?.date ?? date)
        let start = end.addingTimeInterval(-Self.retention)
        return ContainerHistorySnapshot(
            containerID: containerID,
            samples: samples(for: containerID).filter { $0.date >= start && $0.date <= end },
            events: events.filter { $0.containerID == containerID && $0.date >= start && $0.date <= end },
            end: end)
    }
}

/// Keep the same two chart instances when the available width changes.
private struct ContainerMetricPairLayout: Layout {
    private let spacing: CGFloat = 14
    /// Cards sit side by side once each can have this much width.
    private let cardMinimumWidth: CGFloat = 300
    private var sideBySideMinimumWidth: CGFloat { cardMinimumWidth * 2 + spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? sideBySideMinimumWidth
        let horizontal = width >= sideBySideMinimumWidth
        let childWidth = horizontal ? (width - spacing) / 2 : width
        let heights = subviews.map { $0.sizeThatFits(.init(width: childWidth, height: nil)).height }
        let height = horizontal ? (heights.max() ?? 0) : heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let horizontal = bounds.width >= sideBySideMinimumWidth
        let width = horizontal ? (bounds.width - spacing) / 2 : bounds.width
        var origin = bounds.origin
        for subview in subviews {
            let proposal = ProposedViewSize(width: width, height: nil)
            subview.place(at: origin, anchor: .topLeading, proposal: proposal)
            if horizontal { origin.x += width + spacing }
            else { origin.y += subview.sizeThatFits(proposal).height + spacing }
        }
    }
}
