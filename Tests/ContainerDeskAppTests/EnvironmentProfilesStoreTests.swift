import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

@MainActor
struct EnvironmentProfilesStoreTests {
    @Test func persistsUpdatesAndDeletesWithoutChangingOtherProfiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EnvironmentProfileRepository(storageURL: directory.appendingPathComponent("profiles.json"))
        let store = EnvironmentProfilesStore(repository: repository)
        #expect(store.profiles.isEmpty)
        #expect(store.loadError == nil)
        #expect(!FileManager.default.fileExists(atPath: repository.storageURL.path))

        let original = try store.save(name: "  Development  ", configuration: configuration())
        let second = try store.save(name: "Preview", configuration: configuration())
        var changedConfiguration = original.configuration
        changedConfiguration.cpus = "2"
        let updated = try store.save(name: "Development", configuration: changedConfiguration, replacing: original)
        #expect(updated.id == original.id)
        #expect(try repository.load() == [updated, second])
        #expect(EnvironmentProfilesStore(repository: repository).profiles == [updated, second])

        try store.delete(updated)
        #expect(store.profiles == [second])
        #expect(try repository.load() == [second])
    }

    @Test func importsWithFreshIdentifiersAndUniqueNames() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EnvironmentProfilesStore(repository: .init(storageURL: directory.appendingPathComponent("profiles.json")))
        let original = try store.save(name: "Development", configuration: configuration())
        let data = try original.exportData()

        let firstImport = try store.importProfile(data: data)
        let secondImport = try store.importProfile(data: data)

        #expect(firstImport.id != original.id)
        #expect(secondImport.id != original.id)
        #expect(firstImport.id != secondImport.id)
        #expect(firstImport.name == "Development (Imported 2)")
        #expect(secondImport.name == "Development (Imported 3)")
        #expect(firstImport.configuration == original.configuration)
        #expect(store.profiles.count == 3)
    }

    @Test func savingReviewedCopyCreatesFreshIDAndPreservesMountReferences() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EnvironmentProfilesStore(repository: .init(storageURL: directory.appendingPathComponent("profiles.json")))
        let original = try store.save(name: "Development", configuration: configuration())
        var reviewedCopy = original.configuration
        reviewedCopy.name = ""
        let duplicate = try store.save(name: "Development Copy", configuration: reviewedCopy)

        #expect(duplicate.id != original.id)
        #expect(duplicate.configuration.name.isEmpty)
        #expect(duplicate.configuration.volumes == original.configuration.volumes)
        #expect(duplicate.configuration.environmentFiles == original.configuration.environmentFiles)
        #expect(store.profiles.first == original)
    }

    @Test func refusesStaleUpdatesAndDeletes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EnvironmentProfileRepository(storageURL: directory.appendingPathComponent("profiles.json"))
        let store = EnvironmentProfilesStore(repository: repository)
        let original = try store.save(name: "Development", configuration: configuration())
        var changed = original.configuration
        changed.memory = "512M"
        let current = try store.save(name: "Current", configuration: changed, replacing: original)

        #expect(throws: EnvironmentProfilesStoreError.staleProfile) {
            try store.save(name: "Stale", configuration: original.configuration, replacing: original)
        }
        #expect(throws: EnvironmentProfilesStoreError.staleProfile) { try store.delete(original) }
        #expect(store.profiles == [current])
        #expect(try repository.load() == [current])

        try store.delete(current)
        #expect(throws: EnvironmentProfilesStoreError.staleProfile) {
            try store.save(name: "Resurrected", configuration: current.configuration, replacing: current)
        }
        #expect(store.profiles.isEmpty)
    }

    @Test func failedInitialLoadPreventsOverwriteUntilExplicitReload() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("profiles.json")
        let corrupt = Data("not a profile document".utf8)
        try corrupt.write(to: url)
        let repository = EnvironmentProfileRepository(storageURL: url)
        let store = EnvironmentProfilesStore(repository: repository)
        #expect(store.loadError != nil)

        #expect(throws: EnvironmentProfilesStoreError.loadFailed) {
            try store.save(name: "New", configuration: configuration())
        }
        #expect(try Data(contentsOf: url) == corrupt)
        let recovered = EnvironmentProfile(name: "Recovered", configuration: configuration())
        try repository.save([recovered])
        #expect(throws: EnvironmentProfilesStoreError.loadFailed) {
            try store.save(name: "Still Blocked", configuration: configuration())
        }

        store.reload()
        #expect(store.loadError == nil)
        #expect(store.profiles == [recovered])
        let saved = try store.save(name: "New", configuration: configuration())
        #expect(try repository.load() == [recovered, saved])
    }

    @Test func obstructedStoragePathRequiresExplicitReloadAfterRepair() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("blocked")
        try Data("file obstructs the destination directory".utf8).write(to: blockedParent)
        let repository = EnvironmentProfileRepository(storageURL: blockedParent.appendingPathComponent("profiles.json"))
        let store = EnvironmentProfilesStore(repository: repository)

        #expect(throws: EnvironmentProfilesStoreError.loadFailed) { try store.save(name: "Development", configuration: configuration()) }
        #expect(store.profiles.isEmpty)
        #expect(store.loadError != nil)

        try FileManager.default.removeItem(at: blockedParent)
        #expect(throws: EnvironmentProfilesStoreError.loadFailed) { try store.save(name: "Development", configuration: configuration()) }
        store.reload()
        #expect(store.loadError == nil)
        let saved = try store.save(name: "Development", configuration: configuration())
        #expect(store.profiles == [saved])
        #expect(try repository.load() == [saved])
    }

    @Test func repositorySaveFailureLeavesMemoryAndDiskUnchanged() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EnvironmentProfileRepository(storageURL: directory.appendingPathComponent("profiles.json"))
        let originals = (0..<200).map { EnvironmentProfile(name: "Profile \($0)", configuration: configuration()) }
        try repository.save(originals)
        let store = EnvironmentProfilesStore(repository: repository)
        #expect(store.loadError == nil)

        // Exceed the repository's collection limit after its read succeeds.
        #expect(throws: EnvironmentProfileError.documentTooLarge) {
            try store.save(name: "Over Limit", configuration: configuration())
        }
        #expect(store.profiles == originals)
        #expect(store.loadError == nil)
        #expect(try repository.load() == originals)
    }

    @Test func externalEditsRequireReloadAndCannotBeOverwritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EnvironmentProfileRepository(storageURL: directory.appendingPathComponent("profiles.json"))
        let first = EnvironmentProfilesStore(repository: repository)
        let original = try first.save(name: "Original", configuration: configuration())
        let second = EnvironmentProfilesStore(repository: repository)
        let added = try second.save(name: "Added Elsewhere", configuration: configuration())

        #expect(throws: EnvironmentProfilesStoreError.libraryChanged) { try first.delete(original) }
        #expect(first.profiles == [original])
        #expect(first.loadError != nil)
        #expect(try repository.load() == [original, added])
        first.reload()
        #expect(first.profiles == [original, added])
        try first.delete(original)
        #expect(try repository.load() == [added])
    }

    @Test func rejectsInvalidLaunchAndDuplicateNamesWithoutWriting() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EnvironmentProfileRepository(storageURL: directory.appendingPathComponent("profiles.json"))
        let store = EnvironmentProfilesStore(repository: repository)
        let original = try store.save(name: "Development", configuration: configuration())

        #expect(throws: (any Error).self) { try store.save(name: "development", configuration: configuration()) }
        #expect(throws: (any Error).self) { try store.save(name: "Missing Image", configuration: .init()) }
        #expect(throws: (any Error).self) { try store.importProfile(data: Data("{}".utf8)) }
        #expect(store.profiles == [original])
        #expect(try repository.load() == [original])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EnvironmentProfilesStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func configuration() -> ContainerLaunchConfiguration {
        ContainerLaunchConfiguration(
            name: "development",
            image: "docker.io/library/alpine:latest",
            ports: ["8080:80"],
            volumes: ["development-data:/data"],
            environmentFiles: ["/nonexistent/local-development.env"],
            requiredEnvironmentKeys: ["API_TOKEN"]
        )
    }
}
