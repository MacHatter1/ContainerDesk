import SwiftUI
import ContainerDeskCore

/// Advanced CLI flags are represented as typed controls rather than shell text. The tokenizer
/// is intentionally not exposed here; every invocation remains an argv array.
struct AdvancedCommandSheet: View {
    let section: ContainerSection
    let store: AppStore
    let onNotice: (FeatureNotice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var commandID = ""
    @State private var positionals: [String] = []
    @State private var values: [String: String] = [:]
    @State private var flags: Set<String> = []
    @State private var showingConfirmation = false
    @State private var running = false
    @State private var output = ""
    @State private var error: String?
    @State private var operationID: UUID?
    @State private var runningTask: Task<Void, Never>?

    private var specs: [AdvancedCommandSpec] { AdvancedCommandCatalog.specs(for: section) }
    private var spec: AdvancedCommandSpec? { specs.first { $0.id == commandID } ?? specs.first }
    private var destructive: Bool { spec?.destructive ?? false }
    private var confirmationTitle: String {
        guard let spec else { return "Run this command?" }
        if flags.contains("all") {
            switch spec.id {
            case "stop": return "Stop all running containers?"
            case "delete" where section == .images: return "Delete all local images?"
            case "delete" where section == .containers: return "Delete all containers?"
            case "delete" where section == .volumes: return "Delete all unused volumes?"
            case "delete" where section == .networks: return "Delete all user-defined networks?"
            case "kill": return "Signal every running container?"
            default: break
            }
        }
        let targets = confirmationTargets
        return targets.isEmpty ? "\(spec.title)?" : "\(spec.title): \(targets)?"
    }
    private var confirmationMessage: String {
        let targets = confirmationTargets
        if !targets.isEmpty { return "This command targets: \(targets)" }
        return flags.contains("all") ? "The command will apply to the full scope named above." : "Review the selected action and scope before continuing."
    }
    private var confirmationTargets: String {
        positionals
            .flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(AdvancedCommandScopeValidation.confirmationLabel)
            .joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Command") {
                    Picker("Operation", selection: $commandID) {
                        ForEach(specs) { Text($0.title).tag($0.id) }
                    }
                    if let spec {
                        Text(spec.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let spec, !spec.positionals.isEmpty {
                    Section("Arguments") {
                        ForEach(Array(spec.positionals.enumerated()), id: \.offset) { index, positional in
                            if positional.multiline {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(positional.name).font(.subheadline.weight(.medium))
                                    TextEditor(text: binding(for: index))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 52, maxHeight: 120)
                                        .overlay(alignment: .topLeading) {
                                            if !positionals.indices.contains(index) || positionals[index].isEmpty {
                                                Text(positional.placeholder)
                                                    .foregroundStyle(.tertiary)
                                                    .padding(.top, 7)
                                                    .padding(.leading, 5)
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                }
                            } else {
                                TextField(positional.name, text: binding(for: index), prompt: Text(positional.placeholder))
                            }
                        }
                    }
                }
                if let spec, !spec.flags.isEmpty {
                    Section("Advanced flags") {
                        ForEach(spec.flags) { descriptor in
                            if descriptor.kind == .boolean {
                                Toggle(descriptor.label, isOn: flagBinding(descriptor.name))
                            } else {
                                TextField(descriptor.label, text: valueBinding(descriptor.name), prompt: Text(descriptor.placeholder ?? (descriptor.repeats ? "One value per line" : "Optional")))
                                    .font(descriptor.multiline ? .system(.body, design: .monospaced) : .body)
                                    .if(descriptor.multiline) { $0.lineLimit(2...5) }
                                if descriptor.name == "memory", ["run", "create"].contains(commandID), !values["memory", default: ""].isEmpty, let amount = Self.memoryMiB(values["memory", default: ""]), amount < 200 {
                                    Label("Container memory must be at least 200 MiB.", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                if !output.isEmpty {
                    Section("Temporary command output") {
                        TextEditor(text: .constant(output)).font(.system(.caption, design: .monospaced)).frame(minHeight: 120).textSelection(.enabled)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                Section {
                    Label("Arguments are passed directly to the CLI. Shell expansion and scripts are not evaluated.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Advanced Command")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    HStack {
                        Button(running ? "Running…" : "Run") { if destructive { showingConfirmation = true } else { launch() } }
                        if running { Button("Cancel", role: .destructive) { cancelOperation() } }
                    }
                        .buttonStyle(.borderedProminent).disabled(running || !valid)
                }
            }
            .confirmationDialog(confirmationTitle, isPresented: $showingConfirmation, titleVisibility: .visible) {
                Button("Run \(spec?.title ?? "Command")", role: .destructive) { launch() }
                Button("Cancel", role: .cancel) { }
            } message: { Text(confirmationMessage) }
            .onChange(of: commandID) { _, newValue in reset(for: newValue) }
        }
        .frame(minWidth: 500, minHeight: 460)
        .onAppear { commandID = specs.first?.id ?? "" }
        .onDisappear { cancelOperation() }
    }

    private var valid: Bool {
        guard let spec else { return false }
        let positionalsValid = spec.positionals.enumerated().allSatisfy { index, item in !item.required || (positionals.indices.contains(index) && !positionals[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        let requiredFlagsValid = spec.flags.filter { $0.required }.allSatisfy { !values[$0.name, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let memory = values["memory", default: ""]
        let memoryValid = !["run", "create"].contains(spec.id) || memory.isEmpty || (Self.memoryMiB(memory).map { $0 >= 200 } ?? false)
        let scopeValid = AdvancedCommandScopeValidation.isValid(section: section, commandID: spec.id, positionals: positionals, flags: flags)
        return positionalsValid && requiredFlagsValid && memoryValid && scopeValid
    }
    private func binding(for index: Int) -> Binding<String> {
        Binding(get: { positionals.indices.contains(index) ? positionals[index] : "" }, set: { value in
            while positionals.count <= index { positionals.append("") }
            positionals[index] = value
        })
    }
    private func valueBinding(_ name: String) -> Binding<String> {
        Binding(get: { values[name, default: ""] }, set: { values[name] = $0 })
    }
    private func flagBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { flags.contains(name) }, set: { value in if value { flags.insert(name) } else { flags.remove(name) } })
    }
    private func reset(for id: String) { positionals = []; values = [:]; flags = []; output = ""; error = nil }

    private func launch() { runningTask = Task { await run() } }
    private func cancelOperation() {
        if let operationID { store.cancelOperation(operationID) }
        runningTask?.cancel()
        runningTask = nil
    }

    private func run() async {
        guard let spec else { return }
        running = true
        error = nil
        do {
            let redactOutput = spec.id == "inspect"
            var inspectOutput = ""
            var inspectOutputBytes = 0
            var inspectOutputTruncated = false
            let inspectOutputLimit = 1_000_000
            var sensitiveValues: [String] = []
            let flagArguments = spec.flags.flatMap { descriptor -> [String] in
                if descriptor.kind == .boolean { return flags.contains(descriptor.name) ? ["--\(descriptor.name)"] : [] }
                let raw = values[descriptor.name, default: ""]
                guard !raw.isEmpty else { return [] }
                let vals = descriptor.repeats ? raw.split(whereSeparator: \.isNewline).map(String.init) : [raw]
                if descriptor.sensitive { sensitiveValues += vals.map { entry in entry.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? entry } }
                let name = descriptor.shortName ?? "--\(descriptor.name)"
                return vals.flatMap { [name, $0] }
            }
            let positionalArguments = try positionalValues(for: spec)
            let positionalTerminator = AdvancedCommandScopeValidation.positionalTerminator(
                section: section,
                commandID: spec.id,
                positionals: positionalArguments
            )
            let args = spec.arguments + flagArguments + positionalTerminator + positionalArguments
            let request = CommandRequest(arguments: args, redactions: sensitiveValues)
            let stream = store.stream(request, title: spec.title)
            operationID = store.operations.first?.id
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .standardOutput(let chunk):
                    if redactOutput {
                        if inspectOutputBytes + chunk.utf8.count <= inspectOutputLimit {
                            inspectOutput += chunk
                            inspectOutputBytes += chunk.utf8.count
                        } else { inspectOutputTruncated = true }
                    } else { append(chunk) }
                case .standardError(let chunk):
                    if redactOutput {
                        if inspectOutputBytes + chunk.utf8.count <= inspectOutputLimit {
                            inspectOutput += chunk
                            inspectOutputBytes += chunk.utf8.count
                        } else { inspectOutputTruncated = true }
                    } else { append(chunk) }
                case .completed(let result):
                    if !result.succeeded {
                        if redactOutput { throw FeatureCommandError(message: "Inspect failed with exit code \(result.exitCode); raw error output was hidden.") }
                        throw FeatureCommandError(result: result)
                    }
                    if redactOutput {
                        output = inspectOutputTruncated
                            ? "Inspect output exceeded 1 MB. It was hidden because a complete document is required for safe redaction."
                            : InspectRedactor.redact(inspectOutput)
                    }
                }
            }
            if spec.refreshSection { await store.refresh(section, force: true) }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        operationID = nil
        running = false
    }
    private func append(_ text: String) { output += text; if output.count > 150_000 { output = String(output.suffix(150_000)) } }

    private static func memoryMiB(_ value: String) -> Double? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !input.isEmpty else { return nil }
        let suffix = input.last
        let number = (suffix.map { "KMGTP".contains($0) } ?? false) ? String(input.dropLast()) : input
        guard let amount = Double(number), amount >= 0 else { return nil }
        switch suffix {
        case "K": return amount / 1_024
        case "M": return amount
        case "G": return amount * 1_024
        case "T": return amount * 1_048_576
        case "P": return amount * 1_073_741_824
        default: return amount / 1_048_576
        }
    }

    private func positionalValues(for spec: AdvancedCommandSpec) throws -> [String] {
        var result: [String] = []
        for (index, descriptor) in spec.positionals.enumerated() where positionals.indices.contains(index) {
            let value = positionals[index]
            if descriptor.repeats {
                result.append(contentsOf: value.split(whereSeparator: \.isNewline).map(String.init))
            } else if descriptor.tokenized {
                result.append(contentsOf: try SafeArgumentTokenizer.tokenize(value))
            } else if !value.isEmpty {
                result.append(value)
            }
        }
        return result
    }
}

enum AdvancedCommandScopeValidation {
    static func confirmationLabel(_ target: String) -> String {
        target.hasPrefix("-") ? "“\(target)”" : target
    }

    static func isValid(section: ContainerSection, commandID: String, positionals: [String], flags: Set<String>) -> Bool {
        guard requiresTargetOrAll(section: section, commandID: commandID) else { return true }
        let hasTarget = positionals.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return flags.contains("all") ? !hasTarget : hasTarget
    }

    static func positionalTerminator(section: ContainerSection, commandID: String, positionals: [String]) -> [String] {
        guard requiresTargetOrAll(section: section, commandID: commandID),
              positionals.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return [] }
        // Apple Container uses Swift ArgumentParser, which treats values after `--` as positionals.
        return ["--"]
    }

    private static func requiresTargetOrAll(section: ContainerSection, commandID: String) -> Bool {
        switch (section, commandID) {
        case (.containers, "stop"), (.containers, "kill"), (.containers, "delete"),
             (.images, "delete"), (.volumes, "delete"), (.networks, "delete"):
            true
        default:
            false
        }
    }
}

private struct AdvancedCommandSpec: Identifiable {
    struct Positional { let name: String; let placeholder: String; let required: Bool; var repeats = false; var multiline = false; var tokenized = false }
    struct Flag: Identifiable {
        enum Kind { case boolean, value }
        let name: String
        let label: String
        let kind: Kind
        var placeholder: String?
        var repeats = false
        var multiline = false
        var sensitive = false
        var required = false
        var shortName: String?
        var id: String { name }
        static func bool(_ name: String, _ label: String) -> Self { .init(name: name, label: label, kind: .boolean) }
        static func value(_ name: String, _ label: String, _ placeholder: String? = nil, repeats: Bool = false, multiline: Bool = false, sensitive: Bool = false, required: Bool = false, shortName: String? = nil) -> Self { .init(name: name, label: label, kind: .value, placeholder: placeholder, repeats: repeats, multiline: multiline, sensitive: sensitive, required: required, shortName: shortName) }
    }
    let id: String
    let title: String
    let summary: String
    let arguments: [String]
    var positionals: [Positional] = []
    var flags: [Flag] = []
    var destructive = false
    var refreshSection = true
}

private enum AdvancedCommandCatalog {
    typealias Flag = AdvancedCommandSpec.Flag
    typealias Positional = AdvancedCommandSpec.Positional
    static func specs(for section: ContainerSection) -> [AdvancedCommandSpec] {
        switch section {
        case .stacks: []
        case .containers: containers
        case .images: images
        case .builds: builds
        case .volumes: volumes
        case .networks: networks
        case .registries: registries
        case .machines: machines
        case .compose: []
        case .kubernetes: []
        case .system: system
        case .activity: []
        case .mlxModels: []
        case .cleanup: []
        }
    }

    private static let containers: [AdvancedCommandSpec] = [
        .init(id: "run", title: "Run", summary: "Start an image with process, resource, security, networking and mount controls.", arguments: ["run"], positionals: [.init(name: "Image", placeholder: "nginx:latest", required: true), .init(name: "Command and arguments", placeholder: "Optional; quoted command arguments are tokenized without shell expansion", required: false, tokenized: true)], flags: [
            .bool("detach", "Run in background"), .bool("interactive", "Keep stdin open"), .bool("tty", "Allocate TTY"), .value("name", "Name"), .value("cidfile", "Write the container ID to a file"), .value("env", "Environment variables", "KEY=value, one per line", repeats: true, multiline: true, sensitive: true), .value("env-file", "Environment files", "One path per line", repeats: true, multiline: true), .value("cpus", "CPU limit"), .value("memory", "Memory limit"), .value("platform", "Platform"), .value("arch", "Architecture"), .value("os", "Operating system"), .value("entrypoint", "Entrypoint"), .value("workdir", "Working directory"), .value("user", "User"), .value("uid", "UID"), .value("gid", "GID"), .value("ulimit", "Ulimits", "type=soft:hard", repeats: true), .value("publish", "Published ports", "HOST:CONTAINER, one per line", repeats: true, multiline: true), .value("publish-socket", "Published sockets", "HOST:CONTAINER, one per line", repeats: true), .value("volume", "Volumes", "SOURCE:DESTINATION[:ro], one per line", repeats: true, multiline: true), .value("mount", "Mount specs", "type=...,source=...,target=...", repeats: true, multiline: true), .value("network", "Networks", "One network per line", repeats: true, multiline: true), .value("dns", "DNS servers", "One IP per line", repeats: true), .value("dns-domain", "DNS domain"), .value("dns-search", "DNS search domains", repeats: true), .value("dns-option", "DNS options", repeats: true), .value("label", "Labels", "key=value per line", repeats: true, multiline: true), .value("tmpfs", "Tmpfs mounts", repeats: true), .value("cap-add", "Capabilities to add", repeats: true), .value("cap-drop", "Capabilities to drop", repeats: true), .value("kernel", "Custom kernel path"), .value("kernel-arg", "Kernel arguments", repeats: true), .value("runtime", "Runtime handler"), .value("init-image", "Init image"), .value("shm-size", "/dev/shm size"), .value("scheme", "Registry scheme", "http or https"), .value("progress", "Progress format", "auto, none, ansi, plain, color"), .bool("init", "Run init process"), .bool("rm", "Remove after exit"), .bool("rosetta", "Enable Rosetta"), .bool("read-only", "Read-only root filesystem"), .bool("ssh", "Forward SSH agent"), .bool("virtualization", "Expose virtualization"), .bool("no-dns", "Disable DNS setup"), .value("masked-path", "Masked paths", repeats: true), .value("read-only-path", "Read-only paths", repeats: true), .value("max-concurrent-downloads", "Max concurrent image downloads")
        ]),
        .init(id: "create", title: "Create Container", summary: "Create without starting; accepts the run process, resource, network and filesystem options.", arguments: ["create"], positionals: [.init(name: "Image", placeholder: "alpine:latest", required: true), .init(name: "Command and arguments", placeholder: "Optional", required: false, tokenized: true)], flags: [
            .bool("detach", "Do not attach process"), .bool("interactive", "Keep stdin open"), .bool("tty", "Allocate TTY"), .value("name", "Name"), .value("cidfile", "Write the container ID to a file"), .value("env", "Environment variables", "KEY=value per line", repeats: true, multiline: true, sensitive: true), .value("env-file", "Environment files", "One path per line", repeats: true, multiline: true), .value("cpus", "CPU limit"), .value("memory", "Memory limit"), .value("platform", "Platform"), .value("arch", "Architecture"), .value("os", "Operating system"), .value("entrypoint", "Entrypoint"), .value("workdir", "Working directory"), .value("user", "User"), .value("uid", "UID"), .value("gid", "GID"), .value("ulimit", "Ulimits", "type=soft:hard", repeats: true), .value("publish", "Published ports", "HOST:CONTAINER per line", repeats: true, multiline: true), .value("publish-socket", "Published sockets", repeats: true, multiline: true), .value("volume", "Volumes", "SOURCE:DESTINATION per line", repeats: true, multiline: true), .value("mount", "Mount specs", "type=...,source=...,target=...", repeats: true, multiline: true), .value("network", "Networks", "One per line", repeats: true, multiline: true), .value("dns", "DNS servers", repeats: true), .value("dns-domain", "DNS domain"), .value("dns-search", "DNS search domains", repeats: true), .value("dns-option", "DNS options", repeats: true), .value("label", "Labels", "KEY=value per line", repeats: true, multiline: true), .value("tmpfs", "Tmpfs mounts", repeats: true), .value("cap-add", "Capabilities to add", repeats: true), .value("cap-drop", "Capabilities to drop", repeats: true), .value("kernel", "Custom kernel path"), .value("kernel-arg", "Kernel arguments", repeats: true), .value("runtime", "Runtime handler"), .value("init-image", "Init image"), .value("shm-size", "/dev/shm size"), .bool("init", "Run init process"), .bool("rm", "Remove after exit"), .bool("rosetta", "Enable Rosetta"), .bool("read-only", "Read-only root filesystem"), .bool("ssh", "Forward SSH agent"), .bool("virtualization", "Expose virtualization"), .bool("no-dns", "Disable DNS setup"), .value("masked-path", "Masked paths", repeats: true), .value("read-only-path", "Read-only paths", repeats: true), .value("scheme", "Registry scheme"), .value("max-concurrent-downloads", "Max concurrent image downloads")
        ]),
        .init(id: "list", title: "List Containers", summary: "List running containers or include stopped containers; the workspace refresh uses curated JSON summaries.", arguments: ["list"], flags: [.bool("all", "Include stopped containers"), .value("format", "Output format", "json, table, yaml, or toml"), .bool("quiet", "Only container IDs")], refreshSection: false),
        .init(id: "start", title: "Start", summary: "Start a stopped container and optionally attach to its output.", arguments: ["start"], positionals: [.init(name: "Container ID", placeholder: "container-id", required: true)], flags: [.bool("attach", "Attach output"), .bool("interactive", "Attach stdin")]),
        .init(id: "stop", title: "Stop", summary: "Gracefully stop selected containers.", arguments: ["stop"], positionals: [.init(name: "Container IDs", placeholder: "One ID per line", required: false, repeats: true, multiline: true)], flags: [.bool("all", "Stop all running containers"), .value("signal", "Signal", "SIGTERM"), .value("time", "Timeout seconds")], destructive: true),
        .init(id: "kill", title: "Kill", summary: "Immediately signal selected containers.", arguments: ["kill"], positionals: [.init(name: "Container IDs", placeholder: "One ID per line", required: false, repeats: true, multiline: true)], flags: [.bool("all", "Signal all running containers"), .value("signal", "Signal", "KILL")], destructive: true),
        .init(id: "delete", title: "Delete", summary: "Remove containers. Force may remove running containers.", arguments: ["delete"], positionals: [.init(name: "Container IDs", placeholder: "One ID per line", required: false, repeats: true, multiline: true)], flags: [.bool("all", "Delete all containers"), .bool("force", "Force removal")], destructive: true),
        .init(id: "logs", title: "Logs", summary: "Fetch container logs or boot output.", arguments: ["logs"], positionals: [.init(name: "Container ID", placeholder: "container-id", required: true)], flags: [.bool("follow", "Follow output"), .value("n", "Trailing line count", shortName: "-n"), .bool("boot", "Show boot logs")], refreshSection: false),
        .init(id: "stats", title: "Stats", summary: "Display resource statistics for running containers.", arguments: ["stats"], positionals: [.init(name: "Container IDs", placeholder: "Optional; one per line", required: false, repeats: true, multiline: true)], flags: [.bool("no-stream", "Single snapshot"), .value("format", "Output format", "json, table, yaml, or toml")], refreshSection: false),
        .init(id: "exec", title: "Exec", summary: "Run a process inside a running container.", arguments: ["exec"], positionals: [.init(name: "Container ID", placeholder: "container-id", required: true), .init(name: "Command and arguments", placeholder: "/bin/sh or a quoted command line", required: true, tokenized: true)], flags: [.bool("interactive", "Keep stdin open"), .bool("tty", "Allocate TTY"), .bool("detach", "Detach process"), .value("env", "Environment variables", "One per line", repeats: true, multiline: true, sensitive: true), .value("env-file", "Environment files", "One per line", repeats: true, multiline: true), .value("workdir", "Working directory"), .value("user", "User"), .value("uid", "UID"), .value("gid", "GID"), .value("ulimit", "Ulimits", "type=soft:hard", repeats: true)], refreshSection: false),
        .init(id: "inspect", title: "Inspect", summary: "Display resource JSON; environment values are redacted by default in the detail view.", arguments: ["inspect"], positionals: [.init(name: "Container IDs", placeholder: "One ID per line", required: true, repeats: true, multiline: true)], refreshSection: false),
        .init(id: "copy", title: "Copy", summary: "Copy between a local path and a running container path.", arguments: ["copy"], positionals: [.init(name: "Source", placeholder: "./file or container:/path", required: true), .init(name: "Destination", placeholder: "./folder or container:/path", required: true)], refreshSection: false),
        .init(id: "export", title: "Export", summary: "Export a container filesystem as a tar archive.", arguments: ["export"], positionals: [.init(name: "Container ID", placeholder: "container-id", required: true)], flags: [.value("output", "Destination file", "~/Downloads/container.tar", required: true)], refreshSection: false),
        .init(id: "clean", title: "Clean", summary: "Clean unused space in a running container filesystem and named volumes.", arguments: ["clean"], positionals: [.init(name: "Container IDs", placeholder: "One ID per line", required: true, repeats: true, multiline: true)], destructive: true),
    ]

    private static let images: [AdvancedCommandSpec] = [
        .init(id: "pull", title: "Pull", summary: "Pull an OCI image from a registry.", arguments: ["image", "pull"], positionals: [.init(name: "Image reference", placeholder: "alpine:latest", required: true)], flags: [.value("platform", "Platform"), .value("arch", "Architecture"), .value("os", "Operating system"), .value("scheme", "Registry scheme", "https"), .value("progress", "Progress format"), .value("max-concurrent-downloads", "Max concurrent downloads")]),
        .init(id: "push", title: "Push", summary: "Push a tagged OCI image to a registry.", arguments: ["image", "push"], positionals: [.init(name: "Image reference", placeholder: "registry.example/app:tag", required: true)], flags: [.value("platform", "Platform"), .value("arch", "Architecture"), .value("os", "Operating system"), .value("scheme", "Registry scheme", "https"), .value("progress", "Progress format")]),
        .init(id: "tag", title: "Tag", summary: "Create another reference for a local image.", arguments: ["image", "tag"], positionals: [.init(name: "Source", placeholder: "image:tag", required: true), .init(name: "Target", placeholder: "image:new-tag", required: true)]),
        .init(id: "delete", title: "Delete", summary: "Delete one or more local images; --all may be used without explicit image references.", arguments: ["image", "delete"], positionals: [.init(name: "Images", placeholder: "One reference per line", required: false, repeats: true, multiline: true)], flags: [.bool("all", "Delete all images"), .bool("force", "Ignore missing images")], destructive: true),
        .init(id: "prune", title: "Prune", summary: "Remove unused images; all removes every unreferenced image.", arguments: ["image", "prune"], flags: [.bool("all", "Remove all unused images")], destructive: true),
        .init(id: "save", title: "Save", summary: "Save one or more images to an OCI-compatible tar archive.", arguments: ["image", "save"], positionals: [.init(name: "Image references", placeholder: "One per line", required: true, repeats: true, multiline: true)], flags: [.value("output", "Archive path", "~/Desktop/images.tar", required: true), .value("platform", "Platform"), .value("arch", "Architecture"), .value("os", "Operating system")]),
        .init(id: "load", title: "Load", summary: "Load an OCI-compatible tar archive into the local image store.", arguments: ["image", "load"], flags: [.value("input", "Archive path", "~/Downloads/images.tar", required: true), .bool("force", "Load despite invalid members")]),
        .init(id: "inspect", title: "Inspect", summary: "Inspect image metadata as JSON.", arguments: ["image", "inspect"], positionals: [.init(name: "Image references", placeholder: "One per line", required: true, repeats: true, multiline: true)], refreshSection: false),
        .init(id: "list", title: "List", summary: "List local images.", arguments: ["image", "list"], flags: [.bool("verbose", "Include full image details"), .bool("quiet", "Only image references"), .value("format", "Output format", "json, table, yaml, or toml")], refreshSection: false),
    ]

    private static let builds: [AdvancedCommandSpec] = [
        .init(id: "build", title: "Build Image", summary: "Build with BuildKit from a Dockerfile or Containerfile.", arguments: ["build"], positionals: [.init(name: "Build context folder", placeholder: ".", required: false)], flags: [.value("file", "Dockerfile path"), .value("tag", "Image tags", "One per line", repeats: true, multiline: true), .value("build-arg", "Build arguments", "KEY=value per line", repeats: true, multiline: true, sensitive: true), .value("secret", "Build secrets", "id=...,src=... per line", repeats: true, multiline: true, sensitive: true), .value("ssh", "SSH forwarding", "default"), .value("target", "Build stage"), .value("platform", "Platforms", "One per line", repeats: true, multiline: true), .value("arch", "Architectures", "One per line", repeats: true, multiline: true), .value("os", "Operating systems", "One per line", repeats: true, multiline: true), .value("cpus", "Builder CPU limit"), .value("memory", "Builder memory"), .value("output", "Output configurations", "type=oci|tar|local[,dest=...] per line", repeats: true, multiline: true), .bool("pull", "Pull base images"), .bool("no-cache", "Disable cache"), .bool("quiet", "Suppress build output"), .value("progress", "Progress mode", "auto, plain, tty"), .value("vsock-port", "Builder shim vsock port"), .value("label", "Labels", "KEY=value per line", repeats: true, multiline: true), .value("dns", "DNS servers", "One IP per line", repeats: true, multiline: true), .value("dns-domain", "DNS domain"), .value("dns-search", "DNS search domains", repeats: true), .value("dns-option", "DNS options", repeats: true)]),
        .init(id: "builder-start", title: "Start Builder", summary: "Start the BuildKit builder with resource limits.", arguments: ["builder", "start"], flags: [.value("cpus", "CPU limit"), .value("memory", "Memory limit"), .value("dns", "DNS servers", repeats: true), .value("dns-domain", "DNS domain"), .value("dns-search", "DNS search domains", repeats: true), .value("dns-option", "DNS options", repeats: true)]),
        .init(id: "builder-status", title: "Builder Status", summary: "Show current builder state.", arguments: ["builder", "status"], flags: [.value("format", "Output format"), .bool("quiet", "Only builder ID")], refreshSection: false),
        .init(id: "builder-stop", title: "Stop Builder", summary: "Stop the BuildKit builder container.", arguments: ["builder", "stop"], destructive: true),
        .init(id: "builder-delete", title: "Delete Builder", summary: "Delete the builder container.", arguments: ["builder", "delete"], flags: [.bool("force", "Force deletion while running")], destructive: true),
    ]

    private static let volumes: [AdvancedCommandSpec] = [
        .init(id: "create", title: "Create", summary: "Create a named volume with optional size, labels and driver options.", arguments: ["volume", "create"], positionals: [.init(name: "Volume name", placeholder: "app-data", required: true)], flags: [.value("label", "Labels", "KEY=value per line", repeats: true, multiline: true), .value("opt", "Driver options", "KEY=value per line", repeats: true, multiline: true), .value("s", "Size", shortName: "-s")]),
        .init(id: "delete", title: "Delete", summary: "Delete volumes not used by any running or stopped container.", arguments: ["volume", "delete"], positionals: [.init(name: "Volume names", placeholder: "One per line", required: false, repeats: true, multiline: true)], flags: [.bool("all", "Delete all unused volumes")], destructive: true),
        .init(id: "prune", title: "Prune", summary: "Remove volumes with no container references.", arguments: ["volume", "prune"], destructive: true),
        .init(id: "list", title: "List", summary: "List named volumes.", arguments: ["volume", "list"], flags: [.value("format", "Output format"), .bool("quiet", "Only volume names")], refreshSection: false),
        .init(id: "inspect", title: "Inspect", summary: "Inspect volume metadata.", arguments: ["volume", "inspect"], positionals: [.init(name: "Volume names", placeholder: "One per line", required: true, repeats: true, multiline: true)], refreshSection: false),
    ]

    private static let networks: [AdvancedCommandSpec] = [
        .init(id: "create", title: "Create", summary: "Create a VMNet-backed network with optional subnets and plugin options.", arguments: ["network", "create"], positionals: [.init(name: "Network name", placeholder: "app-network", required: true)], flags: [.bool("internal", "Host-only network"), .value("label", "Labels", "KEY=value per line", repeats: true, multiline: true), .value("option", "Plugin options", "KEY=value per line", repeats: true, multiline: true), .value("plugin", "Network plugin", "container-network-vmnet"), .value("subnet", "IPv4 subnet"), .value("subnet-v6", "IPv6 prefix")]),
        .init(id: "delete", title: "Delete", summary: "Delete networks; all removes all user-defined networks.", arguments: ["network", "delete"], positionals: [.init(name: "Network names", placeholder: "One per line", required: false, repeats: true, multiline: true)], flags: [.bool("all", "Delete all user-defined networks")], destructive: true),
        .init(id: "prune", title: "Prune", summary: "Remove networks not connected to containers.", arguments: ["network", "prune"], destructive: true),
        .init(id: "list", title: "List", summary: "List user-defined networks.", arguments: ["network", "list"], flags: [.value("format", "Output format"), .bool("quiet", "Only network names")], refreshSection: false),
        .init(id: "inspect", title: "Inspect", summary: "Inspect network settings.", arguments: ["network", "inspect"], positionals: [.init(name: "Network names", placeholder: "One per line", required: true, repeats: true, multiline: true)], refreshSection: false),
    ]

    private static let registries: [AdvancedCommandSpec] = [
        .init(id: "list", title: "List Logins", summary: "List saved registry hostnames. Passwords are never shown.", arguments: ["registry", "list"], flags: [.value("format", "Output format"), .bool("quiet", "Only hostnames")], refreshSection: false),
        .init(id: "logout", title: "Log Out", summary: "Remove saved credentials for a registry.", arguments: ["registry", "logout"], positionals: [.init(name: "Registry host", placeholder: "registry.example.com", required: true)], destructive: true),
    ]

    private static let machines: [AdvancedCommandSpec] = [
        .init(id: "create", title: "Create Machine", summary: "Create a persistent Linux machine and optionally boot it.", arguments: ["machine", "create"], positionals: [.init(name: "Image reference", placeholder: "alpine:latest", required: true)], flags: [.value("name", "Machine name"), .bool("set-default", "Make default machine"), .bool("no-boot", "Create without booting"), .value("cpus", "Virtual CPUs"), .value("memory", "Memory"), .value("home-mount", "Home mount mode", "ro, rw, none"), .bool("virtualization", "Enable nested virtualization"), .value("kernel", "Custom kernel path"), .value("arch", "Architecture"), .value("os", "Operating system"), .value("platform", "Platform"), .value("scheme", "Registry scheme"), .value("progress", "Progress format"), .value("max-concurrent-downloads", "Max concurrent downloads")]),
        .init(id: "run", title: "Run", summary: "Run a shell or process in a machine; it boots the machine if needed.", arguments: ["machine", "run"], positionals: [.init(name: "Command and arguments", placeholder: "Leave empty for login shell; quoted words are tokenized literally", required: false, tokenized: true)], flags: [.value("name", "Machine name"), .bool("detach", "Detach process"), .bool("root", "Run as root"), .value("env", "Environment variables", "One per line", repeats: true, multiline: true, sensitive: true), .value("env-file", "Environment files", "One per line", repeats: true), .value("workdir", "Working directory"), .value("user", "User"), .value("uid", "UID"), .value("gid", "GID"), .bool("interactive", "Keep stdin open"), .bool("tty", "Allocate TTY"), .value("ulimit", "Ulimits", "type=soft:hard", repeats: true)], refreshSection: false),
        .init(id: "list", title: "List", summary: "List machines and identify the default.", arguments: ["machine", "list"], flags: [.value("format", "Output format"), .bool("quiet", "Only machine identifiers")], refreshSection: false),
        .init(id: "inspect", title: "Inspect", summary: "Show detailed machine information.", arguments: ["machine", "inspect"], positionals: [.init(name: "Machine ID", placeholder: "Default if empty", required: false)], refreshSection: false),
        .init(id: "set", title: "Configure", summary: "Change machine settings; they take effect after stop and restart.", arguments: ["machine", "set"], positionals: [.init(name: "Settings", placeholder: "cpus=4, one setting per line", required: true, repeats: true, multiline: true)], flags: [.value("name", "Machine name")]),
        .init(id: "set-default", title: "Set Default", summary: "Set the default machine for commands that omit a machine name.", arguments: ["machine", "set-default"], positionals: [.init(name: "Machine ID", placeholder: "machine-name", required: true)]),
        .init(id: "logs", title: "Machine Logs", summary: "Read machine logs or the boot log.", arguments: ["machine", "logs"], positionals: [.init(name: "Machine ID", placeholder: "Default if empty", required: false)], flags: [.bool("boot", "Show boot log"), .bool("follow", "Follow output"), .value("n", "Trailing lines", shortName: "-n")], refreshSection: false),
        .init(id: "stop", title: "Stop Machine", summary: "Stop a running machine; does not delete it.", arguments: ["machine", "stop"], positionals: [.init(name: "Machine ID", placeholder: "Default if empty", required: false)], destructive: true),
        .init(id: "delete", title: "Delete Machine", summary: "Stop and delete a machine. If it was default, choose another default.", arguments: ["machine", "delete"], positionals: [.init(name: "Machine ID", placeholder: "machine-name", required: true)], destructive: true),
    ]

    private static let system: [AdvancedCommandSpec] = [
        .init(id: "start", title: "Start Services", summary: "Start container services and optionally install a kernel.", arguments: ["system", "start"], flags: [.value("app-root", "Application data root"), .value("install-root", "Executables and plugins root"), .value("log-root", "Log root"), .bool("enable-kernel-install", "Allow default kernel installation"), .bool("disable-kernel-install", "Do not install a kernel"), .value("timeout", "Startup timeout seconds")]),
        .init(id: "stop", title: "Stop Services", summary: "Stop the launchd services. Running containers remain until stopped separately.", arguments: ["system", "stop"], flags: [.value("prefix", "Launchd prefix")], destructive: true),
        .init(id: "status", title: "Service Status", summary: "Check service status and API health.", arguments: ["system", "status"], flags: [.value("prefix", "Launchd prefix"), .value("format", "Output format")], refreshSection: false),
        .init(id: "version", title: "Version", summary: "Show CLI and API server version information.", arguments: ["system", "version"], flags: [.value("format", "Output format")], refreshSection: false),
        .init(id: "df", title: "Disk Usage", summary: "Show image, container and volume storage use.", arguments: ["system", "df"], flags: [.value("format", "Output format")], refreshSection: false),
        .init(id: "logs", title: "Service Logs", summary: "Read or follow logs from container services.", arguments: ["system", "logs"], flags: [.bool("follow", "Follow output"), .value("last", "Time range", "5m, 1h, 2d")], refreshSection: false),
        .init(id: "dns-list", title: "DNS Domains", summary: "List configured local DNS domains.", arguments: ["system", "dns", "list"], flags: [.value("format", "Output format"), .bool("quiet", "Only domain names")], refreshSection: false),
        .init(id: "kernel-set", title: "Set Kernel", summary: "Install or update the kernel used by the runtime.", arguments: ["system", "kernel", "set"], flags: [.value("arch", "Kernel architecture", "arm64 or amd64"), .value("binary", "Kernel file path"), .bool("force", "Overwrite matching kernel"), .bool("recommended", "Install recommended kernel"), .value("tar", "Archive path or URL"), .value("digest", "Remote archive digest")]),
        .init(id: "property-list", title: "System Properties", summary: "List system properties as JSON or TOML.", arguments: ["system", "property", "list"], flags: [.value("format", "Output format", "json or toml")], refreshSection: false),
    ]
}

private extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
