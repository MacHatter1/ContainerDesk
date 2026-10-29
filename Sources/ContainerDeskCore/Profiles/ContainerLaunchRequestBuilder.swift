import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Darwin
import Foundation

public enum ContainerLaunchValidationError: LocalizedError, Equatable {
    case invalidField(String)
    case invalidEnvironment
    case invalidEnvironmentFile
    case missingEnvironment
    case invalidCommand

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field): "Check the \(field) value before launching."
        case .invalidEnvironment: "Environment overrides must use KEY=value with a nonempty key and no whitespace in the key."
        case .invalidEnvironmentFile: "Environment files must be readable UTF-8 regular files of at most 1 MiB at absolute paths or paths beginning with ~/. Check their variable names as well."
        case .missingEnvironment: "Provide all required environment keys through overrides or environment files before launching."
        case .invalidCommand: "Finish the open quote or escape before running the command."
        }
    }
}

/// Builds an argv request only. Validation never creates containers, volumes, or networks.
public enum ContainerLaunchRequestBuilder {
    /// Checks portable syntax when saving; referenced files and bind sources may be absent.
    public static func validate(configuration: ContainerLaunchConfiguration) throws {
        try configuration.validate()
        let image = trimmed(configuration.image)
        guard isOptionValue(image), !image.contains(where: \.isWhitespace) else {
            throw ContainerLaunchValidationError.invalidField("image")
        }
        let name = trimmed(configuration.name)
        if !name.isEmpty, !ManagedContainer.nameValid(name) {
            throw ContainerLaunchValidationError.invalidField("container name")
        }
        let cpus = trimmed(configuration.cpus)
        if !cpus.isEmpty {
            guard cpus.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int64(cpus), value > 0 else {
                throw ContainerLaunchValidationError.invalidField("CPU limit")
            }
        }
        let memory = trimmed(configuration.memory)
        if !memory.isEmpty {
            // Validate the floating-point conversion before the CLI converts it to Int64.
            guard let measurement = try? Measurement<UnitInformationStorage>.parse(parsing: memory) else {
                throw ContainerLaunchValidationError.invalidField("memory limit")
            }
            let mib = measurement.converted(to: .mebibytes).value
            guard mib.isFinite, mib >= 200, mib < Double(Int64.max / 1_048_576) else {
                throw ContainerLaunchValidationError.invalidField("memory limit (at least 200 MiB)")
            }
        }
        let platform = trimmed(configuration.platform)
        if !platform.isEmpty {
            guard isOptionValue(platform), (try? Parser.platform(from: platform)) != nil else {
                throw ContainerLaunchValidationError.invalidField("platform")
            }
        }
        for port in configuration.ports {
            guard isOptionValue(trimmed(port)), (try? Parser.publishPort(trimmed(port))) != nil else {
                throw ContainerLaunchValidationError.invalidField("published port")
            }
        }
        for network in configuration.networks {
            guard isOptionValue(trimmed(network)), (try? Parser.network(trimmed(network))) != nil else {
                throw ContainerLaunchValidationError.invalidField("network")
            }
        }
        for volume in configuration.volumes { try validateVolumeSyntax(trimmed(volume)) }
        for path in configuration.environmentFiles { _ = try environmentFilePath(path) }
        for key in configuration.requiredEnvironmentKeys {
            guard validEnvironmentKey(key) else { throw ContainerLaunchValidationError.invalidEnvironment }
        }
        _ = try ContainerCommandTokenizer.tokenize(configuration.command)
    }

    /// Values are transient: only their keys belong in a saved profile.
    public static func requiredEnvironmentKeys(in environment: [String]) throws -> [String] {
        var keys: [String] = []
        for entry in environment {
            let pair = try environmentAssignment(entry)
            if !keys.contains(pair.key) { keys.append(pair.key) }
        }
        return keys
    }

    public static func makeRequest(configuration: ContainerLaunchConfiguration, environment: [String] = []) throws -> CommandRequest {
        try validate(configuration: configuration)
        var availableKeys = Set<String>()
        var redactions: [String] = []
        var arguments = ["run", "--detach"]

        for (flag, raw) in [("--name", configuration.name), ("--cpus", configuration.cpus), ("--memory", configuration.memory), ("--platform", configuration.platform)] {
            let value = trimmed(raw)
            if !value.isEmpty { arguments += [flag, value] }
        }
        for (flag, values) in [("--publish", configuration.ports), ("--volume", configuration.volumes), ("--network", configuration.networks)] {
            for value in values { arguments += [flag, trimmed(value)] }
        }
        // The pinned parser validates bind source existence without touching runtime state.
        guard (try? Parser.volumes(configuration.volumes.map(trimmed))) != nil else {
            throw ContainerLaunchValidationError.invalidField("volume")
        }
        for rawPath in configuration.environmentFiles {
            let path = try environmentFilePath(rawPath)
            for pair in try environmentFileAssignments(path: path) {
                availableKeys.insert(pair.key)
                redactions.append(pair.value)
                // Snapshot each parsed value once: the CLI must not reread a changed file.
                // Joined option syntax also safely handles the broader key syntax in env files.
                arguments.append("--env=\(pair.key)=\(pair.value)")
            }
        }
        for entry in environment {
            let pair = try environmentAssignment(entry)
            availableKeys.insert(pair.key)
            redactions.append(pair.value)
            arguments += ["--env", entry]
        }
        guard Set(configuration.requiredEnvironmentKeys).isSubset(of: availableKeys) else {
            throw ContainerLaunchValidationError.missingEnvironment
        }
        // The CLI declares image as an Argument and the remaining command as captureForPassthrough.
        arguments += ["--", trimmed(configuration.image)]
        arguments += try ContainerCommandTokenizer.tokenize(configuration.command)
        return CommandRequest(arguments: arguments, redactions: redactions)
    }

    private static func validateVolumeSyntax(_ value: String) throws {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard isOptionValue(value), (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else {
            throw ContainerLaunchValidationError.invalidField("volume")
        }
        let destination = parts.count == 1 ? parts[0] : parts[1]
        guard destination.hasPrefix("/") else { throw ContainerLaunchValidationError.invalidField("volume destination") }
        if parts.count == 3, parts[2] != "ro", parts[2] != "rw" {
            throw ContainerLaunchValidationError.invalidField("volume mode (ro or rw)")
        }
        if parts.count > 1 {
            let source = String(parts[0])
            if source.contains("/") || source == "." || source == ".." {
                guard source.hasPrefix("/") else {
                    throw ContainerLaunchValidationError.invalidField("bind mount source; use an absolute path")
                }
            } else if !VolumeStorage.isValidVolumeName(source) {
                throw ContainerLaunchValidationError.invalidField("volume name")
            }
        }
    }

    private static func environmentFilePath(_ raw: String) throws -> String {
        let path = trimmed(raw)
        guard !path.contains("\0"), path.hasPrefix("/") || path.hasPrefix("~/") else {
            throw ContainerLaunchValidationError.invalidEnvironmentFile
        }
        return (path as NSString).expandingTildeInPath
    }

    private static func validEnvironmentKey(_ key: String) -> Bool {
        key.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil
    }

    private static func environmentAssignment(_ entry: String) throws -> (key: String, value: String) {
        guard !entry.contains("\0"), let equals = entry.firstIndex(of: "=") else {
            throw ContainerLaunchValidationError.invalidEnvironment
        }
        let key = String(entry[..<equals])
        guard validEnvironmentKey(key) else { throw ContainerLaunchValidationError.invalidEnvironment }
        return (key, String(entry[entry.index(after: equals)...]))
    }

    private static func environmentFileAssignments(path: String) throws -> [(key: String, value: String)] {
        let maximumBytes = 1_048_576
        // Check the opened descriptor so path replacement cannot substitute a FIFO or device.
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ContainerLaunchValidationError.invalidEnvironmentFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw ContainerLaunchValidationError.invalidEnvironmentFile
        }
        var data = Data()
        do {
            while data.count <= maximumBytes {
                guard let chunk = try handle.read(upToCount: maximumBytes + 1 - data.count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch { throw ContainerLaunchValidationError.invalidEnvironmentFile }
        guard data.count <= maximumBytes, let content = String(data: data, encoding: .utf8), !content.contains("\0") else {
            throw ContainerLaunchValidationError.invalidEnvironmentFile
        }
        var assignments: [(key: String, value: String)] = []
        // Matches container 1.5 Parser.envFile: leading whitespace only, literal values,
        // comments only at line start, and bare keys inherited from the host if present.
        for line in content.components(separatedBy: .newlines) {
            let value = String(line.drop(while: \.isWhitespace))
            if value.isEmpty || value.hasPrefix("#") { continue }
            if let equals = value.firstIndex(of: "=") {
                let key = String(value[..<equals])
                guard !key.isEmpty, !key.contains(where: { $0 == " " || $0 == "\t" }) else {
                    throw ContainerLaunchValidationError.invalidEnvironmentFile
                }
                assignments.append((key, String(value[value.index(after: equals)...])))
            } else {
                guard !value.contains(where: { $0 == " " || $0 == "\t" }) else { throw ContainerLaunchValidationError.invalidEnvironmentFile }
                if let inherited = ProcessInfo.processInfo.environment[value] { assignments.append((value, inherited)) }
            }
        }
        return assignments
    }

    private static func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func isOptionValue(_ value: String) -> Bool { !value.isEmpty && !value.hasPrefix("-") && !value.contains("\0") }
}

/// Tokenizes quotes and escapes without invoking a shell or expanding variables or substitutions.
public enum ContainerCommandTokenizer {
    public static func tokenize(_ input: String) throws -> [String] {
        guard !input.contains("\0") else { throw ContainerLaunchValidationError.invalidCommand }
        var arguments: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var active = false
        for character in input {
            if escaped { token.append(character); escaped = false; active = true; continue }
            if character == "\\" && quote != "'" { escaped = true; active = true; continue }
            if let currentQuote = quote {
                if character == currentQuote { quote = nil } else { token.append(character) }
                active = true
                continue
            }
            if character == "'" || character == "\"" { quote = character; active = true; continue }
            if character.isWhitespace {
                if active { arguments.append(token); token = ""; active = false }
            } else { token.append(character); active = true }
        }
        guard quote == nil && !escaped else { throw ContainerLaunchValidationError.invalidCommand }
        if active { arguments.append(token) }
        return arguments
    }
}
