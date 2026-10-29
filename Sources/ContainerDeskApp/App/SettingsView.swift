import ContainerDeskCore
import SwiftUI
import AppKit

struct SettingsView: View {
    let store: AppStore
    let mlxStore: MLXStore
    @State private var cliPathDraft = ""
    @State private var mlxPathDraft = ""
    @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Choose System to follow macOS appearance, or set ContainerDesk to Light or Dark.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Appearance", systemImage: "paintpalette.fill").foregroundStyle(.purple) }
            Section {
                HStack {
                    TextField("Automatic discovery", text: $cliPathDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseCLI)
                }
                HStack {
                    Text("Detected").foregroundStyle(.secondary)
                    Text(ExecutableResolver(overridePath: cliPathDraft.isEmpty ? nil : cliPathDraft).resolve()?.path ?? "Not found")
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Text("The app looks in Homebrew’s Apple Silicon and Intel locations, then your inherited PATH.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save Path") { store.cliPath = cliPathDraft.isEmpty ? nil : cliPathDraft }
                    Button("Use Automatic Discovery") { cliPathDraft = ""; store.cliPath = nil }
                }
            } header: { Label("Container CLI", systemImage: "shippingbox.fill").foregroundStyle(.blue) }
            Section {
                HStack {
                    TextField("Automatic discovery", text: $mlxPathDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseMLXExecutable)
                }
                LabeledContent("Detected", value: mlxStore.capability.executableURL?.path ?? "Not found")
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Status", value: mlxStore.capability.available ? (mlxStore.capability.mlxLMVersion ?? "Ready") : "Unavailable")
                if let reason = mlxStore.capability.reason, !mlxStore.capability.available {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save MLX Path") { Task { await mlxStore.updateExecutableOverride(mlxPathDraft) } }
                    Button("Use Automatic Discovery") { mlxPathDraft = ""; Task { await mlxStore.updateExecutableOverride(nil) } }
                    Button("Check Again", systemImage: "arrow.clockwise") { Task { await mlxStore.configureAndRefresh() } }
                }
                LabeledContent("Managed downloads", value: mlxStore.configuration.managedModelsDirectory.path)
                    .font(.system(.caption, design: .monospaced))
                Button("Choose Managed Models Folder…", action: chooseManagedModelsDirectory)
                Text("ContainerDesk can discover local MLX models and run a loopback-only inference server. Downloads start only when you request them. Model files, chat transcripts, prompts, and server output are not saved in preferences or Activity.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("MLX-LM setup guide", destination: URL(string: "https://github.com/ml-explore/mlx-lm")!)
            } header: { Label("MLX Local Models", systemImage: "cpu.fill").foregroundStyle(.teal) }
            Section {
                LabeledContent("Container reads", value: containerReadDescription)
                LabeledContent("Native list reads", value: "Containers, networks and volumes when available")
                LabeledContent("CLI list reads", value: "Images, registries and machines · about every 3 seconds")
                Text("Native reads are used for supported resources, with CLI fallback if a read fails. Selecting the CLI path disables native reads. Changes, builds, plugins and terminals continue through the CLI.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The app never starts or stops the runtime automatically. Registry credentials remain managed by the container CLI.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Runtime behavior", systemImage: "waveform.path").foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560, height: 700)
        .navigationTitle("Settings")
        .onAppear {
            cliPathDraft = store.cliPath ?? ""
            mlxPathDraft = mlxStore.configuration.executableOverride?.path ?? ""
        }
    }

    private var containerReadDescription: String {
        switch store.containerMetricsBackend ?? store.resourceReadBackends[.containers] {
        case .some(.nativeAPI): "Native API · about every second; CPU after second sample"
        case .some(.cli):
            if store.cliPath != nil { "CLI override · about every 3 seconds; CPU after second sample" }
            else if store.containerMetricsFallbackReason != nil { "CLI fallback · about every 3 seconds; CPU after second sample" }
            else { "CLI · about every 3 seconds; CPU after second sample" }
        case nil: store.cliPath == nil ? "Checking native API availability" : "CLI override · about every 3 seconds"
        }
    }

    @MainActor private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose CLI"
        if panel.runModal() == .OK, let url = panel.url { cliPathDraft = url.path }
    }

    @MainActor private func chooseMLXExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose MLX-LM"
        panel.message = "Choose the mlx_lm executable or its mlx_lm.server entry point."
        if panel.runModal() == .OK, let url = panel.url { mlxPathDraft = url.path }
    }

    @MainActor private func chooseManagedModelsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { Task { await mlxStore.updateManagedModelsDirectory(url) } }
    }
}
