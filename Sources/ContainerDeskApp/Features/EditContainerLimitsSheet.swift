import ContainerDeskCore
import Observation
import SwiftUI

@MainActor
@Observable
private final class ContainerLimitsProgressState {
    var phase: ContainerLimitsProgress?

    func update(_ phase: ContainerLimitsProgress) {
        self.phase = phase
    }
}

struct EditContainerLimitsSheet: View {
    let container: ResourceSummary
    @Bindable var store: AppStore

    @Environment(\.dismiss) private var dismiss
    @State private var plan: ContainerLimitsPlan?
    @State private var preparationError: String?
    @State private var isPreparing = true
    @State private var cpuText = ""
    @State private var memoryMiBText = ""
    @State private var acknowledgeReplacement = false
    @State private var isApplying = false
    @State private var result: ContainerLimitsApplyResult?
    @State private var showsRecoveryFiles = false
    @State private var progressState = ContainerLimitsProgressState()

    private let mebibyte: UInt64 = 1_048_576

    private var maximumMemoryMiB: UInt64 { (plan?.maximumMemoryBytes ?? 0) / mebibyte }
    private var currentMemoryIsRepresentable: Bool {
        guard let plan else { return false }
        return plan.currentLimits.memoryBytes.isMultiple(of: mebibyte)
    }

    private var requestedLimits: ContainerResourceLimits? {
        guard let plan,
              let cpus = Int(cpuText), cpus >= 1, cpus <= plan.maximumCPUs,
              let memoryMiB = UInt64(memoryMiBText), memoryMiB >= 200, memoryMiB <= maximumMemoryMiB else { return nil }
        let (memoryBytes, overflow) = memoryMiB.multipliedReportingOverflow(by: mebibyte)
        guard !overflow, memoryBytes <= plan.maximumMemoryBytes else { return nil }
        return ContainerResourceLimits(cpus: cpus, memoryBytes: memoryBytes)
    }

    private var valuesChanged: Bool {
        guard let plan, let requestedLimits else { return false }
        return requestedLimits.cpus != plan.currentLimits.cpus || requestedLimits.memoryBytes != plan.currentLimits.memoryBytes
    }

    private var validationMessage: String? {
        guard let plan else { return nil }
        guard currentMemoryIsRepresentable else {
            return "The current memory limit is not an exact MiB value. It cannot be safely preserved by this editor."
        }
        guard let cpus = Int(cpuText), cpus >= 1, cpus <= plan.maximumCPUs else {
            return "Enter a whole CPU count from 1 to \(plan.maximumCPUs)."
        }
        guard let memoryMiB = UInt64(memoryMiBText), memoryMiB >= 200 else {
            return "Memory must be at least 200 MiB."
        }
        guard memoryMiB <= maximumMemoryMiB else {
            return "Memory cannot exceed \(maximumMemoryMiB) MiB for this container."
        }
        guard let requestedLimits else {
            return "The requested memory limit is outside the supported range."
        }
        guard requestedLimits.cpus != plan.currentLimits.cpus || requestedLimits.memoryBytes != plan.currentLimits.memoryBytes else {
            return "Change at least one limit to continue."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.cliPath != nil {
                    Section {
                        Label("Edit Limits requires the default Apple Container CLI. A CLI override is active, so this flow is unavailable.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if isPreparing {
                    Section("Prepare review") {
                        ProgressView("Reading the current container configuration…")
                    }
                } else if let preparationError {
                    Section("Cannot prepare a safe replacement") {
                        InlineNotice(message: preparationError, kind: .error)
                        Button("Try Again", systemImage: "arrow.clockwise") { Task { await prepare() } }
                            .disabled(isApplying)
                    }
                } else if let plan {
                    if !isApplying, result == nil {
                        reviewForm(plan)
                    } else {
                        Section("Container") {
                            LabeledContent("Name", value: plan.containerID).textSelection(.enabled)
                            if let requestedLimits {
                                LabeledContent("Requested limits", value: "\(requestedLimits.cpus) CPUs · \(requestedLimits.memoryBytes / mebibyte) MiB")
                            }
                        }
                    }
                }

                if isApplying {
                    Section("Recreating container") {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(progressTitle).font(.callout.weight(.medium))
                                Text(progressDescription).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("Keep ContainerDesk open until verification or restoration finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let result {
                    resultSection(result)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Container Limits")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isApplying)
                }
                if result == nil, plan != nil, !isPreparing, preparationError == nil, store.cliPath == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isApplying ? "Recreating…" : "Recreate Container", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await apply() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canApply)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 540)
        .interactiveDismissDisabled(isApplying)
        .task { await prepare() }
        .onDisappear {
            if let id = plan?.id {
                Task { await store.discardContainerLimitsPlan(id: id) }
            }
        }
        .onChange(of: store.cliPath) { _, newPath in
            guard newPath != nil else { return }
            if let id = plan?.id {
                Task { await store.discardContainerLimitsPlan(id: id) }
            }
            plan = nil
            preparationError = "Edit Limits requires the default Apple Container CLI. A CLI override is active, so no replacement can be prepared or applied."
            isPreparing = false
        }
    }

    private var canApply: Bool {
        !isPreparing && !isApplying && currentMemoryIsRepresentable && requestedLimits != nil && valuesChanged && acknowledgeReplacement && result == nil
    }

    private func reviewForm(_ plan: ContainerLimitsPlan) -> some View {
        Group {
            Section("Container") {
                LabeledContent("Name", value: container.title)
                LabeledContent("Identifier", value: plan.containerID).textSelection(.enabled)
                LabeledContent("Image", value: plan.imageReference)
                LabeledContent("Current state", value: plan.wasRunning ? "Running · will restart" : "Stopped · will remain stopped")
            }

            Section("Resource limits") {
                HStack {
                    Text("CPU limit")
                    Spacer(minLength: 12)
                    Text("\(plan.currentLimits.cpus) CPUs")
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("New CPU count", text: $cpuText)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .disabled(isApplying || result != nil)
                    Text("CPUs").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Memory limit")
                    Spacer(minLength: 12)
                    Text(currentMemoryIsRepresentable ? "\(plan.currentLimits.memoryBytes / mebibyte) MiB" : "\(plan.currentLimits.memoryBytes) bytes")
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("New memory limit", text: $memoryMiBText)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .disabled(isApplying || result != nil || !currentMemoryIsRepresentable)
                    Text("MiB").foregroundStyle(.secondary)
                }
                Text("CPU range: 1–\(plan.maximumCPUs). Memory range: 200–\(maximumMemoryMiB) MiB.")
                    .font(.caption).foregroundStyle(.secondary)
                if let validationMessage {
                    Text(validationMessage).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Downtime and data") {
                Label(
                    plan.wasRunning
                        ? "The running container will stop while the replacement is created and verified. Expect downtime."
                        : "The stopped container remains stopped while its replacement is created.",
                    systemImage: plan.wasRunning ? "clock.badge.exclamationmark" : "pause.circle"
                )
                Label("Running processes and ephemeral network state reset during recreation.", systemImage: "arrow.counterclockwise")
                Label("The writable layer is backed up. Named volumes and bind mounts remain attached to the replacement, so their data stays at its existing source.", systemImage: "externaldrive.badge.checkmark")
                Toggle("I understand this replaces the container and resets its processes and ephemeral network state.", isOn: $acknowledgeReplacement)
                    .disabled(isApplying || result != nil)
            }

        }
    }

    @ViewBuilder private func resultSection(_ result: ContainerLimitsApplyResult) -> some View {
        switch result {
        case .unchanged(let reason):
            Section("Limits unchanged") {
                InlineNotice(message: reason.localizedDescription, kind: .warning)
            }
        case .updated(let recoveryURL):
            Section("Limits updated") {
                Label(plan?.wasRunning == true ? "The replacement is running with the new limits." : "The replacement is ready and remains stopped.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                recoveryFilesDisclosure(recoveryURL)
            }
        case .rolledBack(let recoveryURL, let reason):
            Section("Original container restored") {
                Label("The replacement could not be verified. The original container was restored.", systemImage: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text(reason.localizedDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                recoveryFilesDisclosure(recoveryURL)
            }
        case .recoveryNeeded(let recoveryURL, let reason):
            Section("Manual recovery needed") {
                Label("The replacement did not complete, and automatic restoration could not be verified. Keep the recovery files and inspect the runtime before retrying.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(reason.localizedDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                recoveryFilesDisclosure(recoveryURL)
            }
        }
    }

    private func recoveryFilesDisclosure(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(showsRecoveryFiles ? "Hide Recovery Files" : "Show Recovery Files", systemImage: showsRecoveryFiles ? "chevron.down" : "chevron.right") {
                showsRecoveryFiles.toggle()
            }
            .buttonStyle(.plain)
            if showsRecoveryFiles {
                Text(url.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Label("These files may contain container data or files still referenced by the runtime. Do not delete them while the container uses them.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressTitle: String {
        switch progressState.phase {
        case .validating: "Validating replacement plan"
        case .backingUp: "Backing up container data"
        case .stopping: "Stopping current container"
        case .replacing: "Creating replacement"
        case .starting: "Starting replacement"
        case .verifying: "Verifying replacement"
        case .rollingBack: "Restoring original container"
        case nil: "Preparing"
        }
    }

    private var progressDescription: String {
        switch progressState.phase {
        case .validating: "Checking the reviewed configuration against the current container."
        case .backingUp: "Preserving settings and data before changing the runtime."
        case .stopping: "Existing processes are stopping."
        case .replacing: "Applying the new CPU and memory limits."
        case .starting: "Restoring the prior running or stopped state."
        case .verifying: "Checking the replacement configuration and state."
        case .rollingBack: "The replacement failed verification; restoring the previous container."
        case nil: "The operation is starting."
        }
    }

    private func prepare() async {
        guard store.cliPath == nil else {
            preparationError = "Edit Limits requires the default Apple Container CLI. A CLI override is active."
            isPreparing = false
            return
        }
        isPreparing = true
        preparationError = nil
        do {
            let prepared = try await store.prepareContainerLimits(id: container.id)
            guard !Task.isCancelled else {
                await store.discardContainerLimitsPlan(id: prepared.id)
                return
            }
            plan = prepared
            cpuText = String(prepared.currentLimits.cpus)
            memoryMiBText = String(prepared.currentLimits.memoryBytes / mebibyte)
        } catch {
            preparationError = error.localizedDescription
        }
        isPreparing = false
    }

    private func apply() async {
        guard let plan, let requestedLimits, canApply, store.cliPath == nil else { return }
        isApplying = true
        progressState.phase = .validating
        let progressState = self.progressState
        let result = await store.applyContainerLimits(plan, limits: requestedLimits) { phase in
            await progressState.update(phase)
        }
        self.result = result
        isApplying = false
    }
}
