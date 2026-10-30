import ContainerDeskCore
import Foundation
import Observation

@MainActor
@Observable
public final class ManagedStacksStore {
    public private(set) var collection = ManagedStackCollection()
    public private(set) var loadError: String?
    public private(set) var runtimeScope: String
    public var stacks: [ManagedStack] { collection.stacks }

    @ObservationIgnored private let repository: ManagedStackRepository
    @ObservationIgnored private var library = ManagedStackLibrary()

    public init(repository: ManagedStackRepository = .init(), cliPath: String? = nil) {
        self.repository = repository
        runtimeScope = Self.scope(for: cliPath)
        reload()
    }

    public func setRuntime(cliPath: String?) {
        runtimeScope = Self.scope(for: cliPath)
        collection = ManagedStackCollection()
        reload()
    }

    public func reload() {
        do {
            let loaded = try repository.load()
            library = loaded
            collection = loaded.runtimes[runtimeScope] ?? ManagedStackCollection()
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    /// One atomic membership edit moves selected containers out of other saved
    /// stacks and leaves removed members explicitly ungrouped.
    @discardableResult
    public func save(name: String, containerIDs: Set<String>, replacing original: ManagedStack? = nil) throws -> ManagedStack {
        try ensureWritable()
        if let original, !stacks.contains(original) { throw ManagedStackError.staleStack }
        let stack = ManagedStack(id: original?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), containerIDs: containerIDs)
        var updated = collection
        for index in updated.stacks.indices { updated.stacks[index].containerIDs.subtract(containerIDs) }
        if let original, let index = updated.stacks.firstIndex(where: { $0.id == original.id }) {
            updated.ungroupedContainerIDs.formUnion(original.containerIDs.subtracting(containerIDs))
            updated.stacks[index] = stack
        } else { updated.stacks.append(stack) }
        updated.ungroupedContainerIDs.subtract(containerIDs)
        try commit(updated)
        return stack
    }

    public func delete(_ original: ManagedStack) throws {
        try ensureWritable()
        guard stacks.contains(original) else { throw ManagedStackError.staleStack }
        var updated = collection
        updated.stacks.removeAll { $0.id == original.id }
        updated.ungroupedContainerIDs.formUnion(original.containerIDs)
        try commit(updated)
    }

    public func assign(containerID: String, to stackID: UUID) throws {
        try validateTarget(stackID)
        guard let stack = stacks.first(where: { $0.id == stackID }) else { throw ManagedStackError.staleStack }
        _ = try save(name: stack.name, containerIDs: stack.containerIDs.union([containerID]), replacing: stack)
    }

    public func remove(containerID: String, from original: ManagedStack) throws {
        _ = try save(name: original.name, containerIDs: original.containerIDs.subtracting([containerID]), replacing: original)
    }

    public func validateTarget(_ stackID: UUID) throws {
        try ensureWritable()
        guard stacks.contains(where: { $0.id == stackID }) else { throw ManagedStackError.staleStack }
    }

    private func ensureWritable() throws {
        guard loadError == nil else { throw ManagedStackError.loadFailed }
        let persisted: ManagedStackLibrary
        do { persisted = try repository.load() }
        catch {
            loadError = error.localizedDescription
            throw ManagedStackError.loadFailed
        }
        guard persisted == library else {
            loadError = ManagedStackError.libraryChanged.localizedDescription
            throw ManagedStackError.libraryChanged
        }
    }

    private func commit(_ updated: ManagedStackCollection) throws {
        var document = library
        document.runtimes[runtimeScope] = updated
        try repository.save(document)
        library = document
        collection = updated
    }

    private static func scope(for cliPath: String?) -> String {
        guard let cliPath, !cliPath.isEmpty else { return "default" }
        return "cli:\((cliPath as NSString).expandingTildeInPath)"
    }
}
