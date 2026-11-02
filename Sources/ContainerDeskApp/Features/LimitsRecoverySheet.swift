import ContainerDeskCore
import SwiftUI

struct LimitsRecoverySheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [LimitsRecoverySession] = []
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var removing = false
    @State private var error: String?
    @State private var results: [LimitsRecoveryRemoval] = []
    @State private var review: [LimitsRecoverySession] = []
    @State private var confirmRemoval = false

    private var selectedSessions: [LimitsRecoverySession] { sessions.filter { $0.canRemove && selected.contains($0.id) } }
    private func allocatedSize(_ entries: [LimitsRecoverySession]) -> String {
        let bytes = entries.reduce(Int64(0)) { sum, item in
            let (total, overflow) = sum.addingReportingOverflow(item.allocatedBytes)
            return overflow ? .max : total
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Completed recovery sessions retain rollback disks and configuration, including environment values. Select the copies you no longer need.")
                    .font(.callout)
                Text("Only completed, unreferenced sessions can be removed. In-progress, interrupted, unknown and manual-recovery sessions are always kept. The inventory includes stopped containers.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { InlineNotice(message: error, kind: .error) }
                if busy { ProgressView(removing ? "Rechecking references and removing reviewed sessions…" : "Checking all container references…") }
                List(sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { selected.contains(session.id) }, set: { value in
                            if value { selected.insert(session.id) } else { selected.remove(session.id) }
                        })) {
                            Text(session.containerID ?? session.id).font(.body.weight(.medium))
                        }
                        .disabled(!session.canRemove || busy)
                        Text("\(session.outcome?.rawValue ?? "Unknown outcome") · \(allocatedSize([session])) allocated")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(session.directory.path).font(.caption.monospaced()).textSelection(.enabled)
                        if let reason = session.keepReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
                Text("Selected: \(selectedSessions.count) sessions · up to \(allocatedSize(selectedSessions)) allocated. Shared APFS clone blocks may reduce the space actually reclaimed.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    Text("\(result.sessionID): \(result.message)").font(.caption).textSelection(.enabled)
                }
            }
            .padding(20)
            .navigationTitle("Limits Recovery Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(removing) }
                ToolbarItem { Button("Scan Again") { Task { await scan() } }.disabled(busy || store.limitsOperationContainerID != nil || store.isRecoveryCleanupInProgress) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove Selected…", role: .destructive) { review = selectedSessions; confirmRemoval = true }
                        .disabled(busy || selectedSessions.isEmpty || store.limitsOperationContainerID != nil || store.isRecoveryCleanupInProgress)
                }
            }
            .confirmationDialog("Permanently remove \(review.count) recovery sessions?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove Recovery Copies", role: .destructive) { Task { await remove() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the selected rollback disks and saved configuration, including environment values. Up to \(allocatedSize(review)) is allocated; actual reclaimed space may be lower. All references will be checked again before removal.")
            }
        }
        .frame(minWidth: 650, minHeight: 520)
        .interactiveDismissDisabled(removing)
        .task { await scan() }
        .onChange(of: store.cliPath) { _, _ in sessions = []; selected = []; review = []; error = "The runtime changed. Scan again before removing recovery files." }
    }

    private func scan() async {
        guard !busy else { return }
        busy = true; error = nil; selected = []
        defer { busy = false }
        do { sessions = try await store.scanLimitsRecovery() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; sessions = [] } }
    }

    private func remove() async {
        guard !busy, !review.isEmpty else { return }
        busy = true; removing = true; error = nil
        defer { busy = false; removing = false; review = [] }
        do {
            results = try await store.removeLimitsRecovery(review)
            selected = []; sessions = []
            sessions = try await store.scanLimitsRecovery()
        } catch { self.error = error.localizedDescription }
    }
}
