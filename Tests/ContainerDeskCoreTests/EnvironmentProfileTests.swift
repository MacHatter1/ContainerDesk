import Foundation
import Testing
@testable import ContainerDeskCore

struct EnvironmentProfileTests {
    @Test func normalizesSubmicrosecondTimestampsForStableUnixDateRoundTrips() throws {
        let input = Date(timeIntervalSinceReferenceDate: 800_000_000.000_000_1)
        let profile = EnvironmentProfile(name: "Precise timestamp", configuration: .init(), updatedAt: input)
        #expect(profile.updatedAt == Date(timeIntervalSince1970: input.timeIntervalSince1970))
        #expect(try EnvironmentProfile.importData(profile.exportData()) == profile)
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.repository.save([profile])
        #expect(try fixture.repository.load() == [profile])
    }

    @Test func repositoryRoundTripsEveryLaunchFieldAndPrivatePermissions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = sampleProfile()
        #expect(try fixture.repository.load().isEmpty)
        try fixture.repository.save([profile])
        #expect(try fixture.repository.load() == [profile])
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.repository.storageURL.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        try fixture.repository.save([])
        #expect(try fixture.repository.load().isEmpty)
    }

    @Test func singleProfileExportRoundTripsAndStoresOnlyEnvironmentReferences() throws {
        let profile = sampleProfile()
        let data = try profile.exportData()
        #expect(try EnvironmentProfile.importData(data) == profile)
        let root = try object(data)
        let stored = try #require(root["profile"] as? [String: Any])
        #expect(stored["updatedAt"] as? Double == profile.updatedAt.timeIntervalSince1970)
        let configuration = try #require(stored["configuration"] as? [String: Any])
        #expect(configuration["requiredEnvironmentKeys"] as? [String] == ["API_TOKEN", "DATABASE_URL"])
        #expect(configuration["environmentFiles"] as? [String] == ["/tmp/local.env"])
        #expect(Set(configuration.keys) == Set(["name", "image", "command", "cpus", "memory", "platform", "ports", "volumes", "networks", "environmentFiles", "requiredEnvironmentKeys"]))
    }

    @Test func invalidSavePreservesExistingRepository() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = sampleProfile()
        try fixture.repository.save([original])
        let before = try Data(contentsOf: fixture.repository.storageURL)
        var invalid = original
        invalid.configuration.requiredEnvironmentKeys = ["API_TOKEN=secret"]
        #expect(throws: EnvironmentProfileError.self) { try fixture.repository.save([invalid]) }
        #expect(try Data(contentsOf: fixture.repository.storageURL) == before)
        #expect(try fixture.repository.load() == [original])
    }

    @Test func duplicateIdentifiersAndNormalizedNamesAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = sampleProfile()
        var duplicate = profile
        duplicate.name = "Another profile"
        #expect(throws: EnvironmentProfileError.duplicateID(profile.id)) {
            try fixture.repository.save([profile, duplicate])
        }
        duplicate.id = UUID()
        duplicate.name = "  WORKSPACE  "
        #expect(throws: EnvironmentProfileError.duplicateName(duplicate.name)) {
            try fixture.repository.save([profile, duplicate])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.repository.storageURL.path))
    }

    @Test func corruptionAndUnsupportedSchemasAreRejectedWithoutOverwritingFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.repository.save([sampleProfile()])
        var root = try object(Data(contentsOf: fixture.repository.storageURL))
        root["version"] = 2
        let future = try JSONSerialization.data(withJSONObject: root)
        try future.write(to: fixture.repository.storageURL)
        #expect(throws: EnvironmentProfileError.unsupportedSchemaVersion(2)) { try fixture.repository.load() }
        #expect(try Data(contentsOf: fixture.repository.storageURL) == future)
        let corrupt = Data("{\"profiles\": [".utf8)
        try corrupt.write(to: fixture.repository.storageURL)
        #expect(throws: EnvironmentProfileError.invalidDocument) { try fixture.repository.load() }
        #expect(try Data(contentsOf: fixture.repository.storageURL) == corrupt)
    }

    @Test func loadingAlsoRejectsDuplicateProfiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = sampleProfile()
        try fixture.repository.save([profile])
        var root = try object(Data(contentsOf: fixture.repository.storageURL))
        let entries = try #require(root["profiles"] as? [[String: Any]])
        root["profiles"] = entries + entries
        try JSONSerialization.data(withJSONObject: root).write(to: fixture.repository.storageURL)
        #expect(throws: EnvironmentProfileError.duplicateID(profile.id)) { try fixture.repository.load() }
    }

    @Test func importsRejectInlineEnvironmentFieldsAndMalformedVersions() throws {
        var root = try object(sampleProfile().exportData())
        var profile = try #require(root["profile"] as? [String: Any])
        var configuration = try #require(profile["configuration"] as? [String: Any])
        configuration["environment"] = ["API_TOKEN": "never-import-this"]
        profile["configuration"] = configuration
        root["profile"] = profile
        let withInlineValues = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: EnvironmentProfileError.invalidDocument) { try EnvironmentProfile.importData(withInlineValues) }
        root = try object(sampleProfile().exportData())
        root["version"] = true
        let booleanVersion = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: EnvironmentProfileError.invalidDocument) { try EnvironmentProfile.importData(booleanVersion) }
        root["version"] = 9
        let futureVersion = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: EnvironmentProfileError.unsupportedSchemaVersion(9)) { try EnvironmentProfile.importData(futureVersion) }
    }

    @Test func validatesProfileNamesAndEnvironmentKeySyntaxWithoutConstrainingRuntimeFormats() throws {
        var profile = sampleProfile()
        profile.name = " \n "
        #expect(throws: EnvironmentProfileError.self) { try profile.validate() }
        profile.name = "Workspace"
        for keys in [["HAS-DASH"], ["1STARTS_WITH_NUMBER"], ["KEY=value"], ["DUPLICATE", "DUPLICATE"], ["API_TOKEN\n"], ["API_TOKEN\r"], ["API_TOKEN\r\n"]] {
            profile.configuration.requiredEnvironmentKeys = keys
            #expect(throws: EnvironmentProfileError.self) { try profile.validate() }
        }
        profile.configuration.requiredEnvironmentKeys = ["_TOKEN", "api_key2"]
        profile.configuration.image = "registry.example:5000/image@sha256:abc"
        profile.configuration.memory = "1.5GiB"
        profile.configuration.platform = "linux/arm64/v8"
        try profile.validate()
    }

    @Test func importsRejectRequiredEnvironmentKeysWithTrailingLineTerminators() throws {
        for terminator in ["\n", "\r", "\r\n"] {
            var root = try object(sampleProfile().exportData())
            var profile = try #require(root["profile"] as? [String: Any])
            var configuration = try #require(profile["configuration"] as? [String: Any])
            configuration["requiredEnvironmentKeys"] = ["API_TOKEN" + terminator]
            profile["configuration"] = configuration
            root["profile"] = profile
            let data = try JSONSerialization.data(withJSONObject: root)
            #expect(throws: EnvironmentProfileError.self) { try EnvironmentProfile.importData(data) }
        }
    }

    @Test func oversizedInputsAndCollectionsAreRejectedBeforeStorageChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: EnvironmentProfileError.documentTooLarge) {
            try EnvironmentProfile.importData(Data(repeating: 32, count: 128 * 1_024 + 1))
        }
        var profile = sampleProfile()
        profile.configuration.command = String(repeating: "x", count: 32_769)
        #expect(throws: EnvironmentProfileError.self) { try fixture.repository.save([profile]) }
        let profiles = (0...200).map { EnvironmentProfile(name: "Profile \($0)", configuration: .init()) }
        #expect(throws: EnvironmentProfileError.documentTooLarge) { try fixture.repository.save(profiles) }
        #expect(!FileManager.default.fileExists(atPath: fixture.repository.storageURL.path))
    }

    @Test func repositoryRejectsOversizedRegularFilesAndNonregularFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.repository.save([])
        try Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1).write(to: fixture.repository.storageURL)
        #expect(throws: EnvironmentProfileError.documentTooLarge) { try fixture.repository.load() }
        let directoryRepository = EnvironmentProfileRepository(storageURL: fixture.directory)
        #expect(throws: EnvironmentProfileError.invalidDocument) { try directoryRepository.load() }
    }

    @Test func loadingRejectsBothExistingAndDanglingSymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent("target.json")
        let repository = EnvironmentProfileRepository(storageURL: fixture.directory.appendingPathComponent("link.json"))
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: repository.storageURL, withDestinationURL: target)
        #expect(throws: (any Error).self) { try repository.load() }
        try FileManager.default.removeItem(at: target)
        #expect(throws: (any Error).self) { try repository.load() }
    }

    @Test func savingAtomicallyReplacesSymlinkWithoutChangingItsTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent("target.json")
        let repository = EnvironmentProfileRepository(storageURL: fixture.directory.appendingPathComponent("link.json"))
        let original = Data("untouched target".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: repository.storageURL, withDestinationURL: target)
        let profile = sampleProfile()
        try repository.save([profile])
        #expect(try repository.load() == [profile])
        #expect(try Data(contentsOf: target) == original)
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.storageURL.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    }

    @Test func storageRejectsRemoteAndNonFileURLs() throws {
        for text in ["https://example.com/profiles.json", "file://example.com/profiles.json"] {
            let repository = EnvironmentProfileRepository(storageURL: try #require(URL(string: text)))
            #expect(throws: EnvironmentProfileError.invalidStorageURL) { try repository.load() }
            #expect(throws: EnvironmentProfileError.invalidStorageURL) { try repository.save([]) }
        }
    }

    private func sampleProfile() -> EnvironmentProfile {
        EnvironmentProfile(
            name: "Workspace",
            configuration: ContainerLaunchConfiguration(
                name: "workspace", image: "alpine:latest", command: "sh -c 'printf hello'", cpus: "2", memory: "2g", platform: "linux/arm64",
                ports: ["127.0.0.1:8080:80/tcp"], volumes: ["/tmp/work:/workspace:ro"], networks: ["dev"],
                environmentFiles: ["/tmp/local.env"], requiredEnvironmentKeys: ["API_TOKEN", "DATABASE_URL"]
            ),
            updatedAt: Date(timeIntervalSinceReferenceDate: 123_456_789.25)
        )
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private struct Fixture {
        let directory: URL
        let repository: EnvironmentProfileRepository

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnvironmentProfileTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            repository = EnvironmentProfileRepository(storageURL: directory.appendingPathComponent("nested/profiles.json"))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
