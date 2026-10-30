import Foundation
import Observation

struct SavedComposeProject: Codable, Identifiable, Hashable {
    var id: String { fileURL.absoluteString }
    var fileURL: URL
    var name: String
}

/// One library for every window. Each write also merges the latest persisted document.
@MainActor @Observable
final class PluginLibraryStore {
    private(set) var projects: [SavedComposeProject]
    private(set) var clusterNames: [String]
    private let defaults: UserDefaults
    private static let composeKey = "containerdesk.composeProjects.v1"
    private static let clusterKey = "containerdesk.k8sTrackedNames.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        projects = Self.read([SavedComposeProject].self, key: Self.composeKey, defaults: defaults) ?? []
        clusterNames = Self.read([String].self, key: Self.clusterKey, defaults: defaults) ?? []
    }

    @discardableResult func addProject(_ url: URL, name: String) -> SavedComposeProject {
        reloadProjects()
        let project = SavedComposeProject(fileURL: url.standardizedFileURL, name: name)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.insert(project, at: 0) }
        write(projects, key: Self.composeKey)
        return project
    }

    func renameProject(id: String, name: String) {
        reloadProjects()
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
        write(projects, key: Self.composeKey)
    }

    func forgetProject(id: String) {
        reloadProjects()
        projects.removeAll { $0.id == id }
        write(projects, key: Self.composeKey)
    }

    func rememberCluster(_ name: String) {
        clusterNames = Self.read([String].self, key: Self.clusterKey, defaults: defaults) ?? []
        if !clusterNames.contains(name) { clusterNames.append(name) }
        write(clusterNames, key: Self.clusterKey)
    }

    func forgetCluster(_ name: String) {
        clusterNames = Self.read([String].self, key: Self.clusterKey, defaults: defaults) ?? []
        clusterNames.removeAll { $0 == name }
        write(clusterNames, key: Self.clusterKey)
    }

    private func reloadProjects() { projects = Self.read([SavedComposeProject].self, key: Self.composeKey, defaults: defaults) ?? [] }
    private static func read<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        defaults.string(forKey: key).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    private func write<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return }
        defaults.set(string, forKey: key)
    }
}
