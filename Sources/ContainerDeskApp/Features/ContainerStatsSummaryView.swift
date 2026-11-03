import ContainerDeskCore
import SwiftUI

/// The one-second metric labels have their own observation scope. They must not
/// invalidate the detail pane's native tab picker or the history charts.
struct ContainerStatsSummaryView: View {
    let resource: ResourceSummary
    let store: AppStore

    var body: some View {
        let isSelectedTarget = store.statsTarget == resource.id
        let metric = isSelectedTarget ? store.selectedContainerMetric : store.containerMetrics[resource.id]
        let allocatedCPUs = resource.details.cpuCount ?? resource.details.cpuAllocation
        let cpuDetail = allocatedCPUs.map { "\($0) CPUs allocated" } ?? "CPU limit unavailable"
        let rawCPU = metric?.cpuPercent.map { String(format: "%.1f%% of one core", $0) } ?? "Waiting for CPU sample"
        let memoryLimit = resource.details.memoryLimitBytes ?? resource.details.memoryBytes
        let memoryDetail = memoryLimit.map { "Memory limit \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory))" } ?? "Memory limit unavailable"
        let source: String
        switch store.containerMetricsBackend {
        case .some(.nativeAPI): source = "Native API · every second"
        case .some(.cli): source = "CLI · about every 3 seconds"
        case nil: source = "Waiting for the first stats sample"
        }
        return VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Label("\(cpuDetail) · \(rawCPU)", systemImage: "cpu")
                    Spacer(minLength: 12)
                    Label(memoryDetail, systemImage: "memorychip")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(cpuDetail) · \(rawCPU)", systemImage: "cpu")
                    Label(memoryDetail, systemImage: "memorychip")
                }
            }.font(.caption).foregroundStyle(.secondary)
            Text(source).font(.caption).foregroundStyle(.tertiary)
            Label("Use Edit Limits… to change these values. Apple Container 1.5 recreates the container, causing downtime and resetting its processes and ephemeral network state.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let reason = store.containerMetricsFallbackReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if isSelectedTarget, let statsError = store.statsError { Text(statsError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}
