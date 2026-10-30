import ContainerDeskCore
import SwiftUI

struct ContainerMetricsHistoryView: View {
    let containerID: String
    let monitoring: ContainerMonitoringStore
    @State private var minutes = 15
    @State private var hoveredDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let end = max(context.date, monitoring.history.latestSample(for: containerID)?.date ?? context.date)
            let start = end.addingTimeInterval(-Double(minutes * 60))
            let samples = monitoring.history.samples(for: containerID).filter { $0.date >= start && $0.date <= end }
            let events = monitoring.history.events.filter { $0.containerID == containerID && $0.date >= start && $0.date <= end }
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("History & Events", systemImage: "chart.xyaxis.line").font(.headline)
                    Spacer()
                    Picker("History window", selection: $minutes) {
                        Text("15 minutes").tag(15)
                        Text("60 minutes").tag(60)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                let normalizedCPU = samples.allSatisfy { ($0.cpuLimit ?? 0) > 0 }
                hoverReadout(samples: samples, events: events, normalizedCPU: normalizedCPU)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        metricChart(.cpu(normalized: normalizedCPU), samples: samples, events: events, start: start, end: end).frame(minWidth: 300)
                        metricChart(.memory, samples: samples, events: events, start: start, end: end).frame(minWidth: 300)
                    }
                    VStack(spacing: 14) {
                        metricChart(.cpu(normalized: normalizedCPU), samples: samples, events: events, start: start, end: end)
                        metricChart(.memory, samples: samples, events: events, start: start, end: end)
                    }
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
