import Foundation

public protocol MLXCapabilityProbing: Sendable {
    func detect(configuration: MLXConfiguration, environment: [String: String]) async -> MLXCapability
}

public struct MLXToolchainDetector: MLXCapabilityProbing, Sendable {
    private let configuration: MLXConfiguration
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(configuration: MLXConfiguration = MLXConfiguration(), environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.configuration = configuration
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    public func detect() async -> MLXCapability {
        guard let selectedExecutable = resolveExecutable() else {
            let reason = configuration.executableOverride == nil
                ? "mlx_lm was not found. Install it in an existing Python environment or choose its executable in Settings."
                : "The mlx_lm executable selected in Settings is missing or not executable."
            return MLXCapability(available: false, reason: reason)
        }
        guard let executable = canonicalExecutable(for: selectedExecutable) else {
            return MLXCapability(
                available: false,
                reason: "The selected mlx_lm.server entry point requires an executable mlx_lm dispatcher sibling in the same folder."
            )
        }
        let python = Self.pythonInterpreter(for: executable, environment: environment)
        let client = ProcessExecutableClient(executableURL: executable)
        let env = ["HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"]
        let request = CommandRequest(
            arguments: ["--version"],
            environment: env,
            captureLimit: 4_096,
            suppressOutputEvents: true,
            timeout: .seconds(30)
        )
        do {
            let result = try await client.run(request)
            guard result.succeeded,
                  !result.outputTruncated,
                  let version = Self.version(in: result.standardOutput + "\n" + result.standardError) else {
                return MLXCapability(available: false, executableURL: executable, pythonURL: python, reason: Self.safeFailure(result))
            }
            guard version == "0.32.2" else {
                return MLXCapability(available: false, mlxLMVersion: version, executableURL: executable, pythonURL: python, reason: "This app has verified mlx_lm 0.32.2. The selected executable reports \(version).")
            }
            let help = try await client.run(CommandRequest(
                arguments: ["server", "--help"],
                environment: env,
                captureLimit: 16_384,
                suppressOutputEvents: true,
                timeout: .seconds(30)
            ))
            let helpText = help.standardOutput + "\n" + help.standardError
            let requiredFlags = ["--model", "--host", "--port", "--max-tokens", "--temp", "--allowed-origins"]
            guard help.succeeded, !help.outputTruncated, requiredFlags.allSatisfy({ helpText.contains($0) }) else {
                return MLXCapability(available: false, mlxLMVersion: version, executableURL: executable, pythonURL: python, reason: "The selected mlx_lm build does not expose the verified local server options.")
            }
            return MLXCapability(available: true, mlxLMVersion: version, executableURL: executable, pythonURL: python)
        } catch {
            return MLXCapability(available: false, executableURL: executable, pythonURL: python, reason: "Could not run mlx_lm: \(error.localizedDescription)")
        }
    }

    public func detect(configuration: MLXConfiguration, environment: [String: String]) async -> MLXCapability {
        await MLXToolchainDetector(configuration: configuration, environment: environment, homeDirectory: homeDirectory).detect()
    }

    public func resolveExecutable() -> URL? {
        if let overridePath = configuration.executableOverride?.path {
            guard !overridePath.isEmpty, FileManager.default.isExecutableFile(atPath: overridePath) else { return nil }
            return URL(fileURLWithPath: overridePath).standardizedFileURL
        }
        var candidates: [String] = []
        candidates.append(homeDirectory.appendingPathComponent(".local/bin/mlx_lm").path)
        candidates.append("/opt/homebrew/bin/mlx_lm")
        candidates.append("/usr/local/bin/mlx_lm")
        candidates += (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":").map { String($0) + "/mlx_lm" }
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return URL(fileURLWithPath: candidate).standardizedFileURL
        }
        return nil
    }

    private func canonicalExecutable(for selectedExecutable: URL) -> URL? {
        guard selectedExecutable.lastPathComponent == "mlx_lm.server" else {
            return selectedExecutable
        }
        let dispatcher = selectedExecutable.deletingLastPathComponent().appendingPathComponent("mlx_lm", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: dispatcher.path) else { return nil }
        return dispatcher.standardizedFileURL
    }

    public static func pythonInterpreter(for executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let handle = try? FileHandle(forReadingFrom: executable) {
            let header = try? handle.read(upToCount: 512)
            try? handle.close()
            if let header, let firstLine = String(data: header, encoding: .utf8)?.split(whereSeparator: \.isNewline).first,
               firstLine.hasPrefix("#!") {
                let interpreter = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if interpreter.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: interpreter) {
                    return URL(fileURLWithPath: interpreter).standardizedFileURL
                }
                let components = interpreter.split(whereSeparator: \.isWhitespace)
                if components.first.map({ URL(fileURLWithPath: String($0)).lastPathComponent }) == "env", let name = components.dropFirst().first,
                   let located = resolveCommand(String(name), in: environment) { return located }
            }
        }
        let siblingPython = executable.deletingLastPathComponent().appendingPathComponent("python", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: siblingPython.path) { return siblingPython.standardizedFileURL }
        return resolveCommand("python3", in: environment)
    }

    private static func resolveCommand(_ name: String, in environment: [String: String]) -> URL? {
        for directory in (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path.path) { return path.standardizedFileURL }
        }
        return nil
    }

    private static func version(in text: String) -> String? {
        guard let range = text.range(of: #"\b\d+\.\d+(?:\.\d+)?\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func safeFailure(_ result: CommandResult) -> String {
        let detail = result.standardError.isEmpty ? result.standardOutput : result.standardError
        if result.timedOut { return "The mlx_lm version check timed out." }
        guard !detail.isEmpty else { return "The mlx_lm executable did not return a readable version." }
        return String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
    }
}
