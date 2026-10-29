import Foundation

public enum RuntimeServiceState: Sendable, Equatable {
    case running
    case stopped
    case unknown
}

public struct RuntimeStatusSummary: Sendable, Equatable {
    public let state: RuntimeServiceState
    public let rawState: String?
    public let architecture: String?

    public init(state: RuntimeServiceState, rawState: String?, architecture: String?) {
        self.state = state
        self.rawState = rawState
        self.architecture = architecture
    }
}

/// Parses the stable key/value lines emitted by `container system status`.
public enum RuntimeStatusDecoder {
    public static func decode(_ output: String) -> RuntimeStatusSummary {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            values[String(fields[0]).lowercased()] = String(fields[1]).trimmingCharacters(in: .whitespaces)
        }
        let rawState = values["status"]
        let state: RuntimeServiceState
        switch rawState?.lowercased() {
        case "running": state = .running
        case "stopped", "not running": state = .stopped
        default: state = .unknown
        }
        return RuntimeStatusSummary(state: state, rawState: rawState, architecture: values["host.architecture"])
    }
}

/// Checks plugin help headers without treating the generic root help as plugin support.
public enum CLIPluginHelpDecoder {
    public static func isAvailable(plugin: String, succeeded: Bool, output: String) -> Bool {
        guard succeeded, !plugin.isEmpty else { return false }
        let expectedPrefix = "USAGE: \(plugin) "
        return output.split(whereSeparator: \.isNewline).contains {
            String($0).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(expectedPrefix.lowercased())
        }
    }
}
