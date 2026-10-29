import Darwin
import Foundation

/// Synchronous local storage for a small set of reusable launch configurations.
/// Callers serialize mutations to avoid overwriting a concurrently edited collection.
public struct EnvironmentProfileRepository: Sendable {
    public let storageURL: URL

    public init(storageURL: URL = EnvironmentProfileRepository.defaultStorageURL) {
        self.storageURL = storageURL
    }

    public static var defaultStorageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("ContainerDesk/environment-profiles.json")
    }

    public func load() throws -> [EnvironmentProfile] {
        try validateStorageURL()
        // Inspect the opened file, so symlinks and concurrent path changes cannot
        // bypass the regular-file/size check. Nonblocking open also avoids FIFO hangs.
        let descriptor = try storageURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw EnvironmentProfileError.invalidStorageURL }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw EnvironmentProfileError.invalidDocument }
        guard metadata.st_size <= ProfileDocumentCoding.maximumRepositoryBytes else { throw EnvironmentProfileError.documentTooLarge }
        var data = Data()
        let maximumRead = ProfileDocumentCoding.maximumRepositoryBytes + 1
        while data.count < maximumRead {
            guard let chunk = try handle.read(upToCount: maximumRead - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= ProfileDocumentCoding.maximumRepositoryBytes else { throw EnvironmentProfileError.documentTooLarge }
        try ProfileDocumentCoding.checkShape(data, format: ProfileCollectionDocument.format, collection: true)
        let document: ProfileCollectionDocument
        do {
            document = try ProfileDocumentCoding.decoder().decode(ProfileCollectionDocument.self, from: data)
        } catch {
            throw EnvironmentProfileError.invalidDocument
        }
        try Self.validate(document.profiles)
        return document.profiles
    }

    /// Validates and encodes the complete collection before touching existing storage.
    /// The temporary file is private from creation, then atomically replaces the destination.
    public func save(_ profiles: [EnvironmentProfile]) throws {
        try validateStorageURL()
        try Self.validate(profiles)
        let data = try ProfileDocumentCoding.encoder().encode(ProfileCollectionDocument(profiles: profiles))
        guard data.count <= ProfileDocumentCoding.maximumRepositoryBytes else { throw EnvironmentProfileError.documentTooLarge }
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporaryURL = directory.appendingPathComponent(".environment-profiles-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let result = try temporaryURL.withUnsafeFileSystemRepresentation { source in
            try storageURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { throw EnvironmentProfileError.invalidStorageURL }
                return Darwin.rename(source, destination)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func validateStorageURL() throws {
        guard storageURL.isFileURL,
              storageURL.host == nil || storageURL.host == "" || storageURL.host == "localhost",
              !storageURL.path.contains("\0") else { throw EnvironmentProfileError.invalidStorageURL }
    }

    private static func validate(_ profiles: [EnvironmentProfile]) throws {
        guard profiles.count <= ProfileDocumentCoding.maximumProfiles else { throw EnvironmentProfileError.documentTooLarge }
        var identifiers: Set<UUID> = []
        var names: Set<String> = []
        for profile in profiles {
            try profile.validate()
            guard identifiers.insert(profile.id).inserted else { throw EnvironmentProfileError.duplicateID(profile.id) }
            let normalizedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(normalizedName).inserted else { throw EnvironmentProfileError.duplicateName(profile.name) }
            guard try ProfileDocumentCoding.encoder().encode(profile).count <= ProfileDocumentCoding.maximumProfileBytes else {
                throw EnvironmentProfileError.documentTooLarge
            }
        }
    }
}

private struct ProfileCollectionDocument: Codable {
    static let format = "containerdesk.environment-profiles"
    var format = Self.format
    var version = 1
    var profiles: [EnvironmentProfile]
}
