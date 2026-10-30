import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct AdvancedCommandRequestBuilderTests {
    @Test func everyAdvancedEnvironmentRouteSnapshotsAndRedactsFileInheritedAndInlineValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdvancedEnv.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("inputs.env")
        let executable = root.appendingPathComponent("fake-container")
        try """
        #!/bin/bash
        for argument in "$@"; do
          case "$argument" in
            --env=*) pair="${argument#--env=}"; value="${pair#*=}"
              printf '%s' "${value:0:3}"
              sleep 0.01
              printf '%s\\n' "${value:3}"
              printf '%s\\n' "$value" >&2 ;;
          esac
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = ProcessContainerClient(resolver: ExecutableResolver(overridePath: executable.path))
        for (section, command) in [(ContainerSection.containers, "run"), (.containers, "create"), (.containers, "exec"), (.machines, "run")] {
            try "FILE=file-private-value\nFILE_BARE\n".write(to: file, atomically: true, encoding: .utf8)
            let spec = try #require(AdvancedCommandCatalog.specs(for: section).first { $0.id == command })
            let request = try AdvancedCommandRequestBuilder.make(section: section, spec: spec, flags: [], values: ["env-file": file.path, "env": "INHERITED\nINLINE=inline-private-value\nEMPTY=\nMISSING"], positionalArguments: ["fixture-target"], inherited: ["INHERITED": "inherited-private-value", "FILE_BARE": "file-inherited-value"])
            #expect(!request.arguments.contains(file.path) && !request.arguments.contains("--env-file"))
            #expect(request.arguments.contains("--env=EMPTY="))
            #expect(!request.arguments.contains(where: { $0.contains("MISSING") }))
            try "FILE=changed-after-review\n".write(to: file, atomically: true, encoding: .utf8)
            let secrets = ["file-private-value", "inherited-private-value", "inline-private-value", "file-inherited-value"]
            var visible = ""
            for try await event in client.stream(request) {
                switch event {
                case .standardOutput(let chunk), .standardError(let chunk): visible += chunk
                case .completed(let result):
                    #expect(result.succeeded)
                    #expect(!secrets.contains(where: { result.standardOutput.contains($0) || result.standardError.contains($0) }))
                }
            }
            #expect(visible.contains("••••"))
            #expect(!secrets.contains(where: { visible.contains($0) || request.preview.contains($0) }))
            #expect(!request.arguments.contains(where: { $0.contains("changed-after-review") }))
        }
    }

    @Test func invalidEnvironmentInputFailsBeforeCreatingARequest() throws {
        let spec = try #require(AdvancedCommandCatalog.specs(for: .containers).first { $0.id == "run" })
        #expect(throws: ContainerLaunchValidationError.self) {
            try AdvancedCommandRequestBuilder.make(section: .containers, spec: spec, flags: [], values: ["env-file": "/missing/fixture.env"], positionalArguments: ["image"])
        }
        #expect(throws: ContainerLaunchValidationError.self) {
            try AdvancedCommandRequestBuilder.make(section: .containers, spec: spec, flags: [], values: ["env": "BAD KEY=private-value"], positionalArguments: ["image"])
        }
    }

    @Test func advancedEnvironmentPreservesBroaderCLIKeysAndEmptyOverridePrecedence() throws {
        let spec = try #require(AdvancedCommandCatalog.specs(for: .containers).first { $0.id == "exec" })
        let request = try AdvancedCommandRequestBuilder.make(section: .containers, spec: spec, flags: [], values: ["env": "app.setting=literal=with=equals\nHOST.KEY\nHOST.KEY="], positionalArguments: ["web", "printenv"], inherited: ["HOST.KEY": "host-value"])
        #expect(request.arguments.filter { $0.hasPrefix("--env=") } == ["--env=app.setting=literal=with=equals", "--env=HOST.KEY=host-value", "--env=HOST.KEY="])
        #expect(!request.preview.contains("host-value") && !request.preview.contains("literal=with=equals"))
    }
}
