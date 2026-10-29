import ContainerDeskCore
import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct EnvironmentProfilesSheet: View {
    let store: AppStore

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var editor: ProfileEditorPresentation?
    @State private var deletionCandidate: EnvironmentProfile?
    @State private var operationError: String?
    @State private var notice: FeatureNotice?
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var exportDocument: EnvironmentProfileJSONDocument?
    @State private var exportFilename = "Environment Profile"

    private var library: EnvironmentProfilesStore { store.environmentProfiles }
    private var selectedProfile: EnvironmentProfile? { library.profiles.first { $0.id == selectedID } }
    private var matchingProfiles: [EnvironmentProfile] {
        library.profiles.filter {
            searchText.isEmpty || $0.name.localizedStandardContains(searchText) || $0.configuration.image.localizedStandardContains(searchText)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search profiles or images", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Import…", systemImage: "square.and.arrow.down") { showsImporter = true }
                        .disabled(library.loadError != nil)
                    Button("New Profile", systemImage: "plus") { present(nil, mode: .editProfile) }
                        .buttonStyle(.borderedProminent)
                        .disabled(library.loadError != nil)
                }
                .padding()
                Divider()
                if let error = library.loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        InlineNotice(message: error, kind: .error)
                        Button("Reload Profiles", systemImage: "arrow.clockwise") { library.reload() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    Divider()
                }
                profileList
                Divider()
                libraryFooter
            }
            .navigationTitle("Environment Profiles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 650, idealWidth: 700, minHeight: 500, idealHeight: 550)
        .onChange(of: matchingProfiles.map(\.id)) { _, visibleIDs in
            if let selectedID, !visibleIDs.contains(selectedID) { self.selectedID = nil }
        }
        .sheet(item: $editor) { presentation in
            ContainerRunSheet(store: store, profile: presentation.profile, mode: presentation.mode) { notice = $0 }
        }
        .alert("Delete Environment Profile?", isPresented: Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        ), presenting: deletionCandidate) { profile in
            Button("Delete Profile", role: .destructive) { delete(profile) }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: { profile in
            Text("Delete “\(profile.name)” from this library? Containers, volumes, mounted files, and environment files remain in place.")
        }
        .alert("Profile Operation Failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            importProfile(result)
        }
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .json, defaultFilename: exportFilename) { result in
            switch result {
            case .success:
                notice = FeatureNotice(title: "Profile Exported", message: "The JSON contains launch settings and references to mounted data and environment files. It does not include their contents.")
            case .failure(let error): operationError = error.localizedDescription
            }
        }
    }

    private var profileList: some View {
        List(selection: $selectedID) {
            ForEach(matchingProfiles) { profile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.body.weight(.medium))
                    Text(profile.configuration.image).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(profile.id)
                .contextMenu { profileActions(profile) }
            }
        }
        .listStyle(.inset)
        .overlay {
            if matchingProfiles.isEmpty {
                ContentUnavailableView(
                    library.loadError != nil ? "Profiles Unavailable" : (searchText.isEmpty ? "No Environment Profiles" : "No Matching Profiles"),
                    systemImage: "square.stack.3d.up",
                    description: Text(library.loadError != nil ? "Reload the library to retry reading your saved profiles." : (searchText.isEmpty ? "Save reusable launch settings, then review them whenever you run a container." : "Try another profile name or image."))
                )
                .allowsHitTesting(false)
            }
        }
    }

    private var libraryFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedProfile {
                Text("Mounts and environment files are references to existing data. Duplicating a profile does not clone their contents.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Edit…") { present(selectedProfile, mode: .editProfile) }
                    Button("Duplicate…") { present(selectedProfile, mode: .duplicateProfile) }
                    Button("Export…") { export(selectedProfile) }
                    Button("Delete…", role: .destructive) { deletionCandidate = selectedProfile }
                    Spacer()
                    Button("Review & Run…", systemImage: "play.fill") { present(selectedProfile, mode: .run) }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(library.loadError != nil)
            } else {
                Text("Select a profile to edit, duplicate, export, delete, or review before running.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let notice {
                Text("\(notice.title): \(notice.message)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding()
    }

    @ViewBuilder private func profileActions(_ profile: EnvironmentProfile) -> some View {
        Group {
            Button("Review & Run…") { present(profile, mode: .run) }
            Button("Edit…") { present(profile, mode: .editProfile) }
            Button("Duplicate…") { present(profile, mode: .duplicateProfile) }
            Button("Export…") { export(profile) }
            Divider()
            Button("Delete…", role: .destructive) { deletionCandidate = profile }
        }
        .disabled(library.loadError != nil)
    }

    private func present(_ profile: EnvironmentProfile?, mode: ContainerRunSheetMode) {
        notice = nil
        editor = ProfileEditorPresentation(profile: profile, mode: mode)
    }

    private func delete(_ profile: EnvironmentProfile) {
        do {
            try library.delete(profile)
            selectedID = nil
            notice = FeatureNotice(title: "Profile Deleted", message: "The saved launch settings were removed. Container data remains in place.")
        } catch { operationError = error.localizedDescription }
        deletionCandidate = nil
    }

    private func export(_ profile: EnvironmentProfile) {
        do {
            exportDocument = EnvironmentProfileJSONDocument(data: try profile.exportData())
            exportFilename = profile.name.replacingOccurrences(of: "/", with: "-")
            showsExporter = true
        } catch { operationError = error.localizedDescription }
    }

    private func importProfile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let profile = try library.importProfile(data: readProfileData(url))
            selectedID = profile.id
            searchText = ""
            notice = FeatureNotice(title: "Profile Imported", message: "Imported as “\(profile.name)”. Name collisions receive an Imported suffix. Review file paths, mounts, ports, and required environment keys before running.")
        } catch { operationError = error.localizedDescription }
    }

    private func readProfileData(_ url: URL) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw EnvironmentProfileError.invalidDocument }
        let limit = 128 * 1_024
        guard metadata.st_size >= 0, metadata.st_size <= limit else { throw EnvironmentProfileError.documentTooLarge }
        var data = Data(count: limit + 1)
        var count = 0
        while count < data.count {
            let readCount = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if readCount == 0 { break }
            count += readCount
        }
        guard count <= limit else { throw EnvironmentProfileError.documentTooLarge }
        data.count = count
        return data
    }
}

private struct ProfileEditorPresentation: Identifiable {
    let id = UUID()
    let profile: EnvironmentProfile?
    let mode: ContainerRunSheetMode
}

private struct EnvironmentProfileJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw EnvironmentProfileError.invalidDocument }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
