import CryptoKit
import Darwin
import Foundation

public enum LimitsRecoveryOutcome: String, Codable, Sendable {
    case inProgress, updated, rolledBack, recoveryNeeded
}

/// This marker contains no launch settings or credentials. Absence/unknown versions mean keep.
struct LimitsRecoveryState: Codable {
    var version = 1
    let sessionID: String
    let containerID: String
    let createdAt: Date
    var outcome: LimitsRecoveryOutcome
    static let filename = "session-state.json"

    static func read(at directory: URL) -> Self? { readRecord(at: directory)?.state }

    static func readRecord(at directory: URL) -> (state: Self, data: Data)? {
        let fd = open(directory.appendingPathComponent(filename).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 4_096,
              let data = try? handle.read(upToCount: 4_097), data.count <= 4_096,
              let state = try? JSONDecoder().decode(Self.self, from: data), state.version == 1,
              state.sessionID == directory.lastPathComponent else { return nil }
        return (state, data)
    }

    func write(to directory: URL) throws {
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw LimitsRecoveryError.unsafeSession }
        defer { close(directoryFD) }
        let temporary = "state-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LimitsRecoveryError.unsafeSession }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        let data = try JSONEncoder().encode(self)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw LimitsRecoveryError.unsafeSession }
                offset += written
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, Self.filename) == 0,
              fsync(directoryFD) == 0 else { throw LimitsRecoveryError.unsafeSession }
    }

    static func record(_ result: ContainerLimitsApplyResult) {
        let directory: URL
        let outcome: LimitsRecoveryOutcome
        switch result {
        case .unchanged: return
        case .updated(let url): directory = url; outcome = .updated
        case .rolledBack(let url, _): directory = url; outcome = .rolledBack
        case .recoveryNeeded(let url, _): directory = url; outcome = .recoveryNeeded
        }
        guard var state = read(at: directory) else { return }
        state.outcome = outcome
        // Failed persistence leaves inProgress (or no recognised marker), which is never deletable.
        try? state.write(to: directory)
    }
}

struct LimitsRecoveryInventory: Sendable {
    let referencedFiles: [URL]
    let complete: Bool
}

protocol LimitsRecoveryInventoryReading: Sendable {
    func inventory() async throws -> LimitsRecoveryInventory
}

public struct LimitsRecoverySession: Identifiable, Sendable, Equatable {
    public var id: String { directory.lastPathComponent }
    public let directory: URL
    public let containerID: String?
    public let outcome: LimitsRecoveryOutcome?
    public let allocatedBytes: Int64
    public let keepReason: String?
    public var canRemove: Bool { keepReason == nil }
    fileprivate let directoryStamp: RecoveryFileStamp
    fileprivate let fileStamps: [RecoveryFileStamp]
    fileprivate let markerDigest: String?
}

public struct LimitsRecoveryRemoval: Sendable {
    public let sessionID: String
    public let removed: Bool
    public let message: String
}

public enum LimitsRecoveryError: LocalizedError {
    case incompleteInventory, unsafeSession, busy
    public var errorDescription: String? {
        switch self {
        case .incompleteInventory: "A complete inventory of all containers and their runtime files is required. No recovery sessions were removed."
        case .unsafeSession: "A recovery directory or file changed or could not be verified. Scan again before removing it."
        case .busy: "Wait for the limits change or recovery cleanup to finish."
        }
    }
}

/// Explicit, reviewed cleanup only. In-progress, unknown and recovery-needed sessions are always retained.
public actor ContainerLimitsRecoveryService {
    public nonisolated let directory: URL
    private let reader: any LimitsRecoveryInventoryReading
    private var removing = false

    public init(client: any ContainerClient = ProcessContainerClient(), directory: URL? = nil) {
        self.directory = (directory ?? ContainerLimitsService.defaultRecoveryDirectory()).standardizedFileURL
        self.reader = AppleLimitsRecoveryInventory(cli: client)
    }

    init(directory: URL, reader: any LimitsRecoveryInventoryReading) {
        self.directory = directory.standardizedFileURL
        self.reader = reader
    }

    public func scan() async throws -> [LimitsRecoverySession] {
        let inventory = try await reader.inventory()
        guard inventory.complete else { throw LimitsRecoveryError.incompleteInventory }
        try Task.checkCancellation()
        return try sessions(references: inventory.referencedFiles)
    }

    public func remove(_ reviewed: [LimitsRecoverySession]) async throws -> [LimitsRecoveryRemoval] {
        guard !removing else { throw LimitsRecoveryError.busy }
        removing = true
        defer { removing = false }
        // Inventory failure/incompleteness aborts the entire batch before any unlink.
        let inventory = try await reader.inventory()
        guard inventory.complete else { throw LimitsRecoveryError.incompleteInventory }
        try Task.checkCancellation()
        try validateRoot()
        var results: [LimitsRecoveryRemoval] = []
        var seen = Set<String>()
        for review in reviewed where seen.insert(review.id).inserted {
            do {
                guard review.canRemove,
                      review.directory.deletingLastPathComponent().standardizedFileURL.path == directory.path,
                      let fresh = try session(at: review.directory, references: inventory.referencedFiles),
                      sameReview(fresh, review), fresh.canRemove else { throw LimitsRecoveryError.unsafeSession }
                try unlinkVerified(fresh)
                results.append(.init(sessionID: review.id, removed: true, message: "Removed"))
            } catch {
                results.append(.init(sessionID: review.id, removed: false, message: "Kept or partially removed: \(error.localizedDescription)"))
            }
        }
        return results
    }

    private func validateRoot() throws {
        guard directory.isFileURL, directory.resolvingSymlinksInPath().path == directory.path else { throw LimitsRecoveryError.unsafeSession }
        if FileManager.default.fileExists(atPath: directory.path) {
            let stamp = try RecoveryFileStamp.read(directory)
            guard stamp.isDirectory, stamp.owner == geteuid() else { throw LimitsRecoveryError.unsafeSession }
        }
    }

    private func sessions(references: [URL]) throws -> [LimitsRecoverySession] {
        try validateRoot()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { try session(at: $0, references: references) }.sorted { $0.id < $1.id }
    }

    private func session(at url: URL, references: [URL]) throws -> LimitsRecoverySession? {
        guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
        let directoryStamp = try RecoveryFileStamp.read(url)
        guard directoryStamp.isDirectory else { return nil }
        let record = LimitsRecoveryState.readRecord(at: url)
        let state = record?.state
        let knownFiles: Set<String> = ["rootfs.ext4", "initfs.ext4", "kernel.bin", "recovery.json", LimitsRecoveryState.filename]
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        let stamps = try entries.map(RecoveryFileStamp.read).sorted { $0.name < $1.name }
        let bytes = stamps.reduce(Int64(0)) { sum, file in
            let (total, overflow) = sum.addingReportingOverflow(file.allocatedBytes)
            return overflow ? Int64.max : total
        }
        let caseSensitive = (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == true
        func pathKey(_ path: String) -> String { caseSensitive ? path : path.lowercased() }
        let resolved = pathKey(url.resolvingSymlinksInPath().path)
        let referenced = references.contains { reference in
            let original = reference.resolvingSymlinksInPath().standardizedFileURL.path
            let path = pathKey(original)
            if path == resolved || path.hasPrefix(resolved + "/") { return true }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: original, isDirectory: &isDirectory) && isDirectory.boolValue && resolved.hasPrefix(path.hasSuffix("/") ? path : path + "/")
        }
        let reason: String?
        if state == nil { reason = "Missing or unrecognised outcome; retained for recovery." }
        else if state?.outcome == .inProgress { reason = "In progress or interrupted; retained for recovery." }
        else if state?.outcome == .recoveryNeeded { reason = "Manual recovery is needed; this may be the only copy." }
        else if referenced { reason = "Referenced by a current container, including stopped containers." }
        else if directoryStamp.owner != geteuid() || !stamps.allSatisfy({ $0.isRegular && $0.owner == geteuid() && knownFiles.contains($0.name) }) {
            reason = "Unrecognised or unsafe session files; retained."
        } else { reason = nil }
        let marker = record?.data
        return .init(directory: url, containerID: state?.containerID, outcome: state?.outcome, allocatedBytes: bytes,
                     keepReason: reason, directoryStamp: directoryStamp, fileStamps: stamps,
                     markerDigest: marker.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
    }

    private func sameReview(_ fresh: LimitsRecoverySession, _ reviewed: LimitsRecoverySession) -> Bool {
        fresh.directory.path == reviewed.directory.path && fresh.markerDigest == reviewed.markerDigest
            && fresh.outcome == reviewed.outcome && fresh.keepReason == reviewed.keepReason
            && fresh.directoryStamp.sameIdentity(as: reviewed.directoryStamp)
            && fresh.fileStamps.count == reviewed.fileStamps.count
            && zip(fresh.fileStamps, reviewed.fileStamps).allSatisfy { pair in pair.0.sameIdentity(as: pair.1) }
    }

    private func unlinkVerified(_ session: LimitsRecoverySession) throws {
        // Use directory descriptors and unlink known files individually; never recursively
        // follow a swapped directory/symlink or remove an unexpected file added after review.
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw LimitsRecoveryError.unsafeSession }
        defer { close(rootFD) }
        let sessionFD = openat(rootFD, session.id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sessionFD >= 0 else { throw LimitsRecoveryError.unsafeSession }
        defer { close(sessionFD) }
        var info = stat()
        guard fstat(sessionFD, &info) == 0, session.directoryStamp.matches(info) else { throw LimitsRecoveryError.unsafeSession }
        for file in session.fileStamps {
            guard fstatat(sessionFD, file.name, &info, AT_SYMLINK_NOFOLLOW) == 0, file.matches(info) else { throw LimitsRecoveryError.unsafeSession }
        }
        let files = session.fileStamps.sorted { ($0.name == LimitsRecoveryState.filename ? 1 : 0) < ($1.name == LimitsRecoveryState.filename ? 1 : 0) }
        for file in files {
            guard unlinkat(sessionFD, file.name, 0) == 0 else { throw LimitsRecoveryError.unsafeSession }
        }
        guard fsync(sessionFD) == 0,
              fstatat(rootFD, session.id, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_ino == session.directoryStamp.inode, info.st_dev == session.directoryStamp.device,
              unlinkat(rootFD, session.id, AT_REMOVEDIR) == 0, fsync(rootFD) == 0 else { throw LimitsRecoveryError.unsafeSession }
    }
}

fileprivate struct RecoveryFileStamp: Equatable, Sendable {
    let name: String
    let inode: ino_t
    let device: dev_t
    let owner: uid_t
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let allocatedBytes: Int64
    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    var isRegular: Bool { mode & S_IFMT == S_IFREG }

    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw LimitsRecoveryError.unsafeSession }
        return Self(name: url.lastPathComponent, info: info)
    }
    init(name: String, info: stat) {
        self.name = name; inode = info.st_ino; device = info.st_dev; owner = info.st_uid; mode = info.st_mode
        size = info.st_size; modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
        let (bytes, overflow) = Int64(max(0, info.st_blocks)).multipliedReportingOverflow(by: 512)
        allocatedBytes = overflow ? Int64.max : bytes
    }
    func sameIdentity(as other: Self) -> Bool {
        name == other.name && inode == other.inode && device == other.device && owner == other.owner && mode == other.mode
            && size == other.size && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
    func matches(_ info: stat) -> Bool { sameIdentity(as: Self(name: name, info: info)) }
}
