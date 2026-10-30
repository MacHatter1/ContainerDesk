import SwiftUI
import UniformTypeIdentifiers
import ContainerDeskCore

struct ResourceFormSheet: View {
    let section: ContainerSection
    let store: AppStore
    var initialImage: String = ""
    let onNotice: (FeatureNotice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var image = ""
    @State private var cpuText = ""
    @State private var memoryText = ""
    @State private var platform = ""
    @State private var subnet = ""
    @State private var subnetV6 = ""
    @State private var size = ""
    @State private var optionsText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var registryScheme = "https"
    @State private var internalNetwork = false
    @State private var saving = false
    @State private var errorText: String?

    init(section: ContainerSection, store: AppStore, initialImage: String = "", onNotice: @escaping (FeatureNotice) -> Void) {
        self.section = section
        self.store = store
        self.initialImage = initialImage
        self.onNotice = onNotice
        _image = State(initialValue: initialImage)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Resource") {
                    if section == .machines || section == .images {
                        TextField("Image reference", text: $image, prompt: Text("docker.io/library/alpine:latest"))
                    }
                    if section != .registries && section != .images {
                        TextField(nameLabel, text: $name, prompt: Text(namePlaceholder))
                    }
                    if section == .registries {
                        TextField("Registry host", text: $name, prompt: Text("registry.example:5000"))
                        TextField("Username", text: $username)
                        SecureField("Password or token", text: $password)
                        Picker("Registry scheme", selection: $registryScheme) {
                            Text("HTTPS").tag("https")
                            Text("HTTP").tag("http")
                        }
                        Text("An HTTP or HTTPS URL may include a port. A scheme included in the URL takes precedence over this selection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if section == .images {
                    Section("Platform") {
                        TextField("Platform (optional)", text: $platform, prompt: Text("linux/arm64"))
                    }
                }

                if section == .volumes {
                    Section("Volume options") {
                        TextField("Size", text: $size, prompt: Text("10G"))
                        TextEditor(text: $optionsText).font(.system(.body, design: .monospaced)).frame(minHeight: 64)
                            .overlay(alignment: .topLeading) { if optionsText.isEmpty { Text("Driver options, one KEY=value per line; e.g. journal=ordered").foregroundStyle(.tertiary).padding(.top, 7).padding(.leading, 5).allowsHitTesting(false) } }
                    }
                }

                if section == .networks {
                    Section("Network options") {
                        Toggle("Host only (internal)", isOn: $internalNetwork)
                        TextField("IPv4 subnet", text: $subnet, prompt: Text("192.168.100.0/24"))
                        TextField("IPv6 prefix", text: $subnetV6, prompt: Text("fd00:1234::/64"))
                        TextEditor(text: $optionsText).font(.system(.body, design: .monospaced)).frame(minHeight: 64)
                            .overlay(alignment: .topLeading) { if optionsText.isEmpty { Text("Plugin options, one KEY=value per line").foregroundStyle(.tertiary).padding(.top, 7).padding(.leading, 5).allowsHitTesting(false) } }
                    }
                }

                Section {
                    Label("Additional CLI flags can be entered in Advanced Command. Inputs are passed as argv values; shell syntax is never evaluated.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorText { Section { Text(errorText).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            .navigationTitle(sheetTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { Task { await submit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || !canSubmit)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var nameLabel: String { section == .machines ? "Name (optional)" : "Name" }
    private var namePlaceholder: String { section == .volumes ? "app-data" : section == .networks ? "app-network" : "app" }
    private var sheetTitle: String {
        switch section {
        case .images: "Pull Image"
        case .volumes: "Create Volume"
        case .networks: "Create Network"
        case .registries: "Log In to Registry"
        case .machines: "Create Container Machine"
        default: "Create Resource"
        }
    }
    private var actionTitle: String {
        switch section { case .images: "Pull"; case .registries: "Log In"; default: "Create" }
    }
    private var canSubmit: Bool {
        switch section {
        case .machines: !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .images: !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .registries: !name.isEmpty && !username.isEmpty && !password.isEmpty
        default: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit() async {
        saving = true
        errorText = nil
        do {
            let request = try makeRequest()
            let result = try await store.execute(request, title: sheetTitle)
            guard result.succeeded else { throw FeatureCommandError(result: result) }
            dismiss()
            await store.refresh(section, force: true)
        } catch {
            errorText = error.localizedDescription
            if section == .registries { password = "" }
        }
        saving = false
    }

    private func makeRequest() throws -> CommandRequest {
        var args: [String]
        switch section {
        case .images:
            args = ["image", "pull"]
            if !platform.isEmpty { args += ["--platform", platform] }
            args.append(image)
        case .volumes:
            args = ["volume", "create"]
            if !size.isEmpty { args += ["-s", size] }
            for line in optionsText.lines { args += ["--opt", line] }
            args.append(name)
        case .networks:
            args = ["network", "create"]
            if internalNetwork { args.append("--internal") }
            if !subnet.isEmpty { args += ["--subnet", subnet] }
            if !subnetV6.isEmpty { args += ["--subnet-v6", subnetV6] }
            for line in optionsText.lines { args += ["--option", line] }
            args.append(name)
        case .registries:
            return try RegistryLoginRequestBuilder.request(server: name, scheme: registryScheme, username: username, password: password)
        case .machines:
            args = ["machine", "create"]
            if !name.isEmpty { args += ["--name", name] }
            if !cpuText.isEmpty { args += ["--cpus", cpuText] }
            if !memoryText.isEmpty { args += ["--memory", memoryText] }
            args.append(image)
        default: throw FeatureCommandError(message: "This resource type does not support this form.")
        }
        return CommandRequest(arguments: args)
    }

}

struct ResourceActionSheet: View {
    let action: ResourcePendingAction
    let section: ContainerSection
    let store: AppStore
    let onResult: (FeatureNotice, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var runtime: AppStore.ReviewedRuntime
    @State private var target = ""
    @State private var secondary = ""
    @State private var tagBeforePush = false
    @State private var showingArchivePicker = false
    @State private var output = ""
    @State private var busy = false
    @State private var showConfirm = false
    @State private var failure: String?

    init(action: ResourcePendingAction, section: ContainerSection, store: AppStore, onResult: @escaping (FeatureNotice, String) -> Void) {
        self._runtime = State(initialValue: store.captureReviewedRuntime())
        self.action = action
        self.section = section
        self.store = store
        self.onResult = onResult
        self._target = State(initialValue: ResourceActionTargetValue.initial(selectedResourceID: action.resourceID))
    }

    var body: some View {
        NavigationStack {
            Form {
                if action.kind == .stopAll {
                    Section("Scope") { Label("All currently running containers", systemImage: "shippingbox") }
                } else {
                    Section("Target") {
                        if action.kind == .load {
                            HStack { TextField("Archive file", text: $target, prompt: Text("~/Downloads/images.tar")); Button("Choose…") { showingArchivePicker = true } }
                        } else {
                            TextField(targetLabel, text: $target, prompt: Text("Resource name or image reference"))
                        }
                        if action.kind == .push {
                            Toggle("Create a remote tag before pushing", isOn: $tagBeforePush)
                            if tagBeforePush { TextField("Remote image reference", text: $secondary, prompt: Text("registry.example/app:tag")) }
                        }
                        if action.kind == .save { TextField("Archive output path", text: $secondary, prompt: Text("~/Desktop/images.tar")) }
                        if action.kind == .signal { TextField("Signal", text: $secondary, prompt: Text("SIGTERM or KILL")) }
                        if action.kind == .tag { TextField("New image reference", text: $secondary, prompt: Text("registry.example/app:tag")) }
                    }
                }
                if !output.isEmpty {
                    Section("Command output") { TextEditor(text: .constant(output)).font(.system(.caption, design: .monospaced)).frame(minHeight: 150).textSelection(.enabled) }
                }
                if let failure { Section { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            .navigationTitle(actionTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { Task { if isDestructive { showConfirm = true } else { await perform() } } }
                        .buttonStyle(.borderedProminent).disabled(busy || !canRun)
                }
            }
            .confirmationDialog(confirmationTitle, isPresented: $showConfirm, titleVisibility: .visible) {
                Button(actionTitle, role: .destructive) { Task { await perform() } }
                Button("Cancel", role: .cancel) { }
            } message: { Text(confirmationMessage) }
        }
        .frame(minWidth: 460, minHeight: 340)
        .fileImporter(isPresented: $showingArchivePicker, allowedContentTypes: [.data, .archive, .content], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { target = url.path }
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    private var normalizedTarget: String { ResourceActionTargetValue.normalized(target) }
    private var normalizedSecondary: String { secondary.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var displayedTarget: String { normalizedTarget.isEmpty ? "this resource" : ResourceActionTargetValue.confirmationLabel(normalizedTarget) }
    private var targetLabel: String { action.kind == .setDefault ? "Machine name" : action.kind == .logout ? "Registry host" : "Resource" }
    private var actionTitle: String {
        switch action.kind {
        case .stop: section == .machines ? "Stop Machine" : "Stop Container"
        case .stopAll: "Stop All Containers"
        case .delete: "Delete Resource"
        case .prune: "Prune Unused Resources"
        case .push: "Push Image"
        case .save: "Save Image Archive"
        case .load: "Load Image Archive"
        case .logout: "Log Out"
        case .setDefault: "Set Default Machine"
        case .logs: "Container Logs"
        case .stats: "Container Stats"
        case .exec: "Open Terminal"
        case .start: "Start Container"
        case .restart: "Restart Container"
        case .signal: "Signal Container"
        case .tag: "Add Image Tag"
        }
    }
    private var isDestructive: Bool { [.stop, .stopAll, .delete, .prune, .logout, .restart, .signal].contains(action.kind) }
    private var confirmationTitle: String {
        switch action.kind {
        case .stopAll: "Stop all running containers?"
        case .prune: "Prune unused \(section.title.lowercased())?"
        case .logout: "Remove saved credentials for \(normalizedTarget.isEmpty ? "this registry" : ResourceActionTargetValue.confirmationLabel(normalizedTarget))?"
        case .stop: "Stop \(section == .machines ? "machine" : "container") \(displayedTarget)?"
        case .restart: "Restart container \(displayedTarget)?"
        case .signal: "Signal container \(displayedTarget)?"
        default: "Delete \(displayedTarget)?"
        }
    }
    private var confirmationMessage: String {
        switch action.kind {
        case .stopAll: "Every currently running container will be stopped gracefully."
        case .prune: "Unused resources may be removed to reclaim storage."
        case .logout: "You will need to log in again before pushing to this registry."
        case .stop: "The selected \(section == .machines ? "machine" : "container") will stop. Its data remains available."
        case .restart: "The container will stop gracefully and start again."
        case .signal: "The selected Linux signal will be sent immediately."
        default: "Review the exact target shown above before continuing."
        }
    }
    private var canRun: Bool {
        if action.kind == .delete && !ResourceActionRouting.supportsDelete(section) { return false }
        return switch action.kind {
        case .stopAll, .prune: true
        case .push: !normalizedTarget.isEmpty && (!tagBeforePush || !normalizedSecondary.isEmpty)
        case .tag: !normalizedTarget.isEmpty && !normalizedSecondary.isEmpty
        case .save: !normalizedTarget.isEmpty && !normalizedSecondary.isEmpty
        case .load: !normalizedTarget.isEmpty
        case .logout, .setDefault: !normalizedTarget.isEmpty
        case .logs, .stats, .exec, .start, .stop, .delete, .restart, .signal: !normalizedTarget.isEmpty
        }
    }

    private func perform() async {
        guard canRun else {
            failure = "Enter a valid target and any required additional values."
            return
        }
        busy = true
        failure = nil
        do {
            var args: [String]
            let id = normalizedTarget
            let targetArguments = ResourceActionTargetValue.positionalArguments(id)
            switch action.kind {
            case .stop: args = (section == .machines ? ["machine", "stop"] : ["stop"]) + targetArguments
            case .stopAll: args = ["stop", "--all"]
            case .delete:
                args = try ResourceActionRouting.deletionArguments(section: section, target: id)
            case .prune:
                switch section {
                case .containers: args = ["prune"]
                case .images: args = ["image", "prune"]
                case .volumes: args = ["volume", "prune"]
                case .networks: args = ["network", "prune"]
                default: args = ["prune"]
                }
            case .push:
                if tagBeforePush {
                    _ = try await store.execute(CommandRequest(arguments: ["image", "tag"] + targetArguments + [normalizedSecondary]), title: "Tag Image", reviewedRuntime: runtime)
                    args = ["image", "push"] + ResourceActionTargetValue.positionalArguments(normalizedSecondary)
                } else { args = ["image", "push"] + targetArguments }
            case .save: args = ["image", "save", "--output", normalizedSecondary] + targetArguments
            case .load: args = ["image", "load", "--input", normalizedTarget]
            case .logout: args = ["registry", "logout"] + targetArguments
            case .setDefault: args = ["machine", "set-default"] + targetArguments
            case .logs: args = ["logs"] + targetArguments
            case .stats: args = ["stats", "--no-stream", "--format", "json"] + targetArguments
            case .exec: args = ["exec", "--interactive", "--tty"] + targetArguments + ["/bin/sh"]
            case .start: args = ["start"] + targetArguments
            case .restart:
                _ = try await store.execute(CommandRequest(arguments: ["stop"] + targetArguments), title: "Stop Container for Restart", reviewedRuntime: runtime)
                args = ["start"] + targetArguments
            case .signal: args = ["kill", "--signal", normalizedSecondary.isEmpty ? "SIGTERM" : normalizedSecondary] + targetArguments
            case .tag: args = ["image", "tag"] + targetArguments + [normalizedSecondary]
            }
            let result = try await store.execute(CommandRequest(arguments: args), title: actionTitle, reviewedRuntime: runtime)
            output = result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError)
            guard result.succeeded else { throw FeatureCommandError(result: result) }
            if ![.logs, .stats].contains(action.kind) { await store.refresh(section, force: true) }
        } catch { failure = error.localizedDescription }
        busy = false
    }
}

enum ResourceActionTargetValue {
    static func initial(selectedResourceID: String?) -> String {
        normalized(selectedResourceID ?? "")
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func positionalArguments(_ value: String) -> [String] {
        let target = normalized(value)
        // End option parsing so a resource name like "--all" stays one target.
        return target.isEmpty ? [] : ["--", target]
    }

    static func confirmationLabel(_ value: String) -> String {
        value.hasPrefix("-") ? "“\(value)”" : value
    }
}

struct FeatureCommandError: Error, LocalizedError {
    let text: String
    init(result: CommandResult) {
        if result.timedOut { text = "Command timed out."; return }
        let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        text = message.isEmpty ? (result.failureDescription ?? "Command did not complete.") : message
    }
    init(message: String) { text = message }
    var errorDescription: String? { text }
}

enum SafeArgumentTokenizer {
    static func tokenize(_ input: String) throws -> [String] {
        var args: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var active = false
        for character in input {
            if escaped { token.append(character); escaped = false; active = true; continue }
            if character == "\\" && quote != "'" { escaped = true; active = true; continue }
            if let currentQuote = quote {
                if character == currentQuote { quote = nil } else { token.append(character) }
                active = true
                continue
            }
            if character == "'" || character == "\"" { quote = character; active = true; continue }
            if character.isWhitespace {
                if active { args.append(token); token = ""; active = false }
            } else { token.append(character); active = true }
        }
        guard quote == nil && !escaped else { throw FeatureCommandError(message: "Finish the open quote or escape before running the command.") }
        if active { args.append(token) }
        return args
    }
}

private extension String {
    var lines: [String] { split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}
