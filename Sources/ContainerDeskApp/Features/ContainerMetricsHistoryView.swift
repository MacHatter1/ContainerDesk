import ContainerDeskCore
import AppKit
import SwiftUI

struct ContainerMetricsHistoryView: View {
    let containerID: String
    let monitoring: ContainerMonitoringStore
    @State private var minutes = 15
    @State private var hoveredDate: Date?
    @State private var snapshot: ContainerHistorySnapshot?
    @Environment(\.scenePhase) private var scenePhase
    var isActive = true
    // Tests may shorten the cadence; collection and alerts retain their own schedule.
    var refreshInterval: Duration = .seconds(5)

    private struct Request: Equatable {
        let containerID: String
        let isActive: Bool
    }

    private var request: Request { .init(containerID: containerID, isActive: isActive && scenePhase != .background) }

    private var displayedSnapshot: ContainerHistorySnapshot? {
        guard let snapshot, snapshot.containerID == containerID else { return nil }
        return snapshot
    }

    var body: some View {
        let request = self.request
        let current = displayedSnapshot
        let end = current?.end ?? Date.now
        let start = end.addingTimeInterval(-Double(minutes * 60))
        let samples = current?.samples.filter { $0.date >= start } ?? []
        let events = current?.events.filter { $0.date >= start } ?? []
        LazyVStack(alignment: .leading, spacing: 12) {
            ContainerHistoryHeader(minutes: $minutes)
            let normalizedCPU = samples.allSatisfy { ($0.cpuLimit ?? 0) > 0 }
            hoverReadout(samples: samples, events: events, normalizedCPU: normalizedCPU)
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
        .task(id: request) {
            guard request.isActive else { return }
            while !Task.isCancelled {
                snapshot = ContainerHistorySnapshot(history: monitoring.history, containerID: containerID, at: .now)
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

    private func hoverReadout(samples: [ContainerHistorySample], events: [ContainerHistoryEvent], normalizedCPU: Bool) -> some View {
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

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(title).foregroundStyle(.secondary) }
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
    @Binding var minutes: Int

    func makeCoordinator() -> Coordinator { Coordinator(minutes: $minutes) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["15 minutes", "60 minutes"], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("History window")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.minutes = $minutes
        control.selectedSegment = minutes == 15 ? 0 : 1
    }

    @MainActor final class Coordinator: NSObject {
        var minutes: Binding<Int>
        init(minutes: Binding<Int>) { self.minutes = minutes }

        @objc func choose(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment == 0 || sender.selectedSegment == 1 else { return }
            minutes.wrappedValue = sender.selectedSegment == 0 ? 15 : 60
        }
    }
}

/// An immutable, bounded publication. Collection never becomes a dependency of
/// the chart's native controls or its marks; only this five-second snapshot does.
private struct ContainerHistorySnapshot {
    let containerID: String
    let samples: [ContainerHistorySample]
    let events: [ContainerHistoryEvent]
    let end: Date

    init(history: ContainerMetricsHistory, containerID: String, at date: Date) {
        self.containerID = containerID
        let end = max(date, history.latestSample(for: containerID)?.date ?? date)
        self.end = end
        let start = end.addingTimeInterval(-ContainerMetricsHistory.retention)
        samples = history.samples(for: containerID).filter { $0.date >= start && $0.date <= end }
        events = history.events.filter { $0.containerID == containerID && $0.date >= start && $0.date <= end }
    }
}

/// Keep the same two chart instances when the available width changes.
private struct ContainerMetricPairLayout: Layout {
    private let spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 614
        let horizontal = width >= 614
        let childWidth = horizontal ? (width - spacing) / 2 : width
        let heights = subviews.map { $0.sizeThatFits(.init(width: childWidth, height: nil)).height }
        let height = horizontal ? (heights.max() ?? 0) : heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let horizontal = bounds.width >= 614
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
