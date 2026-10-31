import SwiftUI
import UniformTypeIdentifiers
import ContainerDeskCore

struct BuildFeatureView: View {
    let store: AppStore
    @State private var contextURL: URL?
    @State private var dockerfileURL: URL?
    @State private var tags = ""
    @State private var buildArgs = ""
    @State private var secrets = ""
    @State private var platform = ""
    @State private var target = ""
    @State private var cpus = ""
    @State private var memory = ""
    @State private var outputType = "type=oci"
    @State private var forwardSSH = false
    @State private var pull = false
    @State private var noCache = false
    @State private var contextImporter = false
    @State private var dockerfileImporter = false
    @State private var operation = BuildOperationStore()
    @State private var formError: String?
    private var running: Bool { operation.isRunning }
    private var progress: String { operation.output }
    private var error: String? { formError ?? operation.error }
    @State private var showBuilderDelete = false
    @State private var showAdvanced = false
    @State private var showBuildArgs = false
    @State private var showSecrets = false
    @State private var builderStatus: BuildKitStatus?
    @State private var builderStatusLoaded = false
    @State private var builderStatusError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 16) {
                ScrollView { buildForm.padding(16) }.frame(maxWidth: .infinity)
                builderPanel.frame(width: 250)
            }
            .frame(minHeight: 260, maxHeight: .infinity)
            Divider()
            outputPanel.padding(16).frame(minHeight: 170, idealHeight: 235)
            HStack { Label(running ? "Running BuildKit operation" : "BuildKit image builder", systemImage: running ? "hammer.fill" : "shippingbox"); Spacer(); Button("Advanced Build Options…", systemImage: "slider.horizontal.3") { showAdvanced = true }.disabled(running) }
                .font(.caption).foregroundStyle(.secondary).padding(10).background(.bar)
        }
        .task { await refreshBuilderStatus() }
        .onDisappear { operation.cancel() }
        .fileImporter(isPresented: $contextImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in switch result { case .success(let urls): if let url = urls.first { contextURL = url }; case .failure(let error): formError = error.localizedDescription } }
        .fileImporter(isPresented: $dockerfileImporter, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in switch result { case .success(let urls): dockerfileURL = urls.first; case .failure(let error): formError = error.localizedDescription } }
        .sheet(isPresented: $showAdvanced) { AdvancedCommandSheet(section: .builds, store: store) { _ in } }
        .confirmationDialog("Delete the image builder?", isPresented: $showBuilderDelete, titleVisibility: .visible) {
            Button("Delete Builder", role: .destructive) { Task { await builderAction(["builder", "delete"], title: "Delete Image Builder") } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The next build will recreate the builder container.") }
    }

    private var header: some View {
        WorkspaceHeader(title: "Build Images", subtitle: "BuildKit · Dockerfile or Containerfile · progress remains in this view", symbol: "hammer.fill", tint: .orange) {
            Button {
                if running { operation.cancel() } else { startBuild() }
            } label: {
                Label(running ? "Cancel Operation" : "Build Image", systemImage: running ? "xmark.circle" : "hammer.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!running && (contextURL == nil || tags.lines.isEmpty))
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshBuilderStatus() } }.disabled(running)
        }
    }

    private var buildForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Build context") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("Context") {
                        HStack { Text(contextURL?.path ?? "No folder selected").lineLimit(1).truncationMode(.middle).font(.system(.caption, design: .monospaced)); Spacer(); Button("Choose…") { contextImporter = true } }
                    }
                    LabeledContent("Dockerfile") {
                        HStack { Text(dockerfileURL?.lastPathComponent ?? "Dockerfile or Containerfile").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Choose…") { dockerfileImporter = true } }
                    }
                    TextField("Image tag", text: $tags, prompt: Text("app:latest, one tag per line"))
                        .font(.system(.body, design: .monospaced))
                }
            }
            GroupBox("Build settings") {
                VStack(alignment: .leading, spacing: 9) {
                    DisclosureGroup("Build arguments", isExpanded: $showBuildArgs) {
                        TextField("KEY=value, one per line", text: $buildArgs, axis: .vertical).lineLimit(2...4).font(.system(.body, design: .monospaced))
                    }
                    .animation(ContainerDeskMotion.animation(reduceMotion: reduceMotion), value: showBuildArgs)
                    DisclosureGroup("Build secrets", isExpanded: $showSecrets) {
                        TextField("id=...,src=... or env=..., one per line", text: $secrets, axis: .vertical).lineLimit(2...4).font(.system(.body, design: .monospaced))
                    }
                    .animation(ContainerDeskMotion.animation(reduceMotion: reduceMotion), value: showSecrets)
                    HStack {
                        LabeledContent("Platform") { TextField("linux/arm64", text: $platform).textFieldStyle(.roundedBorder) }
                        LabeledContent("Target") { TextField("production", text: $target).textFieldStyle(.roundedBorder) }
                    }
                    HStack {
                        LabeledContent("CPU limit") { TextField("2", text: $cpus).textFieldStyle(.roundedBorder) }
                        LabeledContent("Memory") { TextField("2048MB", text: $memory).textFieldStyle(.roundedBorder) }
                    }
                    TextField("Output", text: $outputType, prompt: Text("type=oci or type=tar,dest=..."))
                    HStack {
                        Toggle("Pull base images", isOn: $pull)
                        Toggle("Disable cache", isOn: $noCache)
                        Toggle("Forward SSH agent", isOn: $forwardSSH)
                    }
                }
                .padding(.top, 5)
            }
            Text("Choose a build folder and image tag before building. Build arguments and secrets are hidden in Activity.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var builderPanel: some View {
        AccentPanel(title: "BuildKit Builder", symbol: "shippingbox.fill", tint: .blue) {
            VStack(alignment: .leading, spacing: 10) {
            Text("Runs as a separate container with configurable CPU and memory limits.").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("State").foregroundStyle(.secondary); StateBadge(state: builderStateLabel) }
                GridRow { Text("CPU limit").foregroundStyle(.secondary); Text(builderStatus?.cpus.map { String($0) } ?? "—").monospacedDigit() }
                GridRow { Text("Memory limit").foregroundStyle(.secondary); Text(builderStatus?.memoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—").monospacedDigit() }
            }
            if let builderStatusError { Text(builderStatusError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            Button("Start Builder", systemImage: "play.fill") { Task { await builderAction(["builder", "start"], title: "Start Builder") } }.disabled(running || !builderStatusLoaded || builderStatusError != nil || builderIsRunning)
            Button("Stop Builder", systemImage: "stop.fill") { Task { await builderAction(["builder", "stop"], title: "Stop Builder") } }.disabled(running || !builderIsRunning)
            Button("Delete Builder…", systemImage: "trash", role: .destructive) { showBuilderDelete = true }.disabled(running)
            Spacer()
            Text("Builds use the selected folder as their working directory. The CLI finds Dockerfile first, then Containerfile.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var outputPanel: some View {
        AccentPanel(title: error == nil ? "Build output" : "Build needs attention", symbol: error == nil ? "terminal" : "exclamationmark.triangle.fill", tint: error == nil ? .teal : .red) {
          VStack(alignment: .leading, spacing: 6) {
            HStack { Spacer(); if running { ProgressView().controlSize(.small).transition(.opacity) } }
            if let error { InlineNotice(message: error, kind: .error).textSelection(.enabled) }
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(progress.isEmpty ? "Build output appears here while the operation runs." : progress)
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                        .padding(9)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
        .animation(ContainerDeskMotion.animation(reduceMotion: reduceMotion), value: running)
    }

    private func startBuild() {
        guard let contextURL, !tags.lines.isEmpty else { return }
        formError = nil
        var args = ["build"]
        if let dockerfileURL { args += ["--file", dockerfileURL.path] }
        for tag in tags.lines { args += ["--tag", tag] }
        for line in buildArgs.lines { args += ["--build-arg", line] }
        for line in secrets.lines { args += ["--secret", line] }
        if forwardSSH { args += ["--ssh", "default"] }
        if !target.isEmpty { args += ["--target", target] }
        if !platform.isEmpty { args += ["--platform", platform] }
        if !cpus.isEmpty { args += ["--cpus", cpus] }
        if !memory.isEmpty { args += ["--memory", memory] }
        if !outputType.isEmpty { args += ["--output", outputType] }
        if pull { args.append("--pull") }
        if noCache { args.append("--no-cache") }
        args.append(contextURL.path)
        let sensitive = buildArgs.lines.compactMap { $0.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) }
        let request = CommandRequest(arguments: args, workingDirectory: contextURL, redactions: sensitive + secrets.lines, captureLimit: 1_000_000)
        operation.start(request, title: "Build Image", store: store) { succeeded in
            if succeeded { await store.refresh(.images, force: true) }
        }
    }

    private func builderAction(_ args: [String], title: String) async {
        formError = nil
        operation.start(CommandRequest(arguments: args), title: title, store: store) { _ in
            await refreshBuilderStatus()
        }
    }
    private func refreshBuilderStatus() async {
        builderStatusLoaded = false
        builderStatusError = nil
        do {
            let result = try await store.execute(CommandRequest(arguments: ["builder", "status", "--format", "json"], captureLimit: 200_000, suppressOutputEvents: true), title: "Builder Status")
            guard result.succeeded else { throw FeatureCommandError(result: result) }
            updateBuilderStatus(from: result.standardOutput)
        } catch {
            builderStatus = nil
            builderStatusLoaded = true
            builderStatusError = error.localizedDescription
        }
    }
    private func updateBuilderStatus(from output: String) {
        guard let data = output.data(using: .utf8), let decoded = try? JSONDecoder().decode([BuildKitStatus].self, from: data) else {
            builderStatus = nil
            builderStatusLoaded = true
            builderStatusError = "The builder returned status data that could not be read."
            return
        }
        builderStatus = decoded.first(where: { $0.id == "buildkit" })
        builderStatusLoaded = true
        builderStatusError = nil
    }
    private var builderStateLabel: String {
        if let state = builderStatus?.state { return state.capitalized }
        if builderStatusError != nil { return "Unknown" }
        return builderStatusLoaded ? "Not created" : "Checking…"
    }
    private var builderIsRunning: Bool { (builderStatus?.state ?? "").localizedCaseInsensitiveContains("running") }

}

private struct BuildKitStatus: Decodable {
    struct Configuration: Decodable {
        struct Resources: Decodable {
            let cpus: Int?
            let memoryInBytes: Int64?
        }
        let resources: Resources?
    }
    struct RuntimeStatus: Decodable {
        let state: String?
    }

    let id: String
    let configuration: Configuration?
    let status: RuntimeStatus?

    var state: String? { status?.state }
    var cpus: Int? { configuration?.resources?.cpus }
    var memoryBytes: Int64? { configuration?.resources?.memoryInBytes }
}

private extension String {
    var lines: [String] { split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}
