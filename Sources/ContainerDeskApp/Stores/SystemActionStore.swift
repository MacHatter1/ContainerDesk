import Foundation
import Observation

/// An administrative action owns its busy state through its post-action refresh.
@MainActor @Observable
final class SystemActionStore {
    private(set) var isRunning = false
    private(set) var error: String?

    @discardableResult
    func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !isRunning, !Task.isCancelled else { return false }
        isRunning = true
        error = nil
        defer { isRunning = false }
        do { try await operation(); return true }
        catch { self.error = error.localizedDescription; return false }
    }

    func clearError() { if !isRunning { error = nil } }
}
