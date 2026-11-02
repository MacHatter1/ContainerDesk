import Foundation

enum LimitsQuitWaitResult: Equatable { case ready, timedOut, cancelled }

@MainActor enum LimitsQuitWaiter {
    /// Never abandon an active replacement to satisfy Quit. A bounded wait can
    /// instead decline termination, leaving recovery running in the open app.
    static func wait(timeout: Duration = .seconds(30), isRecovering: () -> Bool) async -> LimitsQuitWaitResult {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if !isRecovering() { return .ready }
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero { return .timedOut }
            do { try await Task.sleep(for: min(.milliseconds(100), remaining)) }
            catch { return .cancelled }
        }
        return .cancelled
    }
}
