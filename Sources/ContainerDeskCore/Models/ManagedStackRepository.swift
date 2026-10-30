import Darwin
import Foundation

/// Small, versioned local documents; atomic replacement preserves the last good
/// library on failed writes. Runtime labels and containers are never mutated.
public struct ManagedStackRepository: Sendable {
    public let storageURL: URL
    private static let maximumBytes = 2 * 1024 * 1024

    public init(storageURL: URL = ManagedStackRepository.defaultStorageURL) {
        self.storageURL = storageURL
    }

    public static var defaultStorageURL: URL {
        if let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--stack-library-path=") }) {
            return URL(filePath: String(path.dropFirst("--stack-library-path=".count)))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("ContainerDesk/stacks.json")
    }

    public func load() throws -> ManagedStackLibrary {
        try validateURL()
        let fd = Darwin.open(storageURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return ManagedStackLibrary() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard Darwin.fstat(fd, &metadata) == 0 else { throw POSIXError(.EIO) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ManagedStackError.invalidDocument }
        guard metadata.st_size <= Self.maximumBytes else { throw ManagedStackError.tooLarge }
        var data = Data()
        while data.count <= Self.maximumBytes {
            guard let chunk = try file.read(upToCount: Self.maximumBytes + 1 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumBytes else { throw ManagedStackError.tooLarge }
        let library: ManagedStackLibrary
        do { library = try JSONDecoder().decode(ManagedStackLibrary.self, from: data) }
        catch { throw ManagedStackError.invalidDocument }
        try library.validate()
        return library
    }

    public func save(_ library: ManagedStackLibrary) throws {
        try validateURL()
        try library.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        guard data.count <= Self.maximumBytes else { throw ManagedStackError.tooLarge }
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".stacks-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        guard Darwin.rename(temporary.path, storageURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func validateURL() throws {
        guard storageURL.isFileURL,
              storageURL.host == nil || storageURL.host == "" || storageURL.host == "localhost",
              !storageURL.path.contains("\0") else { throw ManagedStackError.invalidDocument }
    }
}
