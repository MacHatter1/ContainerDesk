import SwiftUI
import ContainerDeskCore

struct SystemFeatureView: View {
    let store: AppStore
    @Environment(\.openCleanup) private var openCleanup

    @State private var output = ""
    @State private var error: String?
    @State private var diskUsage: SystemDiskUsage?
    @State private var busy = false
    @State private var showStopConfirmation = false
    @State private var showDNSCreate = false
    @State private var showDNSDelete = false
    @State private var showDNSDeleteConfirmation = false
    @State private var showKernelSheet = false
    @State private var domain = ""
    @State private var localhost = ""
    @State private var kernelPath = ""
    @State private var archivePath = ""
    @State private var archiveDigest = ""
    @State private var kernelArch = "arm64"
    @State private var installRecommended = true
    @State private var forceKernel = false
    @State private var showAdvanced = false
    @State private var selectedSystemTab = "Disk Usage"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(title: "System", subtitle: "Service, kernel, DNS and storage", symbol: "gearshape.2.fill", tint: .blue) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshCurrentScreen() } }
                    .disabled(busy)
                    .help("Refresh runtime and system information")
                Menu {
                    Button("Advanced System Commands…", systemImage: "terminal") { showAdvanced = true }
                    Divider()
                    Button("Add DNS Domain…", systemImage: "plus") { domain = ""; localhost = ""; showDNSCreate = true }
                    Button("Remove DNS Domain…", systemImage: "minus.circle") { showDNSDelete = true }
                    Button("Install Recommended Kernel…", systemImage: "arrow.down.circle") { installRecommended = true; showKernelSheet = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .help("System actions")
                .accessibilityLabel("System actions")
            }
            HStack(alignment: .top, spacing: 14) {
                serviceCard.frame(maxWidth: .infinity)
                quickActions
            }
            .padding(.horizontal, 16)
            systemTabs
            selectedPanel
            footer
        }
        .task { await refreshCurrentScreen() }
        .sheet(isPresented: $showDNSCreate) { dnsCreateSheet }
        .sheet(isPresented: $showDNSDelete) { dnsDeleteSheet }
        .sheet(isPresented: $showKernelSheet) { kernelSheet }
        .sheet(isPresented: $showAdvanced) { AdvancedCommandSheet(section: .system, store: store) { _ in } }
        .confirmationDialog("Stop Apple container services?", isPresented: $showStopConfirmation, titleVisibility: .visible) {
            Button("Stop Services", role: .destructive) { Task { await run(["system", "stop"], title: "Stop Container Services") } }
            Button("Cancel", role: .cancel) { }
        } message: { Text(SystemServiceActions.stopConfirmation) }
    }

    private var serviceCard: some View {
        AccentPanel(title: "Runtime service", symbol: "power.circle.fill", tint: runtimeIsRunning ? .green : .orange) {
            VStack(spacing: 9) {
                systemValueRow("Status") {
                    HStack(spacing: 7) {
                        Circle().fill(runtimeIsRunning ? .green : .secondary).frame(width: 7, height: 7)
                        Text(runtimeStatusLabel).foregroundStyle(.primary)
                    }
                }
                systemValueRow("Version") { Text(store.runtimeVersionLabel ?? "—").foregroundStyle(.primary) }
                systemValueRow("Architecture") { Text(hostArchitecture).font(.system(.body, design: .monospaced)).foregroundStyle(.primary) }
                Divider().padding(.vertical, 3)
                HStack(spacing: 10) {
                    Button("Start Services", systemImage: "play.fill") {
                        Task { await run(["system", "start", "--disable-kernel-install"], title: "Start Container Services") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || runtimeIsRunning)
                    Button("Stop Services", systemImage: "stop.fill") { showStopConfirmation = true }
                        .disabled(busy || !runtimeIsRunning || store.limitsOperationContainerID != nil)
                }
                .controlSize(.regular)
            }
        }
    }

    private var systemTabs: some View {
        DetailTabStrip(selection: $selectedSystemTab, tabs: ["Disk Usage", "System Logs", "DNS Domains", "Properties", "Kernel"])
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .onChange(of: selectedSystemTab) { _, _ in loadSelectedTab() }
    }

    private var runtimeIsRunning: Bool {
        store.runtimeIsConnected
    }

    private var runtimeStatusLabel: String {
        store.runtimeStateLabel
    }

    private var hostArchitecture: String {
        store.runtimeStatusSummary?.architecture ?? {
            #if arch(arm64)
            "arm64"
            #else
            "unknown"
            #endif
        }()
    }

    private var selectedTabSymbol: String {
        switch selectedSystemTab {
        case "System Logs": "text.alignleft"
        case "DNS Domains": "network"
        case "Properties": "slider.horizontal.3"
        case "Kernel": "cpu"
        default: "externaldrive"
        }
    }

    private func systemValueRow<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body)
    }

    private static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func loadSelectedTab() {
        switch selectedSystemTab {
        case "System Logs": Task { await run(["system", "logs", "--last", "5m"], title: "Read Service Logs") }
        case "DNS Domains": Task { await run(["system", "dns", "list", "--format", "json"], title: "List DNS Domains") }
        case "Properties": Task { await run(["system", "property", "list", "--format", "json"], title: "List System Properties") }
        case "Kernel": showKernelSheet = true
        default: Task { await loadDiskUsage() }
        }
    }

    private func refreshCurrentScreen() async {
        await store.refreshSystemVersion()
        if selectedSystemTab == "Disk Usage" { await loadDiskUsage() }
        else if selectedSystemTab != "Kernel" { loadSelectedTab() }
    }

    private func loadDiskUsage() async {
        busy = true
        error = nil
        do {
            let result = try await store.execute(CommandRequest(arguments: ["system", "df", "--format", "json"], captureLimit: 128_000, suppressOutputEvents: true, timeout: .seconds(20)), title: "Read Disk Usage")
            guard result.succeeded else { throw FeatureCommandError(result: result) }
            guard !result.outputTruncated else { throw SystemFeatureError.responseTooLarge }
            diskUsage = try JSONDecoder().decode(SystemDiskUsage.self, from: Data(result.standardOutput.utf8))
            output = ""
        } catch {
            diskUsage = nil
            self.error = error.localizedDescription
        }
        busy = false
    }

    @ViewBuilder private var selectedPanel: some View {
        if selectedSystemTab == "Disk Usage" {
            diskUsagePanel
        } else {
            outputPanel
        }
    }

    private var diskUsagePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if busy && diskUsage == nil {
                ProgressView("Reading disk usage…").frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else if let error {
                ContentUnavailableView("Disk usage unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text(error))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if let diskUsage {
                diskUsageRows(diskUsage)
            } else {
                ContentUnavailableView("No disk usage data", systemImage: "externaldrive", description: Text("Refresh to query the runtime."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func diskUsageRows(_ usage: SystemDiskUsage) -> some View {
        let rows = [
            SystemDiskUsageRow(title: "Images", usage: usage.images, symbol: "shippingbox", color: .blue),
            SystemDiskUsageRow(title: "Containers", usage: usage.containers, symbol: "shippingbox.fill", color: .green),
            SystemDiskUsageRow(title: "Volumes", usage: usage.volumes, symbol: "externaldrive", color: .purple),
        ]
        let totalBytes = usage.total ?? rows.compactMap(\.sizeInBytes).reduce(Int64(0), +)
        return AccentPanel(title: "Disk usage", symbol: "externaldrive.fill", tint: .blue) {
            VStack(spacing: 0) {
                HStack {
                    Text("Type").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Count").frame(width: 100, alignment: .leading)
                    Text("Size").frame(width: 130, alignment: .trailing)
                    Text("Reclaimable").frame(width: 130, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ForEach(rows) { row in
                    HStack {
                        Label(row.title, systemImage: row.symbol).frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.count.map { $0.formatted() } ?? "—").frame(width: 100, alignment: .leading).monospacedDigit()
                        Text(row.sizeInBytes.map(Self.byteCount) ?? "—").frame(width: 130, alignment: .trailing).monospacedDigit()
                        Text(row.reclaimable.map(Self.byteCount) ?? "—").frame(width: 130, alignment: .trailing).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    Divider()
                }
            }
            HStack {
                Text("\(Self.byteCount(totalBytes)) reported").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Review Cleanup", systemImage: "sparkles") { openCleanup(nil) }
                    .buttonStyle(.bordered)
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(.top, 2)
    }

    private var quickActions: some View {
        AccentPanel(title: "Administration", symbol: "slider.horizontal.3", tint: .purple) {
            VStack(spacing: 8) {
                Button("Add DNS Domain…", systemImage: "plus") { domain = ""; localhost = ""; showDNSCreate = true }
                Button("Remove DNS Domain…", systemImage: "minus.circle") { showDNSDelete = true }
                Button("Install Recommended Kernel…", systemImage: "arrow.down.circle") { installRecommended = true; showKernelSheet = true }
                    .disabled(busy)
                Divider().padding(.vertical, 3)
                Text("DNS changes require administrator approval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 240, idealWidth: 290, maxWidth: 340, alignment: .topLeading)
    }

    private func systemActionCard(_ title: String, detail: String, symbol: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .padding(13)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(error == nil ? selectedSystemTab : "\(selectedSystemTab) unavailable").font(.headline); Spacer(); if busy { ProgressView().controlSize(.small) } }
            if error != nil || !output.isEmpty {
                Text(error ?? output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                    .padding(10).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Choose a system action to view its result.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            Label(runtimeIsRunning ? "Runtime connected" : runtimeStatusLabel, systemImage: runtimeIsRunning ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(runtimeIsRunning ? .green : .secondary)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Text("System state is queried live").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var dnsCreateSheet: some View {
        NavigationStack {
            Form {
                Section("Domain") {
                    TextField("Domain name", text: $domain, prompt: Text("app.test"))
                    TextField("Redirect to localhost (optional)", text: $localhost, prompt: Text("127.0.0.1 or ::1"))
                }
                Section { Text("The app validates the domain and optional IP address, then requests administrator approval for this DNS action only.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("Add Local DNS Domain")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDNSCreate = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Add Domain") { Task { await createDNS() } }.buttonStyle(.borderedProminent).disabled(domain.isEmpty) }
            }
        }.frame(minWidth: 430, minHeight: 250)
    }

    private var dnsDeleteSheet: some View {
        NavigationStack {
            Form {
                Section("Domain") { TextField("Domain name", text: $domain, prompt: Text("app.test")) }
                Section { Text("This removes the local DNS configuration and requires administrator approval.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("Remove Local DNS Domain")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDNSDelete = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Remove…", role: .destructive) { showDNSDeleteConfirmation = true }.disabled(domain.isEmpty) }
            }
            .confirmationDialog("Remove \(domain) from local DNS?", isPresented: $showDNSDeleteConfirmation, titleVisibility: .visible) {
                Button("Remove Domain", role: .destructive) { Task { await deleteDNS() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the named local DNS domain and then requests administrator approval.")
            }
        }.frame(minWidth: 430, minHeight: 220)
    }

    private var kernelSheet: some View {
        NavigationStack {
            Form {
                Section("Kernel source") {
                    Toggle("Download recommended kernel", isOn: $installRecommended)
                    if !installRecommended {
                        TextField("Kernel binary path", text: $kernelPath, prompt: Text("/path/to/vmlinux"))
                        TextField("Archive path or URL (optional)", text: $archivePath)
                        TextField("Remote archive SHA-256 digest", text: $archiveDigest, prompt: Text("sha256:<hex>"))
                        Picker("Architecture", selection: $kernelArch) { Text("Apple Silicon (arm64)").tag("arm64"); Text("Intel (amd64)").tag("amd64") }
                        Toggle("Overwrite existing kernel", isOn: $forceKernel)
                    }
                }
                Section { Text("Installing the recommended kernel uses the CLI’s built-in download. Remote archives require an explicit digest.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("Set Default Kernel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showKernelSheet = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Install Kernel…") { Task { await setKernel() } }.buttonStyle(.borderedProminent).disabled(!installRecommended && kernelPath.isEmpty && archivePath.isEmpty) }
            }
        }.frame(minWidth: 480, minHeight: 340)
    }

    private func refreshStatus() async { await store.refreshSystemVersion() }
    private func run(_ arguments: [String], title: String) async {
        busy = true; error = nil; output = ""
        do {
            let request = CommandRequest(arguments: arguments, captureLimit: 500_000, suppressOutputEvents: true)
            let result = try await store.execute(request, title: title)
            output = request.sanitizeOutput(result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError))
            guard result.succeeded else { throw FeatureCommandError(result: result) }
            if arguments.contains("start") || arguments.contains("stop") { await store.refreshSystemVersion() }
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    private func createDNS() async {
        busy = true; error = nil
        do {
            let value = try await store.executePrivilegedDNS(.create(domainName: domain, localhost: localhost.isEmpty ? nil : localhost))
            output = value.isEmpty ? "DNS domain added." : value; showDNSCreate = false
            await run(["system", "dns", "list", "--format", "json"], title: "List DNS Domains")
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    private func deleteDNS() async {
        busy = true; error = nil
        do {
            let value = try await store.executePrivilegedDNS(.delete(domainName: domain))
            output = value.isEmpty ? "DNS domain removed." : value; showDNSDelete = false
            await run(["system", "dns", "list", "--format", "json"], title: "List DNS Domains")
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    private func setKernel() async {
        var args = ["system", "kernel", "set"]
        if installRecommended { args.append("--recommended") }
        else {
            args += ["--arch", kernelArch]
            if !kernelPath.isEmpty { args += ["--binary", kernelPath] }
            if !archivePath.isEmpty { args += ["--tar", archivePath] }
            if !archiveDigest.isEmpty { args += ["--digest", archiveDigest] }
            if forceKernel { args.append("--force") }
        }
        await run(args, title: "Set Default Kernel")
        if error == nil { showKernelSheet = false }
    }
}

private struct SystemDiskUsageRow: Identifiable {
    let title: String
    let count: Int64?
    let sizeInBytes: Int64?
    let reclaimable: Int64?
    let symbol: String
    let color: Color
    var id: String { title }

    init(title: String, usage: CleanupResourceUsage, symbol: String, color: Color) {
        self.title = title
        self.count = usage.total
        self.sizeInBytes = usage.sizeInBytes
        self.reclaimable = usage.reclaimable
        self.symbol = symbol
        self.color = color
    }
}

private enum SystemFeatureError: LocalizedError {
    case responseTooLarge
    var errorDescription: String? { "The system disk-usage response exceeded the safe decode limit." }
}

