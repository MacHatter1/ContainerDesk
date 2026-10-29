import CoreFoundation
import Foundation

/// Reusable launch inputs. Environment values are supplied only when launching;
/// a profile can store file paths and required key names, never an environment dictionary.
public struct ContainerLaunchConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var image: String
    public var command: String
    public var cpus: String
    public var memory: String
    public var platform: String
    public var ports: [String]
    public var volumes: [String]
    public var networks: [String]
    public var environmentFiles: [String]
    public var requiredEnvironmentKeys: [String]

    public init(name: String = "", image: String = "", command: String = "", cpus: String = "", memory: String = "", platform: String = "", ports: [String] = [], volumes: [String] = [], networks: [String] = [], environmentFiles: [String] = [], requiredEnvironmentKeys: [String] = []) {
        self.name = name
        self.image = image
        self.command = command
        self.cpus = cpus
        self.memory = memory
        self.platform = platform
        self.ports = ports
        self.volumes = volumes
        self.networks = networks
        self.environmentFiles = environmentFiles
        self.requiredEnvironmentKeys = requiredEnvironmentKeys
    }

    public func validate() throws {
        let fields = [name, image, cpus, memory, platform]
        guard fields.allSatisfy({ $0.utf8.count <= 8_192 && !$0.contains("\0") }),
              command.utf8.count <= 32_768, !command.contains("\0") else {
            throw EnvironmentProfileError.invalidConfiguration("A launch field is too long or contains a null character.")
        }
        for entries in [ports, volumes, networks, environmentFiles] {
            guard entries.count <= 128,
                  entries.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8_192 && !$0.contains("\0") }) else {
                throw EnvironmentProfileError.invalidConfiguration("Launch lists must contain at most 128 nonempty entries of at most 8,192 bytes.")
            }
        }
        guard requiredEnvironmentKeys.count <= 128,
              requiredEnvironmentKeys.allSatisfy({ $0.utf8.count <= 256 && $0.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil }),
              Set(requiredEnvironmentKeys).count == requiredEnvironmentKeys.count else {
            throw EnvironmentProfileError.invalidConfiguration("Required environment keys must be unique names such as API_TOKEN, without values.")
        }
    }
}

public struct EnvironmentProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var configuration: ContainerLaunchConfiguration
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, configuration: ContainerLaunchConfiguration, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.configuration = configuration
        // Match the precision of v1's Unix-seconds JSON representation up front.
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970)
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 120,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              updatedAt.timeIntervalSince1970.isFinite else {
            throw EnvironmentProfileError.invalidProfile("Profile names must contain 1–120 characters without control characters, and dates must be valid.")
        }
        try configuration.validate()
    }

    /// The exported document contains references to environment files/keys only.
    public func exportData() throws -> Data {
        try validate()
        let data = try ProfileDocumentCoding.encoder().encode(SingleProfileDocument(profile: self))
        guard data.count <= ProfileDocumentCoding.maximumProfileBytes else { throw EnvironmentProfileError.documentTooLarge }
        return data
    }

    public static func importData(_ data: Data) throws -> EnvironmentProfile {
        guard data.count <= ProfileDocumentCoding.maximumProfileBytes else { throw EnvironmentProfileError.documentTooLarge }
        try ProfileDocumentCoding.checkShape(data, format: SingleProfileDocument.format, collection: false)
        let document: SingleProfileDocument
        do {
            document = try ProfileDocumentCoding.decoder().decode(SingleProfileDocument.self, from: data)
        } catch {
            throw EnvironmentProfileError.invalidDocument
        }
        try document.profile.validate()
        return document.profile
    }
}

public enum EnvironmentProfileError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfile(String)
    case invalidConfiguration(String)
    case invalidDocument
    case unsupportedSchemaVersion(Int)
    case duplicateID(UUID)
    case duplicateName(String)
    case documentTooLarge
    case invalidStorageURL

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let message), .invalidConfiguration(let message): message
        case .invalidDocument: "The environment profile document is malformed or uses an unrecognized format."
        case .unsupportedSchemaVersion(let version): "Environment profile schema version \(version) is not supported."
        case .duplicateID: "Two environment profiles have the same identifier."
        case .duplicateName(let name): "An environment profile named \"\(name)\" already exists."
        case .documentTooLarge: "The environment profile document exceeds the supported size or profile count."
        case .invalidStorageURL: "Environment profiles must be stored at a local file URL."
        }
    }
}

struct SingleProfileDocument: Codable {
    static let format = "containerdesk.environment-profile"
    var format = Self.format
    var version = 1
    var profile: EnvironmentProfile
}

enum ProfileDocumentCoding {
    static let maximumProfileBytes = 128 * 1_024
    static let maximumRepositoryBytes = 2 * 1_024 * 1_024
    static let maximumProfiles = 200

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Explicit Unix seconds make v1 JSON portable while retaining subseconds.
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Reject unknown fields as well as missing fields, including inline environment
    /// dictionaries from unrelated formats. Unsupported data is never silently dropped.
    static func checkShape(_ data: Data, format: String, collection: Bool) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["format"] as? String == format,
              let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(version.intValue) else {
            throw EnvironmentProfileError.invalidDocument
        }
        guard version.intValue == 1 else { throw EnvironmentProfileError.unsupportedSchemaVersion(version.intValue) }
        let payloadKey = collection ? "profiles" : "profile"
        guard Set(root.keys) == Set(["format", "version", payloadKey]) else { throw EnvironmentProfileError.invalidDocument }
        let profiles: [Any]
        if collection {
            guard let entries = root[payloadKey] as? [Any] else { throw EnvironmentProfileError.invalidDocument }
            guard entries.count <= maximumProfiles else { throw EnvironmentProfileError.documentTooLarge }
            profiles = entries
        } else {
            guard let entry = root[payloadKey] else { throw EnvironmentProfileError.invalidDocument }
            profiles = [entry]
        }
        let configurationKeys: Set<String> = ["name", "image", "command", "cpus", "memory", "platform", "ports", "volumes", "networks", "environmentFiles", "requiredEnvironmentKeys"]
        for entry in profiles {
            guard let profile = entry as? [String: Any],
                  Set(profile.keys) == Set(["id", "name", "configuration", "updatedAt"]),
                  let configuration = profile["configuration"] as? [String: Any],
                  Set(configuration.keys) == configurationKeys else { throw EnvironmentProfileError.invalidDocument }
        }
    }
}
