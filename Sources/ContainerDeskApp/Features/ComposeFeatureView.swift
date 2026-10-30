import SwiftUI
import UniformTypeIdentifiers
import ContainerDeskCore

struct ComposeFeatureView: View {
    let store: AppStore

    @State private var selectedID: String?
    private var projects: [SavedComposeProject] { store.pluginLibrary.projects }
    @State private var projectName = ""
    @State private var showingImporter = false
    @State private var selectedFile: URL?
    @State private var busy = false
    @State private var output = ""
    @State private var error: String?
    @State private var showDownConfirmation = false
    @State private var keepNetworks = false
    @State private var keepOrphans = false
    @State private var forceRecreate = false
    @State private var pullPolicy = "missing"
    @State private var commandTask: Task<Void, Never>?
    @State private var operationID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedProject: SavedComposeProject? { projects.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(title: "Compose Projects", subtitle: "Bundled plugin · up and down only · project files and names are remembered on this Mac", symbol: "square.stack.3d.up.fill", tint: .indigo) {
                Button("Add File…", systemImage: "plus") { showingImporter = true }
            }

            if projects.isEmpty {
                VStack(spacing: 12) {
                    FeatureEmptyState(title: "No Compose files", message: "Choose a compose.yaml file to save its path and project name for future up/down actions.", symbol: "square.stack.3d.up")
                    Button("Choose Compose File…", systemImage: "plus") { showingImporter = true }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(projects) { project in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name.isEmpty ? project.fileURL.deletingPathExtension().lastPathComponent : project.name)
                                    .font(.body.weight(.medium)).lineLimit(1)
                                Text(project.fileURL.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .tag(project.id)
                            .contextMenu { Button("Forget Project", role: .destructive) { forget(project) } }
                        }
                    }
                    .listStyle(.sidebar)
                    // Keep the project navigator compact; allowing the List to grow
                    // with the split container crowds the action controls below.
                    .frame(width: 270)
                    Divider()
                    detailPanel
                }
            }
            if !output.isEmpty || error != nil { outputPanel.transition(.opacity.combined(with: .move(edge: .bottom))) }
            footer
        }
        .navigationTitle("Compose")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.yaml, .plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { selectedFile = url; projectName = ""; add(url) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .confirmationDialog("Stop and remove this project's containers?", isPresented: $showDownConfirmation, titleVisibility: .visible) {
            Button("Compose Down", role: .destructive) { launch { await runDown(dryRun: false) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Compose down removes project containers and, by default, networks created by this project.") }
        .onAppear { if selectedID == nil { selectedID = projects.first?.id } }
        .onChange(of: selectedID) { _, newID in
            if let project = projects.first(where: { $0.id == newID }) { projectName = project.name }
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let project = selectedProject {
                AccentPanel(title: "Project settings", symbol: "slider.horizontal.3", tint: .indigo) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.fileURL.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                TextField("Project name (optional)", text: $projectName, prompt: Text("Uses file name or directory by default"))
                    .onSubmit { updateSelectedName() }
                HStack {
                    Button("Save Name") { updateSelectedName() }.disabled(project.name == projectName)
                    Spacer()
                    Menu("Up Options") {
                        Toggle("Force recreate every service", isOn: $forceRecreate)
                        Toggle("Keep orphan services", isOn: $keepOrphans)
                        Picker("Pull images", selection: $pullPolicy) {
                            Text("Missing only").tag("missing")
                            Text("Always").tag("always")
                            Text("Never").tag("never")
                        }
                    }
                    Menu("Down Options") { Toggle("Keep project networks", isOn: $keepNetworks) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button("Plan Up", systemImage: "checklist") { launch { await runUp(dryRun: true) } }
                            .disabled(busy)
                        Button("Compose Up", systemImage: "play.fill") { launch { await runUp(dryRun: false) } }
                            .buttonStyle(.borderedProminent).disabled(busy)
                        Spacer(minLength: 8)
                        Button("Plan Down", systemImage: "list.bullet.rectangle") { launch { await runDown(dryRun: true) } }
                            .disabled(busy)
                        Button("Compose Down…", systemImage: "stop.fill", role: .destructive) { showDownConfirmation = true }
                            .disabled(busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button("Plan Up", systemImage: "checklist") { launch { await runUp(dryRun: true) } }
                                .disabled(busy)
                            Button("Compose Up", systemImage: "play.fill") { launch { await runUp(dryRun: false) } }
                                .buttonStyle(.borderedProminent).disabled(busy)
                        }
                        HStack(spacing: 10) {
                            Button("Plan Down", systemImage: "list.bullet.rectangle") { launch { await runDown(dryRun: true) } }
                                .disabled(busy)
                            Button("Compose Down…", systemImage: "stop.fill", role: .destructive) { showDownConfirmation = true }
                                .disabled(busy)
                        }
                    }
                }
                Label("Working directory is set to the Compose file’s parent so relative build contexts and paths resolve from that file.", systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("This plugin supports only `up` and `down`. It does not provide service listing, logs, restart, or a JSON output mode.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                }
            } else {
                FeatureEmptyState(title: "Select a project", message: "Choose a saved Compose file to plan or run its lifecycle actions.", symbol: "square.stack.3d.up")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(error == nil ? "Temporary output" : "Command failed").font(.headline); Spacer(); if busy { ProgressView().controlSize(.small) } }
            Text(error ?? output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                .padding(10).background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .animation(ContainerDeskMotion.animation(reduceMotion: reduceMotion), value: busy)
    }

    private var footer: some View {
        HStack { Label(busy ? "Running Compose…" : "Plugin output is temporary", systemImage: busy ? "hourglass" : "clock.arrow.circlepath"); Spacer(); if busy { Button("Cancel", role: .destructive) { cancelOperation() } }; Button("Forget Selected", role: .destructive) { if let selectedProject { forget(selectedProject) } }.disabled(selectedProject == nil || busy) }
            .font(.caption).foregroundStyle(.secondary).padding(10).background(.bar)
    }

    private func add(_ url: URL) {
        selectedID = store.pluginLibrary.addProject(url, name: projectName).id
    }
    private func updateSelectedName() {
        guard let id = selectedID else { return }
        store.pluginLibrary.renameProject(id: id, name: projectName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func forget(_ project: SavedComposeProject) {
        store.pluginLibrary.forgetProject(id: project.id)
        if selectedID == project.id { selectedID = projects.first?.id }
    }
    private func runUp(dryRun: Bool) async {
        guard let project = selectedProject else { return }
        updateSelectedName()
        var args = ["compose", "up", "--file", project.fileURL.path]
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { args += ["--project-name", name] }
        args += ["--pull", pullPolicy]
        if forceRecreate { args.append("--force-recreate") }
        if keepOrphans { args.append("--keep-orphans") }
        if dryRun { args.append("--dry-run") }
        await execute(args, title: dryRun ? "Plan Compose Up" : "Compose Up", file: project.fileURL)
    }
    private func runDown(dryRun: Bool) async {
        guard let project = selectedProject else { return }
        var args = ["compose", "down", "--file", project.fileURL.path]
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { args += ["--project-name", name] }
        if dryRun { args.append("--dry-run") }
        if keepNetworks { args.append("--keep-networks") }
        await execute(args, title: dryRun ? "Plan Compose Down" : "Compose Down", file: project.fileURL)
    }
    private func execute(_ args: [String], title: String, file: URL) async {
        busy = true; error = nil; output = ""
        let hasScope = file.startAccessingSecurityScopedResource()
        defer { if hasScope { file.stopAccessingSecurityScopedResource() } }
        do {
            let stream = store.stream(CommandRequest(arguments: args, workingDirectory: file.deletingLastPathComponent(), captureLimit: 1_000_000), title: title)
            operationID = store.operations.first?.id
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .standardOutput(let chunk): append(chunk)
                case .standardError(let chunk): append(chunk)
                case .completed(let result): if !result.succeeded { throw FeatureCommandError(result: result) }
                }
            }
            await store.refresh(.containers, force: true); await store.refresh(.networks, force: true)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        operationID = nil
        busy = false
    }

    private func launch(_ action: @escaping () async -> Void) { commandTask = Task { await action() } }
    private func cancelOperation() {
        if let operationID { store.cancelOperation(operationID) }
        commandTask?.cancel()
        commandTask = nil
    }
    private func append(_ text: String) { BoundedText.append(text, to: &output) }
}
