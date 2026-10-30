import Foundation
import Testing
@testable import ContainerDeskCore

struct CredentialArgumentRegressionTests {
    @Test(arguments: ["--password", "--passwd", "--token", "--secret", "--auth", "--authorization", "--api-key", "--access-key", "--secret-key", "--private-key"])
    func credentialsAreHiddenConsistentlyInRunPreviewInspectAndOutput(_ flag: String) throws {
        for option in [flag, flag.uppercased()] {
            for suffix in [" 'unique credential 🚀'", "='unique credential 🚀'"] {
                let request = try ContainerLaunchRequestBuilder.makeRequest(configuration: .init(image: "alpine:latest", command: "service \(option)\(suffix) --label public"))
                #expect(request.arguments.contains(where: { $0.contains("unique credential 🚀") }))
                #expect(!request.preview.contains("unique credential 🚀"))
                #expect(request.preview.contains("public"))
                let json = String(decoding: try JSONSerialization.data(withJSONObject: ["command": request.arguments]), as: UTF8.self)
                let inspect = try ResourceJSONRedactor.redact(json)
                #expect(!inspect.contains("unique credential 🚀"))
                #expect(inspect.contains("public"))
                #expect(request.redact("echo: unique credential 🚀") == "echo: ••••")
                #expect(!CommandRequest(arguments: ["logs", "web", option, "unique credential 🚀"]).isSafeToRetry)
            }
        }
    }

    @Test func editsToArgumentsUpdateAutomaticRedactionsWithoutDroppingExplicitSecrets() {
        var request = CommandRequest(arguments: ["run", "--auth", "old-value"], redactions: ["environment-value"])
        request.arguments = ["run", "--api-key=new-value"]
        #expect(request.redact("new-value environment-value old-value") == "•••• •••• old-value")
        request.redactions = ["replacement"]
        #expect(request.redact("new-value replacement") == "•••• ••••")
    }

    @Test func outputStreamsMaskKnownFlagValuesEvenAcrossPipeReads() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("container")
        try "#!/bin/sh\nhead -c 4095 /dev/zero | tr '\\000' x\nprintf 'credential-value'\nprintf 'credential-value' >&2\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ProcessContainerClient(resolver: .init(overridePath: executable.path))
        let request = CommandRequest(arguments: ["run", "--", "image", "server", "--auth", "credential-value"])
        var output = ""
        var completed: CommandResult?
        for try await event in client.stream(request) {
            switch event {
            case .standardOutput(let chunk), .standardError(let chunk): output += chunk
            case .completed(let result): completed = result
            }
        }
        #expect(!output.contains("credential-value"))
        #expect(output.contains("••••"))
        #expect(completed?.standardOutput.hasSuffix("••••") == true)
        #expect(completed?.standardError == "••••")
    }
}
