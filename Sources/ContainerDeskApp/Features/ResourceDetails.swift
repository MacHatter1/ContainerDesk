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
    var operationState: String?
    var actionsUnavailable = false
    @Bindable var detailState: ResourceDetailState = .init()
    var terminalSession: ContainerTerminalSession? = nil

    private var isActive: Bool { activation.isActive }
    let onNotice: (FeatureNotice) -> Void
    let action: (ResourceActionKind) -> Void
    let onRun: (String) -> Void
    let onEditLimits: () -> Void

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
        .task(id: "\(resource.id)-\(tab.rawValue)-\(detailState.followLogs)-\(isActive)") {
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
                    if let state = resource.state { StateBadge(state: operationState ?? state).fixedSize(horizontal: true, vertical: false) }
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
                Button("Start", systemImage: "play.fill") { action(.start) }.disabled((resource.state ?? "").lowercased().contains("running") || limitsOperationInProgress || actionsUnavailable)
                Button("Restart", systemImage: "arrow.clockwise") { action(.restart) }.disabled(!(resource.state ?? "").lowercased().contains("running") || limitsOperationInProgress || actionsUnavailable)
                Button("Stop", systemImage: "stop.fill", role: .destructive) { action(.stop) }.disabled(!(resource.state ?? "").lowercased().contains("running") || limitsOperationInProgress || actionsUnavailable)
                Button("Edit Limits…", systemImage: "slider.horizontal.3", action: onEditLimits)
                    .disabled(store.cliPath != nil || store.limitsOperationContainerID != nil || actionsUnavailable)
                    .help(store.cliPath != nil ? "Edit Limits requires the default Apple Container CLI; a CLI override is active" : store.limitsOperationContainerID != nil ? "A container limits recreation is already in progress" : "Recreate this container with new CPU and memory limits")
            } else if section == .images {
                Button("Run", systemImage: "play.fill") { onRun(resource.details.imageReference ?? resource.title) }.disabled(actionsUnavailable)
                Button("Push", systemImage: "arrow.up.circle") { action(.push) }.disabled(actionsUnavailable)
                Menu {
                Button("Save Archive…", systemImage: "square.and.arrow.down") { action(.save) }.disabled(actionsUnavailable)
                    Button("Add Tag…", systemImage: "tag") { action(.tag) }.disabled(actionsUnavailable)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            } else if section == .machines {
                Button("Stop", systemImage: "stop.fill", role: .destructive) { action(.stop) }.disabled(actionsUnavailable)
            }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh details").disabled(detailState.isLoading || tab == .terminal)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var tabBar: some View {
        DetailTabStrip(selection: Binding(
            get: { tab.rawValue },
            set: { value in
                if let selected = ResourceDetailTab(rawValue: value) {
                    tab = selected
                    detailState.error = nil
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
        ResourceDetailTab.available(for: section)
    }

    private var logsPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Container Logs", systemImage: "text.alignleft").font(.headline)
                TextField("Search logs", text: $detailState.logQuery).textFieldStyle(.roundedBorder).frame(maxWidth: 210)
                Spacer(minLength: 12)
                Toggle("Follow", isOn: $detailState.followLogs).toggleStyle(.switch)
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
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                ContainerMetricsHistoryView(containerID: resource.id, monitoring: store.monitoring)
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var terminalPanel: some View {
        Group {
            if store.limitsOperationContainerID != nil {
                ContentUnavailableView("Limits change in progress", systemImage: "terminal", description: Text("The terminal will be available when the container limits change finishes."))
            } else if section == .containers {
                ContainerTerminalView(arguments: ["exec", "--interactive", "--tty", resource.id, "/bin/sh"], runtimeOperations: store.runtimeOperations, executablePath: store.cliPath, session: terminalSession)
            } else if section == .machines {
                ContainerTerminalView(arguments: ["machine", "run", "--name", resource.id], runtimeOperations: store.runtimeOperations, executablePath: store.cliPath, session: terminalSession)
            } else {
                ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text("A terminal is available for running containers and Linux machines."))
            }
        }
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Container file transfer").font(.headline); Spacer(); if detailState.fileOperationRunning { ProgressView().controlSize(.small) } }
            Text("Copy files between this Mac and the running container. Choose the source and destination paths below.")
                .font(.caption).foregroundStyle(.secondary)
            Label("A mounted volume can hide files copied into its mount path. Use the volume workflow or choose an unmounted container path.", systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("Mac to container") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { TextField("Local source path", text: $detailState.hostPath, prompt: Text("~/Desktop/config.json")); Button("Choose…") { detailState.fileImporter = true } }
                    TextField("Container destination path", text: $detailState.containerDestinationPath, prompt: Text("/etc/app/"))
                    Button("Copy to Container", systemImage: "arrow.right") { Task { await copyToContainer() } }
                        .disabled(detailState.hostPath.isEmpty || detailState.containerDestinationPath.isEmpty || detailState.fileOperationRunning)
                }.padding(.top, 5)
            }
            GroupBox("Container to Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Container source path", text: $detailState.containerSourcePath, prompt: Text("/var/log/app.log"))
                    HStack { TextField("Mac destination path", text: $detailState.hostDestinationPath, prompt: Text("~/Downloads/")); Button("Choose…") { chooseHostDestination() } }
                    Button("Copy to Mac", systemImage: "arrow.left") { Task { await copyFromContainer() } }
                        .disabled(detailState.hostDestinationPath.isEmpty || detailState.containerSourcePath.isEmpty || detailState.fileOperationRunning)
                }.padding(.top, 5)
            }
            HStack {
                Button("Export Filesystem as Tar…", systemImage: "archivebox") { exportContainer() }.disabled(detailState.fileOperationRunning)
                Spacer()
                Button("List Root Files", systemImage: "list.bullet") { Task { await loadRootFiles() } }.disabled(detailState.fileOperationRunning)
            }
            if !detailState.fileOutput.isEmpty {
                ScrollView([.horizontal, .vertical]) { Text(detailState.fileOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8)).frame(minHeight: 90)
            }
            if let currentError = detailState.error { Text(currentError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
        }
        .padding(.horizontal)
        .fileImporter(isPresented: $detailState.fileImporter, allowedContentTypes: [.content, .data], allowsMultipleSelection: false) { result in
            switch result { case .success(let urls): if let url = urls.first { detailState.hostPath = url.path }; case .failure(let issue): detailState.error = issue.localizedDescription }
        }
    }

    private func copyToContainer() async {
        await runFileCommand(["copy", localPath(detailState.hostPath), "\(resource.id):\(detailState.containerDestinationPath)"], title: "Copy File to Container")
    }
    private func copyFromContainer() async {
        await runFileCommand(["copy", "\(resource.id):\(detailState.containerSourcePath)", localPath(detailState.hostDestinationPath)], title: "Copy File from Container")
    }
    private func loadRootFiles() async {
        await runFileCommand(["exec", resource.id, "ls", "-la", "/"], title: "List Container Files")
    }
    private func runFileCommand(_ arguments: [String], title: String) async {
        detailState.fileOperationRunning = true; detailState.error = nil; detailState.fileOutput = ""
        do {
            let result = try await store.execute(CommandRequest(arguments: arguments, captureLimit: 200_000, suppressOutputEvents: true), title: title)
            detailState.fileOutput = result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError)
            guard result.succeeded else { throw FeatureCommandError(result: result) }
        } catch let issue { detailState.error = issue.localizedDescription }
        detailState.fileOperationRunning = false
    }
    private func chooseHostDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "container-file"
        if panel.runModal() == .OK, let url = panel.url { detailState.hostDestinationPath = url.path }
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
            if let backend = detailState.inspectBackend {
                Label(backend == .nativeAPI ? "Native API" : (detailState.inspectFallbackReason == nil ? "Container CLI" : "CLI fallback"), systemImage: backend == .nativeAPI ? "bolt.horizontal.circle" : "terminal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fallbackReason = detailState.inspectFallbackReason { Text(fallbackReason).font(.caption).foregroundStyle(.secondary) }
            outputText
        }
        .padding(.horizontal)
    }

    private func outputPanel(title: String, command: [String], sensitive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); if detailState.isLoading { ProgressView().controlSize(.small) } }
            outputText
        }
        .padding(.horizontal)
    }

    @ViewBuilder private var outputText: some View {
        if let currentError = detailState.error { ContentUnavailableView("Command failed", systemImage: "exclamationmark.triangle", description: Text(currentError)) }
        else if transientText.isEmpty {
            if detailState.isLoading { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
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
        guard tab == .logs, !detailState.logQuery.isEmpty else { return transientText }
        return transientText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(detailState.logQuery) }.joined(separator: "\n")
    }

    private func load() async {
        var loadOperationID: UUID?
        detailState.isLoading = true
        detailState.error = nil
        transientText = ""
        if tab == .inspect { detailState.inspectBackend = nil; detailState.inspectFallbackReason = nil }
        let args: [String]
        switch tab {
        case .logs: args = logsCommand
        case .stats: detailState.isLoading = false; return
        case .inspect:
            guard let inspection = ResourceActionRouting.inspectionArguments(section: section, target: resource.id) else {
                detailState.isLoading = false
                detailState.error = "This resource does not support inspection."
                return
            }
            args = inspection
        case .files: args = ["exec", resource.id, "ls", "-la", "/"]
        default: detailState.isLoading = false; return
        }
        do {
            if tab == .logs && detailState.followLogs {
                transientText = ""
                let ownedStream = store.streamWithID(CommandRequest(arguments: args + ["--follow"], captureLimit: 500_000), title: "Follow Container Logs")
                loadOperationID = ownedStream.operationID
                detailState.operationID = loadOperationID
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
                    detailState.inspectBackend = result.backend
                    detailState.inspectFallbackReason = result.fallbackReason
                    transientText = result.value.json
                } else {
                    let result = try await store.client.run(CommandRequest(arguments: args, captureLimit: 500_000, suppressOutputEvents: true))
                    guard result.succeeded else { throw FeatureCommandError(result: result) }
                    // Raw inspect bytes are never kept in view state; persist only the sanitized rendering.
                    transientText = tab == .inspect ? InspectRedactor.redact(result.standardOutput) : result.standardOutput
                    if tab == .inspect { detailState.inspectBackend = .cli; detailState.inspectFallbackReason = nil }
                }
            }
        } catch is CancellationError {
            if let loadOperationID {
                store.cancelOperation(loadOperationID)
                if detailState.operationID == loadOperationID { detailState.operationID = nil }
            }
        } catch let issue { detailState.error = issue.localizedDescription }
        if detailState.operationID == loadOperationID { detailState.operationID = nil }
        detailState.isLoading = false
    }

    private func cancelFollowLogs() {
        guard let activeOperationID = detailState.operationID else { return }
        store.cancelOperation(activeOperationID)
        detailState.operationID = nil
    }

    private func appendTransient(_ chunk: String) {
        BoundedText.append(chunk, to: &transientText)
    }
}

enum InspectRedactor {
    static func redact(_ source: String) -> String {
        (try? ResourceJSONRedactor.redact(source)) ?? "(Inspect output hidden because it could not be safely redacted.)"
    }
}
