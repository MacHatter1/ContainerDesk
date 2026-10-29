import ContainerDeskCore
import Foundation
import Observation

@MainActor
@Observable
public final class EnvironmentProfilesStore {
    public private(set) var profiles: [EnvironmentProfile] = []
    public private(set) var loadError: String?

    @ObservationIgnored private let repository: EnvironmentProfileRepository

    public init(repository: EnvironmentProfileRepository = .init()) {
        self.repository = repository
        reload()
    }

    /// A failed read must be retried explicitly before any write can proceed.
    public func reload() {
        do {
            profiles = try repository.load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    public func save(name: String, configuration: ContainerLaunchConfiguration, replacing original: EnvironmentProfile? = nil) throws -> EnvironmentProfile {
        try ensureWritable()
        if let original {
            guard profiles.first(where: { $0.id == original.id }) == original else {
                throw EnvironmentProfilesStoreError.staleProfile
            }
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profiles.contains(where: { $0.id != original?.id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            throw EnvironmentProfileError.duplicateName(trimmedName)
        }
        // Match the repository's Unix timestamp conversion before retaining the
        // snapshot; adding the epoch offset can round fractional Date precision.
        let timestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
        let profile = EnvironmentProfile(id: original?.id ?? UUID(), name: trimmedName, configuration: configuration, updatedAt: timestamp)
        try profile.validate()
        try ContainerLaunchRequestBuilder.validate(configuration: configuration)
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        try repository.save(updated)
        profiles = updated
        return profile
    }

    public func delete(_ original: EnvironmentProfile) throws {
        try ensureWritable()
        guard profiles.first(where: { $0.id == original.id }) == original else {
            throw EnvironmentProfilesStoreError.staleProfile
        }
        let updated = profiles.filter { $0.id != original.id }
        try repository.save(updated)
        profiles = updated
    }

    /// Imports always create a separate profile. Name collisions receive an
    /// explicit "(Imported 2)" suffix, incremented until the name is available.
    @discardableResult
    public func importProfile(data: Data) throws -> EnvironmentProfile {
        let imported = try EnvironmentProfile.importData(data)
        let baseName = imported.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = baseName
        var suffixNumber = 2
        while profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let suffix = " (Imported \(suffixNumber))"
            name = String(baseName.prefix(120 - suffix.count)) + suffix
            suffixNumber += 1
        }
        return try save(name: name, configuration: imported.configuration)
    }

    private func ensureWritable() throws {
        guard loadError == nil else { throw EnvironmentProfilesStoreError.loadFailed }
        let persisted: [EnvironmentProfile]
        do {
            persisted = try repository.load()
        } catch {
            loadError = error.localizedDescription
            throw EnvironmentProfilesStoreError.loadFailed
        }
        guard persisted == profiles else {
            loadError = "The saved profiles changed outside this window. Reload the library before making changes."
            throw EnvironmentProfilesStoreError.libraryChanged
        }
    }
}

public enum EnvironmentProfilesStoreError: Error, LocalizedError, Equatable {
    case loadFailed
    case libraryChanged
    case staleProfile

    public var errorDescription: String? {
        switch self {
        case .loadFailed: "The profile library could not be read. Reload it successfully before making changes."
        case .libraryChanged: "The saved profile library changed. Reload it and review your changes again."
        case .staleProfile: "This profile changed or was deleted while it was open. Reopen it from the library to review the latest version."
        }
    }
}
