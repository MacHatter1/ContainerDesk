import AppKit
import SwiftUI
import ContainerDeskCore

private struct RememberedCluster: Identifiable {
    let name: String
    var id: String { name }
}

struct KubernetesFeatureView: View {
    let store: AppStore

    private var rememberedNames: [String] { store.pluginLibrary.clusterNames }
    private var operation: KubernetesOperationStore { store.kubernetesOperations }
    private var busy: Bool { operation.isRunning }
    private var output: String { operation.output }
    private var error: String? { inputError ?? operation.error }
    @State private var inputError: String?
    @State private var owner = UUID()
    @State private var actionTask: Task<Void, Never>?
    @State private var actionID: UUID?
    @State private var showCreate = false
    @State private var showDelete = false
    @State private var showLoadImage = false
    @State private var showWriteConfig = false
    @State private var confirmWriteConfig = false
    @State private var selectedNames = Set<String>()
    @State private var clusterName = "k8s-dev"
    @State private var image = ""
    @State private var nodeImage = "docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"
    @State private var cni = ""
    @State private var cpus = ""
    @State private var memory = ""
    @State private var registryScheme = "https"
    @State private var maxDownloads = "3"
    @State private var platform = ""
    @State private var kubeconfig = "~/.kube/config"
    @State private var removeOnStop = false
    @State private var showCNIImporter = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(title: "Local Kubernetes", subtitle: "Experimental Kubernetes plugin · single-node clusters", symbol: "shippingbox.and.arrow.backward.fill", tint: .cyan) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshList() } }.disabled(busy)
            }
            HStack {
                TextField("Cluster name for actions", text: $clusterName, prompt: Text("k8s-dev"))
                    .frame(maxWidth: 300)
                Text("Choose a remembered name or enter a cluster listed above.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            AccentPanel(title: "Installed plugin output", symbol: "terminal", tint: .cyan) {
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Button("Create Cluster…", systemImage: "plus") { showCreate = true }
                        .buttonStyle(.borderedProminent).disabled(busy)
                    Menu("Cluster Actions") {
                        Button("Load Local Image…", systemImage: "square.and.arrow.down") { showLoadImage = true }
                        Button("Write Kubeconfig…", systemImage: "doc.badge.gearshape") { showWriteConfig = true }
                        Divider()
                        Button("Delete Cluster…", systemImage: "trash", role: .destructive) { showDelete = true }
                    }
                }.disabled(busy)
                Text(output.isEmpty ? "Refresh to list clusters. The 1.5.0 list command returns human-readable text and has no JSON formatter." : output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    .padding(12)
                    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
              }
            }
            .padding(.horizontal, 16)
            ScrollView {
                AccentPanel(title: "Remembered cluster names", symbol: "list.bullet.rectangle", tint: .purple) {
                  VStack(alignment: .leading, spacing: 10) {
                    Text("Names are remembered when created in this app. They are references, not proof that a cluster is still live.")
                        .font(.caption).foregroundStyle(.secondary)
                    if rememberedNames.isEmpty {
                        FeatureEmptyState(title: "No remembered names", message: "Create a cluster in this app or enter a name for an action.", symbol: "list.bullet.rectangle")
                            .frame(height: 130)
                    } else {
                        Table(rememberedNames.map(RememberedCluster.init), selection: $selectedNames) {
                            TableColumn("Cluster name") { cluster in Text(cluster.name).font(.body.weight(.medium)) }
                            TableColumn("Record") { _ in Text("Remembered reference").foregroundStyle(.secondary) }
                        }
                        .frame(minHeight: 120)
                    }
                    HStack {
                        Button("Load Image…") { showLoadImage = true }.disabled(busy || rememberedNames.isEmpty)
                        Button("Write Kubeconfig…") { showWriteConfig = true }.disabled(busy || rememberedNames.isEmpty)
                        Spacer()
                        Button("Delete…", role: .destructive) { showDelete = true }.disabled(busy || rememberedNames.isEmpty)
                    }
                  }
                }
                .padding(.horizontal, 16)
            }
            HStack { Label(busy ? "Working…" : "App quit leaves clusters running", systemImage: busy ? "hourglass" : "power") ; Spacer(); if busy, operation.owner == owner { Button("Cancel", role: .destructive) { cancelOperation() } }; if !output.isEmpty { Button("Clear Output") { operation.clearOutput(); inputError = nil }.disabled(busy) } }
                .font(.caption).foregroundStyle(.secondary).padding(10).background(.bar)
                .animation(ContainerDeskMotion.animation(reduceMotion: reduceMotion), value: busy)
        }
        .navigationTitle("Kubernetes")
        .sheet(isPresented: $showCreate) { createSheet }
        .sheet(isPresented: $showLoadImage) { loadImageSheet }
        .sheet(isPresented: $showWriteConfig) { writeConfigSheet }
        .fileImporter(isPresented: $showCNIImporter, allowedContentTypes: [.yaml, .plainText], allowsMultipleSelection: false) { result in
            switch result { case .success(let urls): if let url = urls.first { cni = url.path }; case .failure(let issue): inputError = issue.localizedDescription }
        }
        .confirmationDialog("Create a local cluster?", isPresented: $showCreateConfirmation, titleVisibility: .visible) {
            Button("Create \(clusterName)") { launch { await createCluster() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The plugin merges credentials into ~/.kube/config when it creates a cluster. This action creates one control-plane node and changes local Kubernetes configuration.") }
        .confirmationDialog("Delete Kubernetes cluster?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete \(clusterName)", role: .destructive) { launch { await deleteCluster() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This stops and removes the cluster container and removes its context from ~/.kube/config.") }
        .task { await refreshList() }
        .onDisappear { actionTask?.cancel(); actionTask = nil; actionID = nil; operation.cancel(owner: owner) }
        .onChange(of: selectedNames) { _, newValue in if let name = newValue.first { clusterName = name } }
    }

    @State private var showCreateConfirmation = false

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section("Cluster") {
                    TextField("Name", text: $clusterName)
                    TextField("Node image", text: $nodeImage)
                    TextField("CPUs", text: $cpus, prompt: Text("Default: 1/4 host CPUs, minimum 2"))
                    TextField("Memory", text: $memory, prompt: Text("Default: 1/4 host memory, minimum 2G"))
                    HStack { TextField("CNI manifest path", text: $cni, prompt: Text("Optional plain Kubernetes YAML")); Button("Choose…") { showCNIImporter = true } }
                    Picker("Registry scheme", selection: $registryScheme) { Text("HTTPS").tag("https"); Text("HTTP").tag("http") }
                    TextField("Max concurrent downloads", text: $maxDownloads, prompt: Text("3"))
                    Toggle("Remove cluster when its container stops (--rm)", isOn: $removeOnStop)
                }
                Section { Text("Create automatically merges kubeconfig into ~/.kube/config. A stopped cluster cannot be restarted with this plugin; delete and recreate it.").font(.caption).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped).navigationTitle("Create Kubernetes Cluster")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCreate = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { showCreate = false; showCreateConfirmation = true }.buttonStyle(.borderedProminent).disabled(busy || clusterName.isEmpty) }
            }
        }.frame(minWidth: 480, minHeight: 360)
    }

    private var loadImageSheet: some View {
        NavigationStack {
            Form {
                Section("Image") {
                    TextField("Cluster name", text: $clusterName, prompt: Text("k8s-dev"))
                    TextField("Local image reference", text: $image, prompt: Text("my-app:latest"))
                    TextField("Platform (optional)", text: $platform, prompt: Text("linux/arm64"))
                }
                Section { Text("The image is imported into the selected cluster’s containerd store in the `k8s.io` namespace.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("Load Local Image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showLoadImage = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Load Image") { launch { await loadImage() } }.buttonStyle(.borderedProminent).disabled(busy || image.isEmpty || clusterName.isEmpty) }
            }
        }.frame(minWidth: 460, minHeight: 280)
    }

    private var writeConfigSheet: some View {
        NavigationStack {
            Form {
                Section("Kubeconfig") {
                    TextField("Cluster name", text: $clusterName, prompt: Text("k8s-dev"))
                    HStack { TextField("Kubeconfig file", text: $kubeconfig, prompt: Text("~/.kube/config")); Button("Choose…") { chooseKubeconfig() } }
                }
                Section { Text("This writes or appends cluster credentials to the selected file. Choose an alternate path to avoid changing your default kubeconfig.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("Write Kubeconfig")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showWriteConfig = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Write…") { confirmWriteConfig = true }.buttonStyle(.borderedProminent).disabled(busy || clusterName.isEmpty || kubeconfig.isEmpty) }
            }
            .confirmationDialog("Write kubeconfig for \(clusterName)?", isPresented: $confirmWriteConfig, titleVisibility: .visible) {
                Button("Write Configuration") { launch { await writeConfig() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The selected file may be created or appended to: \((kubeconfig as NSString).expandingTildeInPath)")
            }
        }.frame(minWidth: 460, minHeight: 280)
    }

    private func refreshList() async {
        _ = await execute(["k8s", "list"], title: "List Kubernetes Clusters")
    }
    private func createCluster() async {
        let name = clusterName
        var args = ["k8s", "create", "--name", name, "--node-image", nodeImage]
        if !cpus.isEmpty { args += ["--cpus", cpus] }; if !memory.isEmpty { args += ["--memory", memory] }
        if !registryScheme.isEmpty { args += ["--scheme", registryScheme] }
        if !maxDownloads.isEmpty { args += ["--max-concurrent-downloads", maxDownloads] }
        if !cni.isEmpty { args += ["--cni", cni] }; if removeOnStop { args.append("--rm") }
        guard await execute(args, title: "Create Kubernetes Cluster") else { return }
        store.pluginLibrary.rememberCluster(name); showCreate = false; await refreshList()
    }
    private func deleteCluster() async {
        let name = clusterName
        guard !name.isEmpty else { return }
        guard await execute(["k8s", "delete", "--name", name], title: "Delete Kubernetes Cluster") else { return }
        store.pluginLibrary.forgetCluster(name); selectedNames.remove(name); await refreshList()
    }
    private func loadImage() async {
        var args = ["k8s", "load-image", "--name", clusterName, image]
        if !platform.isEmpty { args += ["--platform", platform] }
        if await execute(args, title: "Load Image into Kubernetes") { showLoadImage = false }
    }
    private func writeConfig() async {
        if await execute(["k8s", "write-config", "--name", clusterName, "--kubeconfig", (kubeconfig as NSString).expandingTildeInPath], title: "Write Kubernetes Config") { showWriteConfig = false }
    }
    @discardableResult private func execute(_ arguments: [String], title: String) async -> Bool {
        inputError = nil
        return await operation.run(CommandRequest(arguments: arguments, captureLimit: 500_000), title: title, store: store, owner: owner)
    }
    private func launch(_ action: @escaping () async -> Void) {
        guard !busy, actionTask == nil else { return }
        let id = UUID()
        actionID = id
        actionTask = Task {
            guard !Task.isCancelled else { return }
            await action()
            if actionID == id { actionTask = nil; actionID = nil }
        }
    }
    private func cancelOperation() { operation.cancel(owner: owner) }
    private func chooseKubeconfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "config"
        if panel.runModal() == .OK, let url = panel.url { kubeconfig = url.path }
    }
}
