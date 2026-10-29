import Foundation

public protocol ContainerClient: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error>
}
