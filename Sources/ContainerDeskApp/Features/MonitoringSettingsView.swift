import SwiftUI

struct MonitoringSettingsView: View {
    @Bindable var monitoring: ContainerMonitoringStore

    var body: some View {
        Section {
            Toggle("Notify when a container exits unexpectedly", isOn: $monitoring.notifyOnExit)
                .onChange(of: monitoring.notifyOnExit) { _, enabled in
                    if enabled { Task { await monitoring.requestNotificationPermission() } }
                }
            Toggle("Notify when usage exceeds a threshold", isOn: $monitoring.notifyOnThreshold)
                .onChange(of: monitoring.notifyOnThreshold) { _, enabled in
                    if enabled { Task { await monitoring.requestNotificationPermission() } }
                }
            if monitoring.notifyOnThreshold {
                HStack {
                    Text("CPU threshold")
                    Slider(value: $monitoring.cpuThreshold, in: 5...100, step: 5)
                    Text("\(Int(monitoring.cpuThreshold))%").monospacedDigit().frame(width: 44)
                }
                HStack {
                    Text("RAM threshold")
                    Slider(value: $monitoring.memoryThreshold, in: 5...100, step: 5)
                    Text("\(Int(monitoring.memoryThreshold))%").monospacedDigit().frame(width: 44)
                }
            }
            Text("Thresholds use the configured CPU and memory limits. An alert repeats only after usage drops 5 percentage points below its threshold. Monitoring runs while a window is visible, including when another app has focus; history stays in memory for 60 minutes.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = monitoring.notificationError { Text(error).font(.caption).foregroundStyle(.red) }
        } header: { Label("Container Monitoring", systemImage: "chart.xyaxis.line").foregroundStyle(.purple) }
    }
}
