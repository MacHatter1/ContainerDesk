import AppKit
import SwiftUI
import ContainerDeskCore

struct FeatureNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    init(title: String, message: String) { self.title = title; self.message = message }
}

struct FeatureNoticeView: View {
    let notice: FeatureNotice
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(notice.title, systemImage: "info.circle.fill").font(.title3.weight(.semibold))
            Text(notice.message).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(minWidth: 340, maxWidth: 520)
    }
}

struct ResourceDetailPane: View {
    let resource: ResourceSummary
    let section: ContainerSection
    @Binding var tab: ResourceDetailTab
    @Binding var transientText: String
    let store: AppStore
    let limitsOperationInProgress: Bool
    @ObservedObject var activation: ResourceFeatureActivation

    private var isActive: Bool { activation.isActive }
    let onNotice: (FeatureNotice) -> Void
    let action: (ResourceActionKind) -> Void
    let onRun: (String) -> Void
    let onEditLimits: () -> Void

    @State private var isLoading = false
    @State private var followLogs = false
    @State private var operationID: UUID?
    @State private var error: String?
    @State private var inspectBackend: ResourceReadBackend?
    @State private var inspectFallbackReason: String?
    @State private var logQuery = ""
    @State private var hostPath = ""
    @State private var hostDestinationPath = ""
    @State private var containerSourcePath = "/tmp/"
    @State private var containerDestinationPath = "/tmp/"
    @State private var fileOutput = ""
    @State private var fileImporter = false
    @State private var fileOperationRunning = false
    @State private var detailHeaderWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            tabBar
            Divider()
            Group {
                switch tab {
                case .overview: overview
                case .logs: logsPanel
                case .terminal: terminalPanel
                case .stats: statsPanel
                case .inspect: inspectPanel
                case .files: ScrollView { filesPanel }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: tab) { oldValue, _ in
            if oldValue == .logs { cancelFollowLogs() }
        }
        .onChange(of: isActive) { _, active in
            if !active { cancelFollowLogs() }
        }
        .onDisappear { cancelFollowLogs() }
        .task(id: "\(resource.id)-\(tab.rawValue)-\(followLogs)-\(isActive)") {
            guard isActive else { return }
            if tab == .logs || tab == .inspect || tab == .files { await load() }
        }
    }

    private var detailHeader: some View {
        Group {
            if detailHeaderWidth < 900 {
                VStack(alignment: .leading, spacing: 8) {
                    detailIdentity.frame(maxWidth: .infinity, alignment: .leading)
                    detailActions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 12) {
                    detailIdentity
                        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                    detailActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailHeaderWidth = $0 }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var detailIdentity: some View {
        HStack(spacing: 12) {
            Image(systemName: section.symbol).font(.title2).foregroundStyle(.tint).frame(width: 36, height: 36).background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(resource.title).font(.headline).lineLimit(1).truncationMode(.middle).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if let state = resource.state { StateBadge(state: state).fixedSize(horizontal: true, vertical: false) }
                }
                Text(resource.subtitle ?? resource.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
        }
    }

    @ViewBuilder private var detailActions: some View {
        HStack(spacing: 8) {
            if section == .containers {
                Button("Start", systemImage: "play.fill") { action(.start) }.disabled((resource.state ?? "").lowercased().contains("running") || limitsOperationInProgress)
                Button("Restart", systemImage: "arrow.clockwise") { action(.restart) }.disabled(limitsOperationInProgress)
                Button("Stop", systemImage: "stop.fill", role: .destructive) { action(.stop) }.disabled(!(resource.state ?? "").lowercased().contains("running") || limitsOperationInProgress)
                Button("Edit Limits…", systemImage: "slider.horizontal.3", action: onEditLimits)
                    .disabled(store.cliPath != nil || store.limitsOperationContainerID != nil)
                    .help(store.cliPath != nil ? "Edit Limits requires the default Apple Container CLI; a CLI override is active" : store.limitsOperationContainerID != nil ? "A container limits recreation is already in progress" : "Recreate this container with new CPU and memory limits")
            } else if section == .images {
                Button("Run", systemImage: "play.fill") { onRun(resource.details.imageReference ?? resource.title) }
                Button("Push", systemImage: "arrow.up.circle") { action(.push) }
                Menu {
                    Button("Save Archive…", systemImage: "square.and.arrow.down") { action(.save) }
                    Button("Add Tag…", systemImage: "tag") { action(.tag) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            } else if section == .machines {
                Button("Stop", systemImage: "stop.fill", role: .destructive) { action(.stop) }
            }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh details").disabled(isLoading || tab == .terminal)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var tabBar: some View {
        DetailTabStrip(selection: Binding(
            get: { tab.rawValue },
            set: { value in
                if let selected = ResourceDetailTab(rawValue: value) {
                    tab = selected
                    error = nil
                }
            }
        ), tabs: availableTabs.map(\.rawValue))
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var overview: some View {
        if section == .images { imageOverview }
        else { resourceOverview }
    }

    private var resourceOverview: some View {
        Form {
            Section("Resource") {
                LabeledContent("Name", value: resource.title)
                LabeledContent("Identifier", value: resource.id)
                if let subtitle = resource.subtitle { LabeledContent("Details", value: subtitle) }
                LabeledContent("State", value: resource.state ?? "Unknown")
                LabeledContent("Type", value: section.title)
            }
            Section {
                if let details = resource.details.imageReference { LabeledContent("Image", value: details) }
                if let platform = resource.details.platform { LabeledContent("Platform", value: platform) }
                if let size = resource.details.sizeBytes { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                if let digest = resource.details.digest { LabeledContent("Digest", value: digest).textSelection(.enabled) }
                if let driver = resource.details.driver { LabeledContent("Driver", value: driver) }
                if let subnet = resource.details.ipv4Subnet { LabeledContent("IPv4 Subnet", value: subnet) }
                if let count = resource.details.cpuCount { LabeledContent("CPUs", value: "\(count)") }
                if let memory = resource.details.memoryBytes ?? resource.details.memoryLimitBytes { LabeledContent("Memory", value: ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)) }
                if let username = resource.details.registryUsername { LabeledContent("Username", value: username) }
                if section == .containers {
                    ForEach(resource.details.publishedPorts) { port in LabeledContent("Port", value: port.hostPort.map { "\($0) → \(port.containerPort)/\(port.proto ?? "tcp")" } ?? "\(port.containerPort)/\(port.proto ?? "tcp")") }
                }
            }
            if !resource.details.labels.isEmpty {
                Section("Labels") { ForEach(resource.details.labels.keys.sorted(), id: \.self) { key in LabeledContent(key, value: resource.details.labels[key] ?? "") } }
            }
        }
        .formStyle(.grouped)
    }

    private var imageOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(resource.title).font(.headline).textSelection(.enabled)
                        Text(resource.details.imageReference ?? resource.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
                    imageMetadata("Repository", value: resource.details.imageRepository ?? resource.title)
                    imageMetadata("Tag", value: resource.details.imageTag ?? "—")
                    imageMetadata("Platform", value: resource.details.platform ?? "—")
                    imageMetadata("Size", value: resource.details.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    imageMetadata("Digest", value: resource.details.digest ?? "—")
                    imageMetadata("Identifier", value: resource.id)
                }
                if let imageTag = resource.details.imageTag {
                    HStack(spacing: 7) {
                        Text("Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        tagChip(imageTag)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(18)
        }
    }

    private func imageMetadata(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tagChip(_ tag: String) -> some View {
        Text(tag).font(.caption.monospaced()).padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule()).foregroundStyle(.tint)
    }

    private var logsCommand: [String] {
        section == .machines ? ["machine", "logs", resource.id] : ["logs", resource.id]
    }

    private var availableTabs: [ResourceDetailTab] {
        switch section {
        case .containers: ResourceDetailTab.allCases
        case .machines: [.overview, .logs, .terminal, .inspect]
        case .images: [.overview, .inspect]
        default: [.overview, .inspect]
        }
    }

    private var logsPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Container Logs", systemImage: "text.alignleft").font(.headline)
                TextField("Search logs", text: $logQuery).textFieldStyle(.roundedBorder).frame(maxWidth: 210)
                Spacer(minLength: 12)
                Toggle("Follow", isOn: $followLogs).toggleStyle(.switch)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visibleText, forType: .string)
                }.disabled(visibleText.isEmpty)
            }
            outputText
        }
        .padding(12)
    }

    private var statsPanel: some View {
        let isSelectedTarget = store.statsTarget == resource.id
        let metric = isSelectedTarget ? store.selectedContainerMetric : store.containerMetrics[resource.id]
        let allocatedCPUs = (resource.details.cpuCount ?? resource.details.cpuAllocation).flatMap { $0 > 0 ? $0 : nil }
        let oneCorePercent = metric?.cpuPercent
        let allocationPercent = ContainerCPUUsage.allocationPercent(oneCorePercent: oneCorePercent, allocatedCPUs: allocatedCPUs)
        let cpuTitle: String
        let cpuValue: String
        let cpuDetail: String
        let cpuAccessibility: String
        if let allocatedCPUs, let allocationPercent {
            cpuTitle = "CPU of limit"
            cpuValue = String(format: "%.1f%%", allocationPercent)
            cpuDetail = "\(allocatedCPUs) CPUs allocated · \(String(format: "%.1f", oneCorePercent ?? 0))% of one core"
            cpuAccessibility = "CPU is \(String(format: "%.1f", allocationPercent)) percent of the configured \(allocatedCPUs)-CPU limit. Raw usage is \(String(format: "%.1f", oneCorePercent ?? 0)) percent of one core."
        } else if let oneCorePercent, let coreEquivalents = ContainerCPUUsage.coreEquivalents(oneCorePercent: oneCorePercent) {
            cpuTitle = "CPU · one core"
            cpuValue = String(format: "%.1f%%", oneCorePercent)
            cpuDetail = "\(String(format: "%.2f", coreEquivalents)) core equivalents · CPU limit unavailable"
            cpuAccessibility = "CPU usage is \(String(format: "%.1f", oneCorePercent)) percent of one core, or \(String(format: "%.2f", coreEquivalents)) core equivalents. Configured CPU limit is unavailable."
        } else {
            cpuTitle = allocatedCPUs == nil ? "CPU · one core" : "CPU of limit"
            cpuValue = "—"
            cpuDetail = allocatedCPUs.map { "\($0) CPUs allocated · waiting for sample" } ?? "CPU limit unavailable · waiting for sample"
            cpuAccessibility = cpuDetail
        }
        let memoryLimit = resource.details.memoryLimitBytes
        let memoryUsage = metric?.memoryUsageBytes
        let memoryValue = memoryUsage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—"
        let memoryDetail = memoryLimit.map { "Limit \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory))" } ?? "No memory limit reported"
        let memoryAccessibility = "Memory use \(memoryValue). \(memoryDetail)."
        let source: String
        switch store.containerMetricsBackend {
        case .some(.nativeAPI): source = "Native API · every second; CPU after the second sample"
        case .some(.cli): source = "CLI · about 3 seconds; CPU after the second sample"
        case nil: source = "Waiting for the first stats sample"
        }
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Live resource usage").font(.headline)
                        Spacer(minLength: 8)
                        Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Live resource usage").font(.headline)
                        Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                HStack(spacing: 14) {
                    metricCard(cpuTitle, value: cpuValue, detail: cpuDetail, accessibility: cpuAccessibility, symbol: "cpu")
                    metricCard("Memory use", value: memoryValue, detail: memoryDetail, accessibility: memoryAccessibility, symbol: "memorychip")
                }
                Label("Use Edit Limits… to change these values. Apple Container 1.5 recreates the container, causing downtime and resetting its processes and ephemeral network state.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let reason = store.containerMetricsFallbackReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if isSelectedTarget, let statsError = store.statsError { Text(statsError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metricCard(_ title: String, value: String, detail: String, accessibility: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .help(accessibility)
    }

    private var terminalPanel: some View {
        Group {
            if section == .containers {
                ContainerTerminalView(arguments: ["exec", "--interactive", "--tty", resource.id, "/bin/sh"], executablePath: store.cliPath)
            } else if section == .machines {
                ContainerTerminalView(arguments: ["machine", "run", "--name", resource.id], executablePath: store.cliPath)
            } else {
                ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text("A terminal is available for running containers and Linux machines."))
            }
        }
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Container file transfer").font(.headline); Spacer(); if fileOperationRunning { ProgressView().controlSize(.small) } }
            Text("Copy files between this Mac and the running container. Choose the source and destination paths below.")
                .font(.caption).foregroundStyle(.secondary)
            Label("A mounted volume can hide files copied into its mount path. Use the volume workflow or choose an unmounted container path.", systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("Mac to container") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { TextField("Local source path", text: $hostPath, prompt: Text("~/Desktop/config.json")); Button("Choose…") { fileImporter = true } }
                    TextField("Container destination path", text: $containerDestinationPath, prompt: Text("/etc/app/"))
                    Button("Copy to Container", systemImage: "arrow.right") { Task { await copyToContainer() } }
                        .disabled(hostPath.isEmpty || containerDestinationPath.isEmpty || fileOperationRunning)
                }.padding(.top, 5)
            }
            GroupBox("Container to Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Container source path", text: $containerSourcePath, prompt: Text("/var/log/app.log"))
                    HStack { TextField("Mac destination path", text: $hostDestinationPath, prompt: Text("~/Downloads/")); Button("Choose…") { chooseHostDestination() } }
                    Button("Copy to Mac", systemImage: "arrow.left") { Task { await copyFromContainer() } }
                        .disabled(hostDestinationPath.isEmpty || containerSourcePath.isEmpty || fileOperationRunning)
                }.padding(.top, 5)
            }
            HStack {
                Button("Export Filesystem as Tar…", systemImage: "archivebox") { exportContainer() }.disabled(fileOperationRunning)
                Spacer()
                Button("List Root Files", systemImage: "list.bullet") { Task { await loadRootFiles() } }.disabled(fileOperationRunning)
            }
            if !fileOutput.isEmpty {
                ScrollView([.horizontal, .vertical]) { Text(fileOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8)).frame(minHeight: 90)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
        }
        .padding(.horizontal)
        .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.content, .data], allowsMultipleSelection: false) { result in
            switch result { case .success(let urls): if let url = urls.first { hostPath = url.path }; case .failure(let issue): error = issue.localizedDescription }
        }
    }

    private func copyToContainer() async {
        await runFileCommand(["copy", localPath(hostPath), "\(resource.id):\(containerDestinationPath)"], title: "Copy File to Container")
    }
    private func copyFromContainer() async {
        await runFileCommand(["copy", "\(resource.id):\(containerSourcePath)", localPath(hostDestinationPath)], title: "Copy File from Container")
    }
    private func loadRootFiles() async {
        await runFileCommand(["exec", resource.id, "ls", "-la", "/"], title: "List Container Files")
    }
    private func runFileCommand(_ arguments: [String], title: String) async {
        fileOperationRunning = true; error = nil; fileOutput = ""
        do {
            let result = try await store.execute(CommandRequest(arguments: arguments, captureLimit: 200_000, suppressOutputEvents: true), title: title)
            fileOutput = result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError)
            guard result.succeeded else { throw FeatureCommandError(result: result) }
        } catch { self.error = error.localizedDescription }
        fileOperationRunning = false
    }
    private func chooseHostDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "container-file"
        if panel.runModal() == .OK, let url = panel.url { hostDestinationPath = url.path }
    }
    private func exportContainer() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.archive]
        panel.nameFieldStringValue = "\(resource.title).tar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await runFileCommand(["export", "--output", url.path, resource.id], title: "Export Container Filesystem") }
    }

    private func localPath(_ value: String) -> String { (value as NSString).expandingTildeInPath }

    private var inspectPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environment values are redacted before display.")
                .font(.caption).foregroundStyle(.secondary)
            if let inspectBackend {
                Label(inspectBackend == .nativeAPI ? "Native API" : (inspectFallbackReason == nil ? "Container CLI" : "CLI fallback"), systemImage: inspectBackend == .nativeAPI ? "bolt.horizontal.circle" : "terminal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let inspectFallbackReason { Text(inspectFallbackReason).font(.caption).foregroundStyle(.secondary) }
            outputText
        }
        .padding(.horizontal)
    }

    private func outputPanel(title: String, command: [String], sensitive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); if isLoading { ProgressView().controlSize(.small) } }
            outputText
        }
        .padding(.horizontal)
    }

    @ViewBuilder private var outputText: some View {
        if let error { ContentUnavailableView("Command failed", systemImage: "exclamationmark.triangle", description: Text(error)) }
        else if transientText.isEmpty {
            if isLoading { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView("No output", systemImage: "text.alignleft") }
        }
        else {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(visibleText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: proxy.size.width, alignment: .leading)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var visibleText: String {
        guard tab == .logs, !logQuery.isEmpty else { return transientText }
        return transientText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(logQuery) }.joined(separator: "\n")
    }

    private func load() async {
        var loadOperationID: UUID?
        isLoading = true
        error = nil
        transientText = ""
        if tab == .inspect { inspectBackend = nil; inspectFallbackReason = nil }
        let args: [String]
        switch tab {
        case .logs: args = logsCommand
        case .stats: isLoading = false; return
        case .inspect:
            switch section {
            case .containers: args = ["inspect", resource.id]
            case .images: args = ["image", "inspect", resource.id]
            case .volumes: args = ["volume", "inspect", resource.id]
            case .networks: args = ["network", "inspect", resource.id]
            case .machines: args = ["machine", "inspect", resource.id]
            default: args = ["inspect", resource.id]
            }
        case .files: args = ["exec", resource.id, "ls", "-la", "/"]
        default: isLoading = false; return
        }
        do {
            if tab == .logs && followLogs {
                transientText = ""
                let ownedStream = store.streamWithID(CommandRequest(arguments: args + ["--follow"], captureLimit: 500_000), title: "Follow Container Logs")
                loadOperationID = ownedStream.operationID
                operationID = loadOperationID
                for try await event in ownedStream.events {
                    try Task.checkCancellation()
                    switch event {
                    case .standardOutput(let chunk): appendTransient(chunk)
                    case .standardError(let chunk): appendTransient(chunk)
                    case .completed(let result): if !result.succeeded { throw FeatureCommandError(result: result) }
                    }
                }
            } else if tab == .stats {
                repeat {
                    let result = try await store.client.run(CommandRequest(arguments: args, captureLimit: 200_000, suppressOutputEvents: true))
                    guard result.succeeded else { throw FeatureCommandError(result: result) }
                    transientText = String(result.standardOutput.suffix(150_000))
                    try await Task.sleep(for: .seconds(1))
                } while !Task.isCancelled
            } else {
                if tab == .inspect, section == .containers {
                    let result = try await store.inspectContainer(id: resource.id)
                    try Task.checkCancellation()
                    inspectBackend = result.backend
                    inspectFallbackReason = result.fallbackReason
                    transientText = result.value.json
                } else {
                    let result = try await store.client.run(CommandRequest(arguments: args, captureLimit: 500_000, suppressOutputEvents: true))
                    guard result.succeeded else { throw FeatureCommandError(result: result) }
                    // Raw inspect bytes are never kept in view state; persist only the sanitized rendering.
                    transientText = tab == .inspect ? InspectRedactor.redact(result.standardOutput) : result.standardOutput
                    if tab == .inspect { inspectBackend = .cli; inspectFallbackReason = nil }
                }
            }
        } catch is CancellationError {
            if let loadOperationID {
                store.cancelOperation(loadOperationID)
                if operationID == loadOperationID { operationID = nil }
            }
        } catch { self.error = error.localizedDescription }
        if operationID == loadOperationID { operationID = nil }
        isLoading = false
    }

    private func cancelFollowLogs() {
        guard let operationID else { return }
        store.cancelOperation(operationID)
        self.operationID = nil
    }

    private func appendTransient(_ chunk: String) {
        transientText += chunk
        if transientText.count > 150_000 { transientText = String(transientText.suffix(150_000)) }
    }
}

enum InspectRedactor {
    static func redact(_ source: String) -> String {
        guard let data = source.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            return source.split(separator: "\n", omittingEmptySubsequences: false).map { redactEnvironmentLine(String($0)) }.joined(separator: "\n")
        }
        let safe = redactObject(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]), let text = String(data: safeData, encoding: .utf8) else { return "(Inspect output hidden because it could not be safely redacted.)" }
        return text
    }

    private static func redactObject(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { item in redactObject(item) }.reduce(into: [String: Any]()) { result, pair in
                if pair.key.lowercased() == "environment", let environment = dictionary[pair.key] as? [Any] {
                    result[pair.key] = environment.map { value -> String in
                        guard let item = value as? String else { return "••••" }
                        return redactEnvironmentLine(item)
                    }
                } else { result[pair.key] = pair.value }
            }
        }
        if let array = value as? [Any] { return array.map(redactObject) }
        return value
    }

    private static func redactEnvironmentLine(_ line: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return "••••" }
        return String(line[...equals]) + "••••"
    }
}

