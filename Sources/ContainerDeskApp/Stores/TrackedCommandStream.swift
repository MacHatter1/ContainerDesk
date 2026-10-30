import ContainerDeskCore
import Foundation

/// Consumers can stop reading immediately, but serialized owners await cleanup
/// before allowing another mutation. Completion includes the runtime lease release.
public struct TrackedCommandStream: Sendable {
    public let operationID: UUID
    public let events: AsyncThrowingStream<CommandEvent, Error>
    private let completion: Task<Void, Never>?

    init(operationID: UUID, events: AsyncThrowingStream<CommandEvent, Error>, completion: Task<Void, Never>? = nil) {
        self.operationID = operationID
        self.events = events
        self.completion = completion
    }

    public func waitForCompletion() async { await completion?.value }
}
