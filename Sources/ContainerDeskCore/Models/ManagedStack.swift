import Foundation

/// A user-owned collection of container identities in one runtime.
public struct ManagedStack: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var containerIDs: Set<String>

    public init(id: UUID = UUID(), name: String, containerIDs: Set<String> = []) {
        self.id = id
        self.name = name
        self.containerIDs = containerIDs
    }

    public var workspaceID: String { "managed:\(id.uuidString)" }
}

public struct ManagedStackCollection: Codable, Sendable, Equatable {
    public var stacks: [ManagedStack] = []
    /// Explicit removals stay ungrouped instead of immediately reappearing in an
    /// automatically inferred or label-discovered stack.
    public var ungroupedContainerIDs: Set<String> = []

    public init() {}
}

public struct ManagedStackLibrary: Codable, Sendable, Equatable {
    public var version = 1
    public var runtimes: [String: ManagedStackCollection] = [:]

    public init() {}

    public func validate() throws {
        guard version == 1 else { throw ManagedStackError.unsupportedVersion }
        guard runtimes.count <= 100 else { throw ManagedStackError.tooLarge }
        for (runtime, collection) in runtimes {
            guard !runtime.isEmpty, runtime.count <= 4096,
                  collection.stacks.count <= 200,
                  collection.ungroupedContainerIDs.count <= 10_000 else { throw ManagedStackError.tooLarge }
            var identifiers: Set<UUID> = []
            var names: Set<String> = []
            var members: Set<String> = []
            for stack in collection.stacks {
                let name = stack.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name == stack.name, name.count <= 120,
                      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw ManagedStackError.invalidName
                }
                guard identifiers.insert(stack.id).inserted else { throw ManagedStackError.invalidDocument }
                let key = name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard names.insert(key).inserted else { throw ManagedStackError.duplicateName(name) }
                guard stack.containerIDs.count <= 2000 else { throw ManagedStackError.tooLarge }
                guard members.isDisjoint(with: stack.containerIDs) else { throw ManagedStackError.duplicateMembership }
                members.formUnion(stack.containerIDs)
            }
            guard members.isDisjoint(with: collection.ungroupedContainerIDs) else { throw ManagedStackError.duplicateMembership }
            for id in members.union(collection.ungroupedContainerIDs) {
                guard !id.isEmpty, id.count <= 1024, !id.contains("\0") else { throw ManagedStackError.invalidDocument }
            }
        }
    }
}

public enum ManagedStackError: Error, LocalizedError, Equatable {
    case invalidName, invalidDocument, unsupportedVersion, tooLarge, duplicateMembership
    case duplicateName(String)
    case loadFailed, libraryChanged, staleStack, runtimeChanged
    case launchedButNotAssigned(container: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a stack name of 1–120 characters without line breaks."
        case .invalidDocument: "The saved stack library is malformed."
        case .unsupportedVersion: "The saved stack library uses an unsupported version."
        case .tooLarge: "The saved stack library exceeds its supported size."
        case .duplicateMembership: "A container can belong to only one saved stack."
        case .duplicateName(let name): "A saved stack named \"\(name)\" already exists."
        case .loadFailed: "Reload the stack library successfully before changing saved stacks."
        case .libraryChanged: "The saved stack library changed elsewhere. Reload it and review your changes again."
        case .staleStack: "This stack changed or was deleted. Reopen it to review its latest membership."
        case .runtimeChanged: "The runtime changed. Reopen the stack in the selected runtime."
        case .launchedButNotAssigned(let container, let reason): "Container \"\(container)\" launched, but could not be added to the stack: \(reason) Add it using Manage Containers."
        }
    }
}
