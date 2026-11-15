import ContainerDeskCore

enum LogRequestBuilder {
    enum Source: Sendable {
        case container(String)
        case machine(String)
    }

    enum Mode: Sendable {
        case snapshot
        case follow
        case resume
    }

    static func make(source: Source, mode: Mode) -> CommandRequest {
        let prefix: [String]
        let id: String
        switch source {
        case .container(let value): prefix = ["logs"]; id = value
        case .machine(let value): prefix = ["machine", "logs"]; id = value
        }
        let follows = mode != .snapshot
        // Supplying -n also avoids the CLI's empty-file return before follow starts.
        let arguments = prefix + (follows ? ["--follow"] : []) + ["-n", mode == .resume ? "0" : "200", "--", id]
        return CommandRequest(arguments: arguments, captureLimit: follows ? 0 : 500_000, suppressOutputEvents: !follows)
    }
}
