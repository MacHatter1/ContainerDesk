import Foundation

public struct CommandResult: Sendable, Equatable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32
    public let terminationReason: Process.TerminationReason
    public let duration: Duration
    public let outputTruncated: Bool
    public let timedOut: Bool

    public var succeeded: Bool { terminationReason == .exit && exitCode == 0 }

    public init(standardOutput: String, standardError: String, exitCode: Int32, terminationReason: Process.TerminationReason, duration: Duration, outputTruncated: Bool = false, timedOut: Bool = false) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.duration = duration
        self.outputTruncated = outputTruncated
        self.timedOut = timedOut
    }
}

public enum CommandEvent: Sendable, Equatable {
    case standardOutput(String)
    case standardError(String)
    case completed(CommandResult)
}

public enum ContainerClientError: Error, LocalizedError, Sendable {
    case executableNotFound
    case launchFailed(String)
    case outputBufferExceeded

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "The container CLI could not be found. Set its path in Settings."
        case .launchFailed(let message): message
        case .outputBufferExceeded: "Command output exceeded the streaming buffer. The command was stopped to avoid losing output."
        }
    }
}
