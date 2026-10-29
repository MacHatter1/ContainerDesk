import Darwin
import Foundation
import Testing
@testable import ContainerDeskCore

struct ContainerLaunchRequestBuilderTests {
    @Test func buildsDetachedLaunchWithLiteralCommandAndSeparateOptions() throws {
        let configuration = ContainerLaunchConfiguration(
            name: "dev-api", image: "alpine:latest", command: #"sh -c 'echo $HOME; $(whoami)' ''"#,
            cpus: "2", memory: "512MiB", platform: "linux/arm64",
            ports: ["8080:80"], volumes: ["app-data:/data"], networks: ["default"]
        )
        let request = try ContainerLaunchRequestBuilder.makeRequest(configuration: configuration)
        #expect(request.arguments == ["run", "--detach", "--name", "dev-api", "--cpus", "2", "--memory", "512MiB", "--platform", "linux/arm64", "--publish", "8080:80", "--volume", "app-data:/data", "--network", "default", "--", "alpine:latest", "sh", "-c", "echo $HOME; $(whoami)", ""])
        #expect(request.stdin == nil)
    }

    @Test func tokenizerKeepsEmptyArgumentsAndDoesNotExpandShellSyntax() throws {
        let words = try ContainerCommandTokenizer.tokenize(#"printf '' "" '$HOME' "$(id)" a\ b"#)
        #expect(words == ["printf", "", "", "$HOME", "$(id)", "a b"])
        #expect(throws: ContainerLaunchValidationError.self) { try ContainerCommandTokenizer.tokenize("echo 'unfinished") }
        #expect(throws: ContainerLaunchValidationError.self) { try ContainerCommandTokenizer.tokenize("echo \\") }
    }

    @Test func requiredKeysPreserveOrderDeduplicateAndAcceptExplicitEmptyValues() throws {
        #expect(try ContainerLaunchRequestBuilder.requiredEnvironmentKeys(in: ["FIRST=value", "SECOND=", "FIRST=override"]) == ["FIRST", "SECOND"])
        let config = ContainerLaunchConfiguration(image: "alpine", requiredEnvironmentKeys: ["FIRST", "SECOND"])
        let request = try ContainerLaunchRequestBuilder.makeRequest(configuration: config, environment: ["FIRST=private-value", "SECOND="])
        #expect(request.arguments.contains("SECOND="))
        #expect(!request.preview.contains("private-value"))
        #expect(request.redact("private-value") == "••••")
    }

    @Test func missingRequiredValueFailsWithoutFallingBackToImageOrHostEnvironment() {
        let config = ContainerLaunchConfiguration(image: "alpine", requiredEnvironmentKeys: ["PATH"])
        #expect(throws: ContainerLaunchValidationError.missingEnvironment) {
            try ContainerLaunchRequestBuilder.makeRequest(configuration: config)
        }
    }

    @Test func invalidOverridesNeverRevealTheirContentsInErrors() {
        for entry in ["SECRET_WITHOUT_ASSIGNMENT", "BAD KEY=very-private-value", "=very-private-value", "--name=very-private-value", "KEY=private\0value"] {
            do {
                _ = try ContainerLaunchRequestBuilder.requiredEnvironmentKeys(in: [entry])
                Issue.record("Invalid assignment was accepted")
            } catch {
                #expect(!error.localizedDescription.contains("very-private-value"))
                #expect(!error.localizedDescription.contains("SECRET_WITHOUT_ASSIGNMENT"))
            }
        }
    }

    @Test func environmentAssignmentKeysRejectTrailingLineTerminators() {
        for terminator in ["\n", "\r", "\r\n"] {
            let entry = "API_TOKEN" + terminator + "=private-value"
            #expect(throws: ContainerLaunchValidationError.invalidEnvironment) {
                try ContainerLaunchRequestBuilder.requiredEnvironmentKeys(in: [entry])
            }
            #expect(throws: ContainerLaunchValidationError.invalidEnvironment) {
                try ContainerLaunchRequestBuilder.makeRequest(configuration: .init(image: "alpine"), environment: [entry])
            }
        }
    }

    @Test func environmentFilesMatchLiteralCLIValuesAndRedactEveryValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("launch.env")
        try "# ignored\n\n  FIRST='literal $HOME'\nSECOND=\nTHIRD=secret=with=equals # literal\n".write(to: file, atomically: true, encoding: .utf8)
        let config = ContainerLaunchConfiguration(image: "alpine", environmentFiles: [file.path], requiredEnvironmentKeys: ["FIRST", "SECOND", "THIRD"])
        let request = try ContainerLaunchRequestBuilder.makeRequest(configuration: config, environment: ["FIRST=override-secret"])
        #expect(!request.arguments.contains(file.path))
        #expect(!request.arguments.contains("--env-file"))
        #expect(request.arguments.contains("--env=FIRST='literal $HOME'"))
        #expect(request.arguments.contains("--env=SECOND="))
        #expect(request.arguments.contains("--env=THIRD=secret=with=equals # literal"))
        let fileIndex = try #require(request.arguments.firstIndex(of: "--env=FIRST='literal $HOME'"))
        let inlineIndex = try #require(request.arguments.firstIndex(of: "FIRST=override-secret"))
        #expect(fileIndex < inlineIndex)
        // Later file edits cannot change the values or secret redactions in this request.
        try "FIRST=changed-secret\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!request.arguments.contains(where: { $0.contains("changed-secret") }))
        #expect(!request.preview.contains("literal $HOME"))
        #expect(!request.preview.contains("override-secret"))
        #expect(request.redact("'literal $HOME' / secret=with=equals # literal / override-secret") == "•••• / •••• / ••••")
    }

    @Test func saveAllowsAbsentFilesButLaunchRequiresReadableRegularUTF8Files() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let config = ContainerLaunchConfiguration(image: "alpine", environmentFiles: [missing])
        try ContainerLaunchRequestBuilder.validate(configuration: config)
        #expect(throws: ContainerLaunchValidationError.invalidEnvironmentFile) { try ContainerLaunchRequestBuilder.makeRequest(configuration: config) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ContainerLaunchValidationError.invalidEnvironmentFile) {
            try ContainerLaunchRequestBuilder.makeRequest(configuration: ContainerLaunchConfiguration(image: "alpine", environmentFiles: [directory.path]))
        }
        let file = directory.appendingPathComponent("invalid.env")
        try Data([0xFF, 0xFE]).write(to: file)
        #expect(throws: ContainerLaunchValidationError.invalidEnvironmentFile) {
            try ContainerLaunchRequestBuilder.makeRequest(configuration: ContainerLaunchConfiguration(image: "alpine", environmentFiles: [file.path]))
        }
    }

    @Test func environmentFilesRejectOverLimitAndNonregularFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("oversize.env")
        try Data(repeating: 65, count: 1_048_577).write(to: file)
        #expect(throws: ContainerLaunchValidationError.invalidEnvironmentFile) {
            try ContainerLaunchRequestBuilder.makeRequest(configuration: ContainerLaunchConfiguration(image: "alpine", environmentFiles: [file.path]))
        }
        let link = directory.appendingPathComponent("symlink.env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: ContainerLaunchValidationError.invalidEnvironmentFile) {
            try ContainerLaunchRequestBuilder.makeRequest(configuration: ContainerLaunchConfiguration(image: "alpine", environmentFiles: [link.path]))
        }
        let fifo = directory.appendingPathComponent("pipe.env")
        try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ContainerLaunchValidationError.invalidEnvironmentFile) {
            try ContainerLaunchRequestBuilder.makeRequest(configuration: ContainerLaunchConfiguration(image: "alpine", environmentFiles: [fifo.path]))
        }
    }

    @Test func environmentFileParsingErrorsHideSecretContent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "=private-file-secret\n".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try ContainerLaunchRequestBuilder.makeRequest(configuration: ContainerLaunchConfiguration(image: "alpine", environmentFiles: [file.path]))
            Issue.record("Malformed file was accepted")
        } catch {
            #expect(!error.localizedDescription.contains("private-file-secret"))
        }
    }

    @Test func bareFileKeysInheritOnlyAvailableHostValuesLikePinnedCLI() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "PATH\nCONTAINERDESK_MISSING_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\n".write(to: file, atomically: true, encoding: .utf8)
        let config = ContainerLaunchConfiguration(image: "alpine", environmentFiles: [file.path], requiredEnvironmentKeys: ["PATH"])
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            let request = try ContainerLaunchRequestBuilder.makeRequest(configuration: config)
            #expect(request.redactions.contains(path))
        }
    }

    @Test func savingBindReferencesDoesNotRequireTheirSourcesToExist() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let config = ContainerLaunchConfiguration(image: "alpine", volumes: [source + ":/app"])
        try ContainerLaunchRequestBuilder.validate(configuration: config)
        #expect(throws: ContainerLaunchValidationError.self) { try ContainerLaunchRequestBuilder.makeRequest(configuration: config) }
        for source in ["./data", "relative/data", "~/data", ".", ".."] {
            #expect(throws: ContainerLaunchValidationError.self) {
                try ContainerLaunchRequestBuilder.validate(configuration: ContainerLaunchConfiguration(image: "alpine", volumes: [source + ":/data"]))
            }
        }
    }

    @Test func volumeModesMustBeExplicitlyReadOnlyOrReadWrite() throws {
        for mode in ["ro", "rw"] {
            try ContainerLaunchRequestBuilder.validate(configuration: ContainerLaunchConfiguration(image: "alpine", volumes: ["data:/data:" + mode]))
        }
        for mode in ["readonly", "ro,rw", "--help"] {
            #expect(throws: ContainerLaunchValidationError.self) {
                try ContainerLaunchRequestBuilder.validate(configuration: ContainerLaunchConfiguration(image: "alpine", volumes: ["data:/data:" + mode]))
            }
        }
    }

    @Test func rejectsRelativeEnvironmentPathsAndOptionShapedInputs() {
        for path in ["relative.env", "$HOME/.env", "~someone/.env", "--env-file"] {
            #expect(throws: ContainerLaunchValidationError.self) {
                try ContainerLaunchRequestBuilder.validate(configuration: ContainerLaunchConfiguration(image: "alpine", environmentFiles: [path]))
            }
        }
        for config in [
            ContainerLaunchConfiguration(image: "--help"),
            ContainerLaunchConfiguration(name: "--rm", image: "alpine"),
            ContainerLaunchConfiguration(image: "alpine", platform: "--help"),
            ContainerLaunchConfiguration(image: "alpine", ports: ["--help"]),
            ContainerLaunchConfiguration(image: "alpine", volumes: ["--help:/data"]),
            ContainerLaunchConfiguration(image: "alpine", networks: ["--help"]),
        ] {
            #expect(throws: ContainerLaunchValidationError.self) { try ContainerLaunchRequestBuilder.validate(configuration: config) }
        }
    }

    @Test func validatesResourceLimitsBeforeCLIConversion() throws {
        for cpus in ["0", "-1", "1.5", "NaN", "999999999999999999999999999"] {
            #expect(throws: ContainerLaunchValidationError.self) {
                try ContainerLaunchRequestBuilder.validate(configuration: ContainerLaunchConfiguration(image: "alpine", cpus: cpus))
            }
        }
        for memory in ["199MiB", "0", "-1GiB", "NaN", "inf", String(repeating: "9", count: 400) + "P"] {
            #expect(throws: ContainerLaunchValidationError.self) {
                try ContainerLaunchRequestBuilder.validate(configuration: ContainerLaunchConfiguration(image: "alpine", memory: memory))
            }
        }
        try ContainerLaunchRequestBuilder.validate(configuration: ContainerLaunchConfiguration(image: "alpine", cpus: "1", memory: "200MiB"))
    }
}
