import Foundation
import Testing
@testable import ContainerDeskCore

@Suite(.serialized)
struct MLXToolchainDetectorTests {
    @Test func missingExplicitOverrideDoesNotFallBackToInstalledTool() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent(".local/bin/mlx_lm")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(installed, script: "#!/bin/sh\nprintf 'mlx_lm 0.32.2\\n'\n")
        let detector = MLXToolchainDetector(configuration: MLXConfiguration(executableOverride: root.appendingPathComponent("missing")), environment: ["PATH": ""], homeDirectory: root)

        #expect(detector.resolveExecutable() == nil)
    }

    @Test func checksSupportedVersionAndRequiredServerFlags() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mlx_lm")
        try writeExecutable(executable, script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'mlx_lm 0.32.2\\n'; exit 0; fi
        if [ "$1" = "server" ] && [ "$2" = "--help" ]; then printf '%s\\n' '--model --host --port --max-tokens --temp --allowed-origins'; exit 0; fi
        exit 2
        """)
        let detector = MLXToolchainDetector(configuration: MLXConfiguration(executableOverride: executable), environment: ["PATH": "/usr/bin:/bin"], homeDirectory: root)

        let result = await detector.detect()
        #expect(result.available)
        #expect(result.mlxLMVersion == "0.32.2")
        #expect(result.executableURL?.path == executable.path)
    }

    @Test func selectedServerEntryPointUsesSiblingDispatcherForCapabilityChecks() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = root.appendingPathComponent("mlx_lm")
        let server = root.appendingPathComponent("mlx_lm.server")
        try writeExecutable(dispatcher, script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'mlx_lm 0.32.2\\n'; exit 0; fi
        if [ "$1" = "server" ] && [ "$2" = "--help" ]; then printf '%s\\n' '--model --host --port --max-tokens --temp --allowed-origins'; exit 0; fi
        exit 2
        """)
        // The Python entry point is a direct server parser: it accepts server flags at argv[1]
        // and has neither the dispatcher version flag nor a `server` subcommand.
        try writeExecutable(server, script: """
        #!/bin/sh
        if [ "$1" = "--help" ]; then printf '%s\\n' '--model --host --port --max-tokens --temp --allowed-origins'; exit 0; fi
        exit 2
        """)
        let detector = MLXToolchainDetector(configuration: MLXConfiguration(executableOverride: server), environment: ["PATH": ""], homeDirectory: root)

        let result = await detector.detect()
        #expect(result.available)
        #expect(result.mlxLMVersion == "0.32.2")
        #expect(result.executableURL?.standardizedFileURL.path == dispatcher.standardizedFileURL.path)
    }

    @Test func selectedServerEntryPointWithoutSiblingDispatcherFailsActionably() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let selected = root.appendingPathComponent("chosen/mlx_lm.server")
        try FileManager.default.createDirectory(at: selected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(selected, script: "#!/bin/sh\nexit 0\n")
        let pathCandidate = bin.appendingPathComponent("mlx_lm")
        try writeExecutable(pathCandidate, script: "#!/bin/sh\nprintf 'mlx_lm 0.32.2\\n'\n")
        let detector = MLXToolchainDetector(configuration: MLXConfiguration(executableOverride: selected), environment: ["PATH": bin.path], homeDirectory: root)

        let result = await detector.detect()
        #expect(!result.available)
        #expect(result.reason?.localizedCaseInsensitiveContains("sibling") == true)
        #expect(result.executableURL == nil)
    }

    @Test func refusesUnverifiedVersionEvenWhenExecutableSucceeds() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mlx_lm")
        try writeExecutable(executable, script: "#!/bin/sh\nprintf 'mlx_lm 0.33.0\\n'\n")
        let result = await MLXToolchainDetector(configuration: MLXConfiguration(executableOverride: executable), environment: ["PATH": "/usr/bin:/bin"], homeDirectory: root).detect()

        #expect(!result.available)
        #expect(result.mlxLMVersion == "0.33.0")
    }

    @Test func resolvesInterpreterFromScriptShebangWithoutExecutingIt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent("python3.14")
        let executable = root.appendingPathComponent("mlx_lm")
        try writeExecutable(python, script: "#!/bin/sh\nexit 0\n")
        try writeExecutable(executable, script: "#!\(python.path)\nexit 0\n")

        #expect(MLXToolchainDetector.pythonInterpreter(for: executable, environment: ["PATH": ""])?.path == python.path)
    }

    @Test func shellTrampolineUsesTheSiblingPythonInAPathContainingSpaces() throws {
        let root = temporaryDirectory().appendingPathComponent("Python Environment/bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let python = root.appendingPathComponent("python")
        let executable = root.appendingPathComponent("mlx_lm")
        try writeExecutable(python, script: "#!/bin/sh\nexit 0\n")
        try writeExecutable(executable, script: "#!/bin/sh\n'''exec' \"\(python.path)\" \"$0\" \"$@\"\n' '''\n")
        #expect(MLXToolchainDetector.pythonInterpreter(for: executable, environment: ["PATH": ""])?.path == python.path)
    }

    @Test func symlinkedShellTrampolineUsesTargetVenvWithoutResolvingPythonOutOfIt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("Python Environment/bin")
        let exposed = root.appendingPathComponent("exposed")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exposed, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try FileManager.default.createSymbolicLink(at: python, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        let target = bin.appendingPathComponent("mlx_lm")
        try writeExecutable(target, script: "#!/bin/sh\n'''exec' \"\(python.path)\" \"$0\" \"$@\"\n' '''\n")
        let link = exposed.appendingPathComponent("mlx_lm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(MLXToolchainDetector.pythonInterpreter(for: link, environment: ["PATH": "/usr/bin:/bin"])?.path == python.path)
    }

    @Test func envShebangResolvesPythonAndNeverReturnsAShellOrAnArbitraryInterpreter() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mlx_lm")
        let python = root.appendingPathComponent("python3")
        try writeExecutable(python, script: "#!/bin/sh\nexit 0\n")
        try writeExecutable(executable, script: "#!/usr/bin/env -S python3 -u\n")
        #expect(MLXToolchainDetector.pythonInterpreter(for: executable, environment: ["PATH": root.path])?.path == python.path)
        try FileManager.default.removeItem(at: python)
        for interpreter in ["/bin/sh", "/bin/bash", "/usr/bin/ruby"] {
            try writeExecutable(executable, script: "#!\(interpreter)\n")
            #expect(MLXToolchainDetector.pythonInterpreter(for: executable, environment: ["PATH": ""]) == nil)
        }
    }

    private func writeExecutable(_ url: URL, script: String) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesk-mlx-toolchain-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
