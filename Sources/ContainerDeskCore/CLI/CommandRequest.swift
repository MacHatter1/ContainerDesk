import Foundation

public struct CommandRequest: Sendable {
    /// Arguments passed to the container executable; do not include its path or shell quoting.
    public var arguments: [String]
    public var workingDirectory: URL?
    /// If present, bytes are written once to stdin and stdin is then closed.
    public var stdin: Data?
    /// Additional environment values. The inherited GUI-process environment is preserved.
    public var environment: [String: String]
    /// Exact secret strings removed from previews, events, and captured output.
    public var redactions: [String]
    /// Upper bound for captured stdout/stderr independently. Stream events continue to be emitted.
    public var captureLimit: Int
    /// Do not emit stdout/stderr events; still return bounded output from `run` for immediate parsing.
    public var suppressOutputEvents: Bool
    public var timeout: Duration?

    public init(
        arguments: [String],
        workingDirectory: URL? = nil,
        stdin: Data? = nil,
        environment: [String: String] = [:],
        redactions: [String] = [],
        captureLimit: Int = 1_000_000,
        suppressOutputEvents: Bool = false,
        timeout: Duration? = nil
    ) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.stdin = stdin
        self.environment = environment
        self.redactions = redactions.filter { !$0.isEmpty }
        self.captureLimit = max(0, captureLimit)
        self.suppressOutputEvents = suppressOutputEvents
        self.timeout = timeout
    }

    public var preview: String {
        var safeArguments = arguments
        let secretFlags = ["--password", "--token", "--secret", "--auth", "--authorization", "--access-key", "--secret-key"]
        for index in safeArguments.indices {
            let lower = safeArguments[index].lowercased()
            if secretFlags.contains(where: { lower == $0 || lower.hasPrefix($0 + "=") }) {
                if let equals = safeArguments[index].firstIndex(of: "=") { safeArguments[index] = String(safeArguments[index][...equals]) + "••••" }
                else if safeArguments.indices.contains(index + 1) { safeArguments[index + 1] = "••••" }
            } else if let equals = safeArguments[index].firstIndex(of: "=") {
                let key = safeArguments[index][..<equals].lowercased()
                if ["password", "passwd", "token", "secret", "authorization", "access_key", "secret_key"].contains(where: { key.contains($0) }) {
                    safeArguments[index] = String(safeArguments[index][...equals]) + "••••"
                }
            }
        }
        let command = (["container"] + safeArguments.map(redact)).map(Self.quoteForDisplay).joined(separator: " ")
        return command
    }

    /// Only known read-only operations may be replayed after failure.
    public var isSafeToRetry: Bool {
        guard stdin == nil, environment.isEmpty, redactions.isEmpty else { return false }
        let sensitiveMarkers = ["--password", "--token", "--secret", "--auth", "--authorization", "--env", "--env-file", "--access-key", "--secret-key"]
        guard !arguments.contains(where: { argument in
            let lower = argument.lowercased()
            return sensitiveMarkers.contains(where: { lower == $0 || lower.hasPrefix($0 + "=") }) || lower.contains("password=") || lower.contains("token=") || lower.contains("secret=")
        }) else { return false }

        // Retry policy is intentionally an allowlist. Most container CLI commands are
        // mutating (including delete/prune/create/start/stop/copy/exec), and their
        // resource scope may have changed by the time a user retries them.
        let words = Array(arguments.prefix(3))
        if words.starts(with: ["logs"]) || words.starts(with: ["stats"]) { return true }
        if words.starts(with: ["builder", "status"]) { return true }
        if words.starts(with: ["system", "version"]) || words.starts(with: ["system", "df"]) { return true }
        if words.starts(with: ["system", "dns", "list"]) { return true }
        return false
    }

    public func redact(_ string: String) -> String {
        redactions.sorted { $0.count > $1.count }.reduce(string) { $0.replacingOccurrences(of: $1, with: "••••") }
    }

    /// Redacts common credential-shaped assignments in CLI output even when the value came from the runtime.
    public func sanitizeOutput(_ string: String) -> String {
        var output = redact(string)
        let patterns: [(String, String)] = [
            (#"(?i)((?:[A-Z0-9_.-]*(?:password|passwd|token|secret|authorization|api[_-]?key|access[_-]?key|private[_-]?key)[A-Z0-9_.-]*)\s*=\s*)([^,;\r\n}]+)"#, "$1••••"),
            (#"(?i)(\"[^\"]*(?:password|passwd|token|secret|authorization|api[_-]?key|access[_-]?key|private[_-]?key)[^\"]*\"\s*:\s*\")[^\"]*(\")"#, "$1••••$2"),
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: template)
        }
        return output
    }

    private static func quoteForDisplay(_ value: String) -> String {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\\\"$`"))) != nil else {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
