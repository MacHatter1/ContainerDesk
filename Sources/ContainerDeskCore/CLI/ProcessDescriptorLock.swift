import Foundation

/// Coordinates short descriptor creation/spawn windows with other in-process PTY launches.
public enum ProcessDescriptorLock {
    private static let storage = ProcessDescriptorLockStorage()

    public static func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return try operation()
    }
}

private final class ProcessDescriptorLockStorage: @unchecked Sendable {
    let lock = NSLock()
}
