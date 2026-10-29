import Foundation

public struct ExecutableResolver: Sendable {
    public var overridePath: String?

    public init(overridePath: String? = nil) { self.overridePath = overridePath }

    public func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let overridePath, !overridePath.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: overridePath, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: overridePath) else { return nil }
            return URL(fileURLWithPath: overridePath)
        }

        var candidates: [String] = []
        candidates += ["/opt/homebrew/bin/container", "/usr/local/bin/container"]
        candidates += (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":").map { String($0) + "/container" }
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Preserves the GUI caller's environment (HOME, SSH_AUTH_SOCK, proxy settings, etc.) and adds Homebrew to PATH.
    public static func normalizedEnvironment(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var environment = inherited
        let currentPath = inherited["PATH"] ?? ""
        var paths = ["/opt/homebrew/bin", "/usr/local/bin"] + currentPath.split(separator: ":").map(String.init)
        var seen = Set<String>()
        paths = paths.filter { seen.insert($0).inserted }
        environment["PATH"] = paths.joined(separator: ":")
        environment.merge(additional) { _, new in new }
        return environment
    }
}
