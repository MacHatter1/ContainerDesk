import Foundation
import Observation
import ContainerDeskCore

struct SystemStopReview {
    let runtime: AppStore.ReviewedRuntime
    let request = CommandRequest(arguments: ["system", "stop"], captureLimit: 500_000, suppressOutputEvents: true)
}

struct SystemDNSRemovalReview {
    let domainName: String
    let action: AppStore.ReviewedDNSAction

    @MainActor init(domain: String, store: AppStore) throws {
        domainName = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        action = try store.reviewPrivilegedDNS(.delete(domainName: domainName))
    }
}

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

    func reviewDNSRemoval(domain: String, store: AppStore) -> SystemDNSRemovalReview? {
        guard !isRunning else { return nil }
        do {
            let review = try SystemDNSRemovalReview(domain: domain, store: store)
            error = nil
            return review
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
