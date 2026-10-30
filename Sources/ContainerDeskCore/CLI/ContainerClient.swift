import Foundation

public protocol ContainerClient: Sendable {
    /// Process-backed implementations return only after owned process cleanup,
    /// including when their caller is cancelled.
    func run(_ request: CommandRequest) async throws -> CommandResult
    /// Iteration cancellation can precede producer cleanup. Owners that need
    /// quiescence use launch and await the returned handle's shutdown.
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error>
    /// Process-backed clients must wait for their owned child and pipe drains in
    /// the returned handle's terminateAndWait operation.
    func launch(_ request: CommandRequest) throws -> ManagedProcessExecution
}

public extension ContainerClient {
    /// Stream-only transports have no owned OS process to reap. Their stream's
    /// termination handler remains responsible for cancelling transport work.
    func launch(_ request: CommandRequest) throws -> ManagedProcessExecution {
        ManagedProcessExecution(events: stream(request), isLeaderRunning: { false }, terminateAndWait: {})
    }
}
