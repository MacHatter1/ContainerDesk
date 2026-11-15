import ContainerDeskCore
import SwiftUI

struct LimitsRecoverySheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [LimitsRecoverySession] = []
    @State private var selected = Set<String>()
    private enum TaskStatus: String {
        case scanning = "Checking all container references…"
        case reviewing = "Verifying the backup and checking for the original container…"
        case removing = "Rechecking references and removing reviewed sessions…"
        case restoring = "Restoring the container and checking its state…"
    }
    private enum Confirmation {
        case remove([LimitsRecoverySession])
        case restore(AppStore.ReviewedLimitsRestore)

        var title: String {
            switch self {
            case .remove(let sessions): "Permanently remove \(sessions.count) recovery sessions?"
            case .restore(let review): "Restore \(review.backup.containerID)?"
            }
        }
    }
    @State private var status: TaskStatus?
    private var busy: Bool { status != nil }
    private var mutating: Bool { status == .removing || status == .restoring }
    @State private var error: String?
    @State private var results: [LimitsRecoveryRemoval] = []
    @State private var confirmation: Confirmation?
    @State private var restored: String?

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
                Text("Restore a missing container from a verified backup, or remove completed recovery copies you no longer need.")
                    .font(.callout)
                Text("Only completed, unreferenced sessions can be removed. In-progress, interrupted, unknown and manual-recovery sessions are always kept. The inventory includes stopped containers.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { InlineNotice(message: error, kind: .error) }
                if let restored { Text(restored) }
                if let status { ProgressView(status.rawValue) }
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
                        if session.canReviewRestore {
                            Button("Review Restore…") { Task { await reviewRestore(session) } }
                                .disabled(busy || store.limitsOperationContainerID != nil || store.isRecoveryCleanupInProgress)
                        } else if let reason = session.keepReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
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
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(mutating) }
                ToolbarItem { Button("Scan Again") { Task { await scan() } }.disabled(busy || store.limitsOperationContainerID != nil || store.isRecoveryCleanupInProgress) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove Selected…", role: .destructive) { confirmation = .remove(selectedSessions) }
                        .disabled(busy || selectedSessions.isEmpty || store.limitsOperationContainerID != nil || store.isRecoveryCleanupInProgress)
                }
            }
            .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            ), titleVisibility: .visible, presenting: confirmation) { action in
                switch action {
                case .remove(let sessions):
                    Button("Remove Recovery Copies", role: .destructive) { Task { await remove(sessions) } }
                case .restore(let review):
                    Button("Restore Container") { Task { await restore(review) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                switch action {
                case .remove(let sessions):
                    Text("This deletes the selected rollback disks and saved configuration, including environment values. Up to \(allocatedSize(sessions)) is allocated; actual reclaimed space may be lower. All references will be checked again before removal.")
                case .restore(let review):
                    let backup = review.backup
                    let state = backup.wasRunning ? "The container will start." : "The container will stay stopped."
                    Text("Restore \(backup.imageReference) with \(backup.limits.cpus) CPUs and \(backup.limits.memoryBytes / 1_048_576) MiB of memory. \(state) Existing mounts will be reattached.\n\nRecovery copy to keep: \(backup.session.directory.path)")
                }
            }
        }
        .frame(minWidth: 650, minHeight: 520)
        .interactiveDismissDisabled(mutating)
        .task { await scan() }
        .onChange(of: store.cliPath) { _, _ in sessions = []; selected = []; confirmation = nil; restored = nil; error = "The runtime changed. Scan again before using recovery files." }
    }

    private func scan() async {
        guard !busy else { return }
        status = .scanning; error = nil; selected = []
        defer { status = nil }
        do { sessions = try await store.scanLimitsRecovery() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; sessions = [] } }
    }

    private func remove(_ review: [LimitsRecoverySession]) async {
        guard !busy, !review.isEmpty else { return }
        status = .removing; error = nil; restored = nil
        defer { status = nil }
        do {
            results = try await store.removeLimitsRecovery(review)
            selected = []; sessions = []
            sessions = try await store.scanLimitsRecovery()
        } catch { self.error = error.localizedDescription }
    }

    private func reviewRestore(_ session: LimitsRecoverySession) async {
        guard !busy else { return }
        status = .reviewing; error = nil; restored = nil
        defer { status = nil }
        do { confirmation = .restore(try await store.reviewLimitsRestore(session)) }
        catch { self.error = error.localizedDescription }
    }

    private func restore(_ review: AppStore.ReviewedLimitsRestore) async {
        guard !busy else { return }
        status = .restoring; error = nil; selected = []; results = []
        defer { status = nil }
        do {
            try await store.restoreLimitsBackup(review)
            restored = "Restored \(review.backup.containerID)."
        } catch { self.error = error.localizedDescription }
        do { sessions = try await store.scanLimitsRecovery() }
        catch { sessions = []; if self.error == nil { self.error = error.localizedDescription } }
    }
}
