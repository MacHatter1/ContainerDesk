import AppKit
import ContainerDeskCore
import SwiftUI

struct MLXFeatureView: View {
    @Bindable var store: MLXStore
    @Bindable var externalStore: ExternalMLXStore
    let sceneID: String

    @State private var page = MLXModelsPage.models
    @State private var query = ""
    @State private var selectedID: String?
    @State private var sortOrder: [KeyPathComparator<MLXModelRecord>] = [KeyPathComparator(\.displayName)]
    @State private var externalQuery = ""
    @State private var detailTab = "Overview"
    @State private var showingDownload = false
    @State private var showingStopConfirmation: MLXServerSession?
    @State private var showingRemoveConfirmation: MLXModelRecord?
    @State private var errorMessage: String?
    @State private var notice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredModels: [MLXModelRecord] {
        let values = store.models.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) ||
                $0.id.localizedCaseInsensitiveContains(query) ||
                ($0.repositoryID?.localizedCaseInsensitiveContains(query) ?? false) ||
                ($0.modelType?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return values.sorted(using: sortOrder)
    }
    private var selectedModel: MLXModelRecord? { store.models.first { $0.id == selectedID } }
    private var visibleExternalServers: [MLXExternalServerRecord] {
        let ownedPorts = Set(store.runningServers.filter { [.starting, .running, .stopping].contains($0.state) }.map(\.port))
        return externalStore.visibleServers(excludingPorts: ownedPorts)
    }
    private var modelServer: MLXServerSession? { store.runningServers.first { $0.modelID == selectedModel?.id && $0.state != .stopped && $0.state != .failed } }
    private var latestModelServer: MLXServerSession? {
        let sessions = store.runningServers.filter { $0.modelID == selectedModel?.id }
        return sessions.first(where: { $0.state == .running })
            ?? sessions.first(where: { $0.state == .starting })
            ?? sessions.first(where: { $0.state == .stopping })
            ?? sessions.first(where: { $0.state == .failed })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let notice { InlineNotice(message: notice, kind: .success).padding(.horizontal, 16).padding(.vertical, 8).transition(.opacity.combined(with: .move(edge: .top))) }
            if page == .models {
                GeometryReader { geometry in
                    VSplitView {
                        modelTable
                            .frame(width: geometry.size.width)
                            .frame(minHeight: 170, idealHeight: 390, maxHeight: .infinity)
                        detailPane
                            .frame(width: geometry.size.width)
                            .frame(minHeight: 240, idealHeight: 320, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ExternalMLXServicesView(externalStore: externalStore, mlxStore: store, sceneID: sceneID, query: $externalQuery) { endpoint in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(endpoint.absoluteString, forType: .string)
                    postNotice("Copied the verified loopback endpoint. This service is externally managed and read only in ContainerDesk.")
                }
            }
            footer
        }
        .navigationTitle("MLX Models")
        .task { if page == .models { await store.refresh() } }
        .sheet(isPresented: $showingDownload) {
            MLXDownloadSheet(store: store) { errorMessage = $0 }
        }
        .confirmationDialog("Stop this local model server?", isPresented: Binding(
            get: { showingStopConfirmation != nil }, set: { if !$0 { showingStopConfirmation = nil } }
        ), titleVisibility: .visible, presenting: showingStopConfirmation) { session in
            Button("Stop Server", role: .destructive) {
                Task { do { try await store.stopServer(session) } catch { errorMessage = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { }
        } message: { session in
            Text("ContainerDesk will stop its owned server for this model at 127.0.0.1:\(String(session.port)). Other local processes are not affected.")
        }
        .confirmationDialog("Remove this model reference?", isPresented: Binding(
            get: { showingRemoveConfirmation != nil }, set: { if !$0 { showingRemoveConfirmation = nil } }
        ), titleVisibility: .visible, presenting: showingRemoveConfirmation) { model in
            Button(model.source == .appManagedDownload ? "Move to Trash" : "Forget Reference", role: .destructive) {
                Task {
                    do {
                        if model.source == .appManagedDownload { try await store.trash(model) }
                        else { try await store.forget(model) }
                        if selectedID == model.id { selectedID = nil }
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { model in
            Text(model.source == .appManagedDownload
                 ? "Move the ContainerDesk-managed copy of \(model.displayName) to macOS Trash. Cached and imported files will not be changed."
                 : "Remove \(model.displayName) from ContainerDesk. The files in its folder will remain untouched.")
        }
        .alert("MLX", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: selectedID) { _, _ in detailTab = "Overview" }
        .animation(ContainerDeskMotion.animation(reduceMotion: reduceMotion), value: notice)
        .onAppear { port = store.preferredPort }
        .onChange(of: port) { _, value in store.setPreferredPort(value) }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarSingleRow
            toolbarCompactRows
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var pagePicker: some View {
        Picker("MLX view", selection: $page) {
            ForEach(MLXModelsPage.allCases) { option in Text(option.title).tag(option) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("MLX view")
        .fixedSize()
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task {
                if page == .models { await store.refresh() }
                else { await externalStore.refresh(force: true) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(page == .models ? "Refresh local model discovery" : "Rescan current-user MLX loopback services")
    }

    private var importButton: some View {
        Button("Import Folder…", systemImage: "folder.badge.plus", action: importFolder)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var downloadButton: some View {
        Button("Download Model…", systemImage: "arrow.down.circle") { showingDownload = true }
            .buttonStyle(.borderedProminent)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!store.capability.available || store.isShuttingDown)
    }

    private var toolbarSingleRow: some View {
        HStack(spacing: 10) {
            pagePicker
            searchField(minimumWidth: 140)
            Spacer(minLength: 4)
            refreshButton
            if page == .models { importButton; downloadButton }
        }
    }

    private var toolbarCompactRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                pagePicker
                searchField(minimumWidth: 140)
                Spacer(minLength: 0)
                refreshButton
            }
            if page == .models {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    importButton
                    downloadButton
                }
            }
        }
    }

    private func searchField(minimumWidth: CGFloat) -> some View {
        TextField(page == .models ? "Search local models" : "Search running services", text: page == .models ? $query : $externalQuery)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: minimumWidth, maxWidth: 280)
    }

    private var modelTable: some View {
        Table(filteredModels, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.displayName) { model in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.system(.body, weight: .medium)).lineLimit(1)
                    Text(model.repositoryID ?? model.path.lastPathComponent)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(model.path.path)
            }
            .width(min: 220, ideal: 340)
            TableColumn("Source") { model in Label(sourceLabel(model.source), systemImage: sourceIcon(model.source)).foregroundStyle(.secondary) }
                .width(min: 130, ideal: 170)
            TableColumn("Type") { model in Text(model.modelType ?? "—").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 110, ideal: 150)
            TableColumn("Quantization") { model in Text(model.quantizationBits.map { "\($0)-bit" } ?? "—").foregroundStyle(.secondary) }
                .width(min: 105, ideal: 125)
            TableColumn("Size") { model in Text(byteCount(model.diskBytes)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 85, ideal: 105)
            TableColumn("Local Server") { model in
                if let server = store.runningServers.first(where: { $0.modelID == model.id && $0.state != .stopped }) {
                    Label(server.state.rawValue.capitalized, systemImage: server.state == .running ? "circle.fill" : "circle.dashed")
                        .font(.caption).foregroundStyle(server.state == .running ? .green : .secondary)
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 110, ideal: 140)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let model = selectedModel {
                detailHeader(model)
                DetailTabStrip(selection: $detailTab, tabs: ["Overview", "Server Logs", "Chat"])
                    .padding(.horizontal, 18)
                Group {
                    switch detailTab {
                    case "Server Logs": serverLogs(model)
                    case "Chat": MLXChatPlayground(store: store, sceneID: sceneID, server: latestModelServer, maxTokens: $maxTokens, temperature: $temperature)
                    default: overview(model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
                .animation(ContainerDeskMotion.animation(reduceMotion: reduceMotion), value: detailTab)
            } else {
                FeatureEmptyState(title: "Select a local model", message: emptyDescription, symbol: "cpu")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func detailHeader(_ model: MLXModelRecord) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName).font(ContainerDeskTypography.detailTitle).lineLimit(1)
                Text("\(sourceLabel(model.source)) · \(model.modelType ?? "MLX model") · \(byteCount(model.diskBytes))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let server = modelServer {
                Button("Stop Server", systemImage: "stop.fill") { showingStopConfirmation = server }
                    .disabled(server.state == .stopping)
                if server.state == .running { Button("Copy Endpoint", systemImage: "doc.on.doc") { copyEndpoint(server) } }
            } else {
                Button("Start Server", systemImage: "play.fill") { Task { await startServer(model) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.capability.available || !model.isReady || store.isShuttingDown)
            }
            if model.source == .appManagedDownload || model.source == .importedDirectory {
                Menu {
                    Button(model.source == .appManagedDownload ? "Move to Trash…" : "Forget Reference…", systemImage: "trash", role: .destructive) {
                        showingRemoveConfirmation = model
                    }
                    .disabled(store.isModelInUse(model.id))
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .help(model.source == .appManagedDownload ? "Model actions" : "Imported model actions")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func overview(_ model: MLXModelRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let server = modelServer {
                    serverControls(server)
                } else {
                    if let failed = latestModelServer, failed.state == .failed {
                        NeutralPanel(title: "Server failed") {
                            Text(failed.detail ?? "The local MLX server stopped unexpectedly.")
                                .foregroundStyle(.red)
                            if let output = store.serverOutput[failed.id], !output.isEmpty {
                                Text(String(output.suffix(1_500)))
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    serverConfiguration(model)
                }
                NeutralPanel(title: "Model details") {
                    Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 9) {
                        detailRow("Source", sourceLabel(model.source))
                        detailRow("Model type", model.modelType ?? "Not reported")
                        detailRow("Parameters", model.parameterCount.map(parameterCount) ?? "Not reported")
                        detailRow("Quantization", model.quantizationBits.map { "\($0)-bit" } ?? "Not reported")
                        detailRow("Files", model.fileCount.formatted())
                        detailRow("Disk usage", byteCount(model.diskBytes))
                        detailRow("Repository", model.repositoryID ?? "Local folder")
                        if let revision = model.revision { detailRow("Revision", revision) }
                        detailRow("Path", model.path.path)
                    }
                }
                if !store.capability.available { capabilityNotice }
                if let modelError = store.modelError {
                    NeutralPanel(title: "Model discovery failed") { Text(modelError).foregroundStyle(.secondary) }
                }
            }
            .padding(18)
        }
    }

    private func serverConfiguration(_ model: MLXModelRecord) -> some View {
        NeutralPanel(title: "Local inference server") {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                LabeledContent("Address", value: "127.0.0.1")
                LabeledContent("Port", value: String(port))
                Text("Server binds to this Mac only.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                TextField("Port", value: $port, format: .number.grouping(.never)).frame(width: 90)
                Stepper("Max tokens · \(maxTokens)", value: $maxTokens, in: 1...32_768, step: 128)
                    .frame(maxWidth: 240)
                HStack { Text("Temperature"); Slider(value: $temperature, in: 0...2, step: 0.05).frame(width: 130); Text(temperature, format: .number.precision(.fractionLength(2))).monospacedDigit() }
            }
            HStack {
                LabeledPrimaryButton(title: "Start Server", systemImage: "play.fill") { Task { await startServer(model) } }
                    .disabled(!store.capability.available || !model.isReady || !((1024...65535).contains(Int(port))) || store.isShuttingDown)
                Text("Starting a server may load model weights into unified memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @State private var port: UInt16 = 8080
    @State private var maxTokens = 512
    @State private var temperature = 0.0

    private func serverControls(_ session: MLXServerSession) -> some View {
        NeutralPanel(title: "App-owned server") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                detailRow("State", session.state.rawValue.capitalized)
                detailRow("Endpoint", "http://127.0.0.1:\(String(session.port))/v1")
                detailRow("Maximum tokens", "\(maxTokens)")
                detailRow("Temperature", temperature.formatted(.number.precision(.fractionLength(2))))
            }
            HStack {
                Button("Copy Endpoint", systemImage: "doc.on.doc") { copyEndpoint(session) }
                Spacer()
                Button("Stop Server…", systemImage: "stop.fill", role: .destructive) { showingStopConfirmation = session }
                    .disabled(session.state == .stopping)
            }
            Text("This server is owned by ContainerDesk and listens only on 127.0.0.1.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func serverLogs(_ model: MLXModelRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Server output").font(.headline)
                Spacer()
                if let server = latestModelServer {
                    Text(server.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.serverOutput[server.id] ?? "", forType: .string) }
                }
            }
            if let server = latestModelServer {
                ScrollView {
                    Text(store.serverOutput[server.id] ?? "Waiting for local server output…")
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
            } else {
                ContentUnavailableView("No server for this model", systemImage: "server.rack", description: Text("Start the local server from Overview to see its live output here."))
            }
        }
        .padding(18)
    }

    private var capabilityNotice: some View {
        NeutralPanel(title: "MLX-LM is not available") {
            Text(store.capability.reason ?? "Install MLX-LM in a Python environment, then choose its executable in Settings.")
                .foregroundStyle(.secondary)
            Button("Open MLX-LM setup guide") { NSWorkspace.shared.open(URL(string: "https://github.com/ml-explore/mlx-lm")!) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if page == .models {
                Circle().fill(store.capability.available ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(store.capability.available ? "MLX-LM \(store.capability.mlxLMVersion ?? "available")" : "MLX-LM unavailable")
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("\(store.models.count) local model\(store.models.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            } else {
                Circle().fill(visibleExternalServers.contains(where: { $0.status == .reachable }) ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text("\(visibleExternalServers.count) external service\(visibleExternalServers.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if let refreshedAt = externalStore.refreshedAt {
                    Text("·").foregroundStyle(.tertiary)
                    Text("Scanned \(refreshedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if page == .models {
                if store.downloadInProgress { ProgressView().controlSize(.small); Text("Downloading…").font(.caption).foregroundStyle(.secondary) }
                Text("Loopback only · no remote inference").font(.caption).foregroundStyle(.tertiary)
            } else {
                if externalStore.isRefreshing { ProgressView().controlSize(.small) }
                Text("External · read only · loopback").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyDescription: String {
        if let modelError = store.modelError { return modelError }
        return store.capability.available
            ? "Import a validated model folder or explicitly download a Hugging Face model to get started."
            : store.capability.reason ?? "Configure MLX-LM in Settings to discover local models."
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Model Folder"
        panel.message = "Choose a local MLX model directory containing weights and tokenizer files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await store.importModel(at: url); selectedID = store.models.first(where: { $0.path.standardizedFileURL == url.standardizedFileURL })?.id }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func startServer(_ model: MLXModelRecord) async {
        do { try await store.startServer(for: model, port: port, maxTokens: maxTokens, temperature: temperature) }
        catch { errorMessage = error.localizedDescription }
    }

    private func copyEndpoint(_ session: MLXServerSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(String(session.port))/v1", forType: .string)
        postNotice("Copied the local OpenAI-compatible endpoint. It listens only on 127.0.0.1.")
    }

    private func postNotice(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == message { notice = nil }
        }
    }

    private func sourceLabel(_ source: MLXModelSource) -> String {
        switch source { case .huggingFaceCache: "Hugging Face cache"; case .importedDirectory: "Imported folder"; case .appManagedDownload: "Managed download" }
    }

    private func sourceIcon(_ source: MLXModelSource) -> String {
        switch source { case .huggingFaceCache: "shippingbox"; case .importedDirectory: "folder"; case .appManagedDownload: "arrow.down.app" }
    }

    private func byteCount(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func parameterCount(_ count: Int64) -> String { count >= 1_000_000_000 ? String(format: "%.1fB", Double(count) / 1_000_000_000) : String(format: "%.0fM", Double(count) / 1_000_000) }
}

private enum MLXModelsPage: String, CaseIterable, Identifiable {
    case models
    case runningServices

    var id: String { rawValue }
    var title: String { self == .models ? "Models" : "Running Services" }
}


