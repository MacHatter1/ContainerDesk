import ContainerDeskCore
import SwiftUI
import UniformTypeIdentifiers

enum ContainerRunSheetMode {
    case run, editProfile, duplicateProfile
}

/// A profile is launch configuration, not a container or a copy of its data.
struct ContainerRunSheet: View {
    let store: AppStore
    let mode: ContainerRunSheetMode
    let onNotice: (FeatureNotice) -> Void
    let stackID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var configuration: ContainerLaunchConfiguration
    @State private var originalProfile: EnvironmentProfile?
    @State private var profileName: String
    @State private var environmentText = ""
    @State private var requiredKeysText: String
    @State private var busy = false
    @State private var errorText: String?
    @State private var savedMessage: String?
    @State private var choosingEnvironmentFiles = false
    @State private var pendingProfile: EnvironmentProfile?
    @State private var confirmingLoad = false
    @State private var launchedWithoutMembership = false

    init(store: AppStore, initialImage: String = "", profile: EnvironmentProfile? = nil,
         mode: ContainerRunSheetMode = .run, stackID: UUID? = nil, onNotice: @escaping (FeatureNotice) -> Void) {
        self.store = store
        self.mode = mode
        self.onNotice = onNotice
        self.stackID = stackID
        var configuration = profile?.configuration ?? ContainerLaunchConfiguration(image: initialImage)
        if mode == .duplicateProfile { configuration.name = "" }
        _configuration = State(initialValue: configuration)
        _originalProfile = State(initialValue: mode == .duplicateProfile ? nil : profile)
        _profileName = State(initialValue: profile.map { mode == .duplicateProfile ? $0.name + " Copy" : $0.name } ?? "")
        _requiredKeysText = State(initialValue: configuration.requiredEnvironmentKeys.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorText {
                    InlineNotice(message: errorText, kind: .error)
                        .padding(.horizontal, 20).padding(.top, 12)
                }
                Form {
                    profileSection
                    launchSection
                    environmentSection
                    connectionSection
                    resourceSection
                }
                .formStyle(.grouped)
                .disabled(busy)
            }
            .navigationTitle(mode == .run ? "Run Container" : mode == .duplicateProfile ? "Duplicate Profile" : "Environment Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .run ? "Run" : "Save Profile") {
                        if mode == .run { Task { await run() } }
                        else { saveProfile(close: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || launchedWithoutMembership || configuration.image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode != .run && profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .frame(width: 620, height: 700)
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $choosingEnvironmentFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() where !configuration.environmentFiles.contains(url.path) {
                    configuration.environmentFiles.append(url.path)
                }
            } catch { errorText = "Could not select environment files: \(error.localizedDescription)" }
        }
        .confirmationDialog("Load this profile and replace the current form?", isPresented: $confirmingLoad, titleVisibility: .visible) {
            Button("Load Profile") {
                if let pendingProfile { load(pendingProfile) }
                pendingProfile = nil
            }
            Button("Cancel", role: .cancel) { pendingProfile = nil }
        } message: {
            Text("Unsaved settings and environment values in this form will be discarded.")
        }
    }

    private var profileSection: some View {
        Section("Environment profile") {
            if mode == .run, !store.environmentProfiles.profiles.isEmpty {
                Menu("Load Saved Profile…") {
                    ForEach(store.environmentProfiles.profiles) { profile in
                        Button(profile.name) { pendingProfile = profile; confirmingLoad = true }
                    }
                }
            }
            TextField("Profile name", text: $profileName, prompt: Text("API development"))
            if mode == .run {
                HStack {
                    Button(originalProfile == nil ? "Save Profile" : "Save Changes") { saveProfile(close: false) }
                        .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if originalProfile != nil {
                        Button("Save a Copy") {
                            originalProfile = nil
                            profileName += " Copy"
                            configuration.name = ""
                            savedMessage = "Choose a new container name, ports, and volume sources, then save the copy."
                        }
                    }
                }
            }
            Text("Profiles save launch settings and environment-file paths. Values entered for a run are replaced by required variable names when saved.")
                .font(.caption).foregroundStyle(.secondary)
            if let savedMessage {
                Text(savedMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.environmentProfiles.loadError {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Reload Profiles", systemImage: "arrow.clockwise") { store.environmentProfiles.reload() }
            }
        }
    }

    private var launchSection: some View {
        Section("Container") {
            if let stackID, let stack = store.managedStacks.stacks.first(where: { $0.id == stackID }) {
                LabeledContent("Stack", value: stack.name)
                Text("This container will join the stack after a successful launch. A container name is generated when omitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Image reference", text: $configuration.image, prompt: Text("docker.io/library/postgres:17"))
            TextField("Container name (optional)", text: $configuration.name, prompt: Text("api-dev"))
            TextField("Command and arguments", text: $configuration.command, prompt: Text("/bin/sh -lc 'echo ready'"))
                .font(.system(.body, design: .monospaced))
            Text("Runs in the background. Quoted arguments are supported; shell expansion is not performed. Commands are saved with the profile, so supply credentials through environment files or run-only variables.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var environmentSection: some View {
        Section("Environment") {
            ProfileLinesEditor(title: "Environment files", text: linesBinding(\.environmentFiles), prompt: "/absolute/path/to/.env or ~/.config/app.env")
            Button("Choose Environment Files…", systemImage: "doc.badge.plus") { choosingEnvironmentFiles = true }
            ProfileLinesEditor(title: "Required variable names", text: $requiredKeysText, prompt: "DATABASE_URL\nAPI_KEY")
            Text("Required variables must be supplied by an environment file or this run’s overrides. File contents are read only when you run the container.")
                .font(.caption).foregroundStyle(.secondary)
            if mode == .run {
                ProfileLinesEditor(title: "Overrides for this run only", text: $environmentText, prompt: "KEY=value, one per line")
                if !requiredKeysText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Required: \(Self.lines(requiredKeysText).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connectionSection: some View {
        Section("Ports, storage, and networks") {
            ProfileLinesEditor(title: "Published ports", text: linesBinding(\.ports), prompt: "127.0.0.1:8080:80")
            ProfileLinesEditor(title: "Volume mounts", text: linesBinding(\.volumes), prompt: "app-data:/var/lib/app\n/absolute/host/path:/workspace:ro")
            Text("Existing volume names reuse their data. A new volume name creates an empty volume during launch. Duplicating a profile keeps its mount sources; change them here to isolate data.")
                .font(.caption).foregroundStyle(.secondary)
            ProfileLinesEditor(title: "Networks (optional)", text: linesBinding(\.networks), prompt: "app-network")
        }
    }

    private var resourceSection: some View {
        Section("Resources") {
            TextField("CPUs (optional)", text: $configuration.cpus, prompt: Text("2"))
            TextField("Memory (optional)", text: $configuration.memory, prompt: Text("512M; minimum 200M"))
            TextField("Platform (optional)", text: $configuration.platform, prompt: Text("linux/arm64"))
        }
    }

    private func linesBinding(_ keyPath: WritableKeyPath<ContainerLaunchConfiguration, [String]>) -> Binding<String> {
        Binding(get: { configuration[keyPath: keyPath].joined(separator: "\n") },
                set: { configuration[keyPath: keyPath] = $0.components(separatedBy: "\n") })
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var environmentEntries: [String] {
        // Preserve whitespace in values; only the variable name must match KEY=value.
        environmentText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func reviewedConfiguration() -> ContainerLaunchConfiguration {
        var result = configuration
        result.requiredEnvironmentKeys = Self.lines(requiredKeysText)
        result.ports = result.ports.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        result.volumes = result.volumes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        result.networks = result.networks.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        result.environmentFiles = result.environmentFiles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return result
    }

    private func saveProfile(close: Bool) {
        errorText = nil
        savedMessage = nil
        do {
            var savedConfiguration = reviewedConfiguration()
            let keys = try ContainerLaunchRequestBuilder.requiredEnvironmentKeys(in: environmentEntries)
            for key in keys where !savedConfiguration.requiredEnvironmentKeys.contains(key) {
                savedConfiguration.requiredEnvironmentKeys.append(key)
            }
            let saved = try store.environmentProfiles.save(name: profileName, configuration: savedConfiguration, replacing: originalProfile)
            originalProfile = saved
            profileName = saved.name
            requiredKeysText = saved.configuration.requiredEnvironmentKeys.joined(separator: "\n")
            savedMessage = "Profile saved. Environment override values remain in this form only."
            if close { dismiss() }
        } catch { errorText = error.localizedDescription }
    }

    private func load(_ profile: EnvironmentProfile) {
        configuration = profile.configuration
        originalProfile = profile
        profileName = profile.name
        requiredKeysText = profile.configuration.requiredEnvironmentKeys.joined(separator: "\n")
        environmentText = ""
        errorText = nil
        savedMessage = nil
    }

    private func run() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let result = try await store.runContainer(configuration: reviewedConfiguration(), environment: environmentEntries, stackID: stackID)
            guard result.succeeded else { throw FeatureCommandError(result: result) }
            onNotice(FeatureNotice(title: "Container launched", message: "The background launch command completed."))
            dismiss()
        } catch {
            if case ManagedStackError.launchedButNotAssigned = error { launchedWithoutMembership = true }
            errorText = error.localizedDescription
        }
    }
}

private struct ProfileLinesEditor: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 54)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(prompt).font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(title)
        }
    }
}
