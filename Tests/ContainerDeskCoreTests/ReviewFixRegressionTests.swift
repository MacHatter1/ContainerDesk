import Darwin
import Foundation
import Testing
@testable import ContainerDeskCore

struct ReviewFixRegressionTests {
    @Test func optionalStatsDoNotDiscardHealthyContainers() throws {
        let json = #"[{"id":"starting"},{"id":"partial","cpuUsageUsec":null,"memoryUsageBytes":10},{"id":"ready","cpuUsageUsec":20,"memoryUsageBytes":30}]"#
        #expect(try ContainerStatsJSONDecoder.samples(from: Data(json.utf8)) == [.init(id: "ready", cpuUsageUsec: 20, memoryUsageBytes: 30)])
    }

    @Test func doubleQuotedBackslashesPreserveRegexEscapes() throws {
        #expect(try ContainerCommandTokenizer.tokenize(#"grep "\d+\s" "a\qb" "\"quoted\"" "a\\b""#) == ["grep", #"\d+\s"#, #"a\qb"#, "\"quoted\"", #"a\b"#])
    }

    @Test func unicodeJoinersSurviveLogsAndSavedNames() throws {
        let text = "👩‍💻 می‌خواهم"
        var buffer = ContainerLogBuffer()
        buffer.append(text + "\u{07}\n", containerID: "web")
        #expect(buffer.entries.first?.message == text)
        var library = ManagedStackLibrary()
        var collection = ManagedStackCollection()
        collection.stacks = [ManagedStack(name: text)]
        library.runtimes["default"] = collection
        try library.validate()
        try EnvironmentProfile(name: text, configuration: .init(image: "alpine")).validate()
    }

    @Test(arguments: ["DB_PASS", "MYSQL_PWD", "passphrase", "x-auth", "session_cookie"])
    func credentialLabelsAreMasked(key: String) throws {
        let json = try JSONSerialization.data(withJSONObject: ["labels": [key: "private-value", "description": "visible"]])
        let redacted = try ResourceJSONRedactor.redact(String(decoding: json, as: UTF8.self))
        #expect(!redacted.contains("private-value"))
        #expect(redacted.contains("visible"))
    }

    @Test func frameworkPythonIsRecognizedAsMLXServer() {
        #expect(MLXServerProcessIdentity.isServer(arguments: ["/Library/Frameworks/Python.framework/Versions/3.13/Python", "-u", "-m", "mlx_lm.server", "--port", "8080"]))
        #expect(!MLXServerProcessIdentity.isServer(arguments: ["/usr/bin/Python", "-m", "unrelated.server"]))
    }

    @Test func shortBuildValuesDoNotMaskUnrelatedOutput() {
        let request = CommandRequest(arguments: ["build"], redactions: [CommandRequest.assignmentRedaction("VERSION=1")])
        #expect(request.redact("step 1 of 10: VERSION=1") == "step 1 of 10: ••••")
        #expect(CommandRequest.assignmentRedaction("DB_PASS=1") == "1")
    }

    @Test func relativeExecutableOverridesAreRejected() {
        #expect(ExecutableResolver(overridePath: "./container").resolve(environment: ["PATH": ".:bin:"]) == nil)
    }

    @Test func privilegedDNSScriptQuotesExecutableAndEveryArgument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DNS quoting \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("container ' $HOME `id`")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var request = try DNSAdminAction.create(domainName: "app.test", localhost: "::1").administratorRequest(executableURL: cli)
        #expect(request.arguments[1].contains("with administrator privileges"))
        // Exercise the exact quoting script without requesting administrator access.
        request.arguments[1] = request.arguments[1].replacingOccurrences(of: " with administrator privileges", with: "")
        request.timeout = .seconds(10)
        let result = try await ProcessExecutableClient(executableURL: URL(fileURLWithPath: "/usr/bin/osascript")).run(request)
        #expect(result.succeeded, "\(result.standardError)")
        #expect(result.standardOutput.split(whereSeparator: \.isNewline).map(String.init) == ["system", "dns", "create", "--localhost", "::1", "app.test"])
        #expect(throws: DNSAdminError.self) { try DNSAdminAction.delete(domainName: "app.test; id").administratorRequest(executableURL: cli) }
    }

    @Test(arguments: [false, true])
    func escapedDescendantCannotKeepOutputPipesOpenPastShutdown(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EscapedPipe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("escaped-pid")
        defer {
            if let raw = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) { _ = kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        let script = "import os,sys,time; pid=os.fork();\nif pid == 0:\n os.setsid(); open(sys.argv[1], 'w').write(str(os.getpid())); print('ready', flush=True); time.sleep(30)\nelse:\n os.waitpid(pid, 0)\n"
        let client = ProcessExecutableClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let start = ContinuousClock.now
        if cancel {
            let execution = try client.launch(.init(arguments: ["-c", script, marker.path], timeout: .seconds(5)))
            for try await event in execution.events {
                if case .standardOutput = event { break }
            }
            await execution.terminateAndWait()
        } else {
            let result = try await client.run(.init(arguments: ["-c", script, marker.path], timeout: .seconds(1)))
            #expect(result.timedOut)
        }
        #expect(start.duration(to: .now) < .seconds(4))
    }
}
