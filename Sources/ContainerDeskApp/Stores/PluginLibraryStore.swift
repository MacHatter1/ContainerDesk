import ContainerDeskCore
import Darwin
import Foundation
import Observation

struct SavedComposeProject: Codable, Identifiable, Hashable {
    var id: String { fileURL.absoluteString }
    var fileURL: URL
    var name: String
}

struct ComposeDownReview {
    let project: SavedComposeProject
    let keepNetworks: Bool
    var displayName: String { project.name.isEmpty ? "default project for \(project.fileURL.lastPathComponent)" : project.name }
    var request: CommandRequest {
        var args = ["compose", "down", "--file", project.fileURL.path]
        if !project.name.isEmpty { args += ["--project-name", project.name] }
        if keepNetworks { args.append("--keep-networks") }
        return CommandRequest(arguments: args, workingDirectory: project.fileURL.deletingLastPathComponent())
    }
}

enum PluginLibraryKind: String, Identifiable {
    case compose, kubernetes
    var id: String { rawValue }
    var title: String { self == .compose ? "Compose projects" : "Kubernetes names" }
    var key: String { self == .compose ? "containerdesk.composeProjects.v1" : "containerdesk.k8sTrackedNames.v1" }
}

struct PluginLibraryRecoveryReview {
    let kind: PluginLibraryKind
    let archive: Data
}

/// One library for every window. Each write also merges the latest persisted document.
@MainActor @Observable
final class PluginLibraryStore {
    private(set) var projects: [SavedComposeProject]
    private(set) var clusterNames: [String]
    var loadError: String? { projectLoadError ?? clusterLoadError }
    private var projectLoadError: String?
    private var clusterLoadError: String?
    private let defaults: UserDefaults
    private static let composeKey = PluginLibraryKind.compose.key
    private static let clusterKey = PluginLibraryKind.kubernetes.key

    init(defaults: UserDefaults) {
        self.defaults = defaults
        projects = []
        clusterNames = []
        _ = reloadProjects()
        _ = reloadClusters()
    }

    @discardableResult func addProject(_ url: URL, name: String) -> SavedComposeProject {
        let project = SavedComposeProject(fileURL: url.standardizedFileURL, name: name)
        guard reloadProjects() else { return project }
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.insert(project, at: 0) }
        write(projects, key: Self.composeKey)
        return project
    }

    func renameProject(id: String, name: String) {
        guard reloadProjects() else { return }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
        write(projects, key: Self.composeKey)
    }

    func forgetProject(id: String) {
        guard reloadProjects() else { return }
        projects.removeAll { $0.id == id }
        write(projects, key: Self.composeKey)
    }

    func rememberCluster(_ name: String) {
        guard reloadClusters() else { return }
        if !clusterNames.contains(name) { clusterNames.append(name) }
        write(clusterNames, key: Self.clusterKey)
    }

    func forgetCluster(_ name: String) {
        guard reloadClusters() else { return }
        clusterNames.removeAll { $0 == name }
        write(clusterNames, key: Self.clusterKey)
    }

    func error(for kind: PluginLibraryKind) -> String? { kind == .compose ? projectLoadError : clusterLoadError }

    func retry(_ kind: PluginLibraryKind) {
        if kind == .compose { _ = reloadProjects() } else { _ = reloadClusters() }
    }

    func recoveryReview(_ kind: PluginLibraryKind) throws -> PluginLibraryRecoveryReview {
        guard let stored = defaults.object(forKey: kind.key) else { throw PluginLibraryRecoveryError.changed }
        let archive = try PropertyListSerialization.data(fromPropertyList: ["value": stored], format: .binary, options: 0)
        return .init(kind: kind, archive: archive)
    }

    /// Archive the exact damaged value before replacing only this collection.
    @discardableResult func recover(_ review: PluginLibraryRecoveryReview, repairedJSON: Data? = nil, backupDirectory: URL? = nil) throws -> URL {
        let replacement: String
        if let repairedJSON {
            guard repairedJSON.count <= 1_000_000, let json = String(data: repairedJSON, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            if review.kind == .compose { _ = try JSONDecoder().decode([SavedComposeProject].self, from: repairedJSON) }
            else { _ = try JSONDecoder().decode([String].self, from: repairedJSON) }
            replacement = json
        } else { replacement = "[]" }
        guard try recoveryReview(review.kind).archive == review.archive else { throw PluginLibraryRecoveryError.changed }
        let root = backupDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContainerDesk/Library Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = root.appendingPathComponent("\(review.kind.rawValue)-\(UUID().uuidString).plist")
        try export(review, to: backup)
        let directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
        guard try recoveryReview(review.kind).archive == review.archive else { throw PluginLibraryRecoveryError.changed }
        defaults.set(replacement, forKey: review.kind.key)
        retry(review.kind)
        return backup
    }

    func export(_ review: PluginLibraryRecoveryReview, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: review.archive); try handle.synchronize() }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    private func reloadProjects() -> Bool {
        do { projects = try read([SavedComposeProject].self, key: Self.composeKey); projectLoadError = nil; return true }
        catch { projectLoadError = "Saved Compose projects could not be read. The saved library has been preserved. Open Library Recovery to retry, import repaired JSON or reset it with a backup."; return false }
    }
    private func reloadClusters() -> Bool {
        do { clusterNames = try read([String].self, key: Self.clusterKey); clusterLoadError = nil; return true }
        catch { clusterLoadError = "Saved Kubernetes names could not be read. The saved library has been preserved. Open Library Recovery to retry, import repaired JSON or reset it with a backup."; return false }
    }
    private func read<T: Decodable>(_ type: T.Type, key: String) throws -> T where T: RangeReplaceableCollection {
        guard let stored = defaults.object(forKey: key) else { return T() }
        guard let string = stored as? String, let data = string.data(using: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(type, from: data)
    }
    private func write<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return }
        defaults.set(string, forKey: key)
    }
}

private enum PluginLibraryRecoveryError: LocalizedError {
    case changed
    var errorDescription: String? { "The saved library changed. Retry and review it again before replacing it." }
}
