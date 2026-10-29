import Foundation
import Testing
@testable import ContainerDeskCore

/// Opt-in only: requires a running service and an explicitly selected, cached Linux
/// image containing sh, printf, cat, and sleep. Never starts/stops system services.
struct EnvironmentProfilesLiveTests: Sendable {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTAINERDESK_PROFILES_LIVE_CHECK"] == "1"
        && ProcessInfo.processInfo.environment["CONTAINERDESK_PROFILES_IMAGE"]?.isEmpty == false))
    func launchesEnvironmentSnapshotWithOwnedVolumeAndCleansUp() async throws {
        let image = try #require(ProcessInfo.processInfo.environment["CONTAINERDESK_PROFILES_IMAGE"])
        // Default resolver deliberately ignores the app's optional CLI override.
        let client = ProcessContainerClient()
        let status = try await client.run(readOnly(["system", "status", "--format", "json"]))
        try #require(status.succeeded && !status.outputTruncated, "Start the runtime separately before enabling the live test.")
        let imageInspection = try await client.run(readOnly(["image", "inspect", "--", image]))
        try #require(imageInspection.succeeded && !imageInspection.outputTruncated, "The explicitly selected image must already be cached locally.")
        let images = try #require(JSONSerialization.jsonObject(with: Data(imageInspection.standardOutput.utf8)) as? [[String: Any]])
        try #require(!images.isEmpty, "Select an existing workload image, rather than an infrastructure image.")

        let suffix = UUID().uuidString.lowercased()
        let containerName = "profile-smoke-" + suffix
        let volumeName = "profile-data-" + suffix
        let containerBefore = try await client.run(readOnly(["inspect", containerName]))
        let volumeBefore = try await client.run(readOnly(["volume", "inspect", volumeName]))
        try #require(!containerBefore.succeeded && !volumeBefore.succeeded, "Generated smoke resource names must be unused.")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-smoke-" + suffix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.env")
        let fakeValue = "profile-fixture-" + suffix
        try "PROFILE_TEST_VALUE=\(fakeValue)\n".write(to: file, atomically: true, encoding: .utf8)
        let configuration = ContainerLaunchConfiguration(
            name: containerName,
            image: image,
            command: #"sh -c 'printf %s "$PROFILE_TEST_VALUE" > /data/profile-value; sleep 120'"#,
            cpus: "1", memory: "256M", volumes: [volumeName + ":/data"],
            environmentFiles: [file.path], requiredEnvironmentKeys: ["PROFILE_TEST_VALUE"]
        )
        var launch = try ContainerLaunchRequestBuilder.makeRequest(configuration: configuration)
        launch.timeout = .seconds(90)
        launch.suppressOutputEvents = true
        #expect(!launch.arguments.contains("--env-file"))
        #expect(!launch.preview.contains(fakeValue))
        // Change the file after preparation: execution must consume the prepared snapshot.
        try "PROFILE_TEST_VALUE=changed-after-snapshot\n".write(to: file, atomically: true, encoding: .utf8)

        do {
            let launched = try await client.run(launch)
            try #require(launched.succeeded && !launched.timedOut, "The owned smoke container must launch successfully.")
            let volumeInspection = try await client.run(readOnly(["volume", "inspect", volumeName]))
            try #require(volumeInspection.succeeded && !volumeInspection.outputTruncated)
            let volumes = try #require(JSONSerialization.jsonObject(with: Data(volumeInspection.standardOutput.utf8)) as? [[String: Any]])
            #expect(volumes.contains { $0["id"] as? String == volumeName })

            // Captured exec output is redacted by the same request mechanism as app activity.
            var readValue = try await client.run(CommandRequest(
                arguments: ["exec", containerName, "cat", "/data/profile-value"],
                redactions: launch.redactions, suppressOutputEvents: true, timeout: .seconds(20)
            ))
            for _ in 0..<20 where !readValue.succeeded {
                try await Task.sleep(for: .milliseconds(250))
                readValue = try await client.run(CommandRequest(
                    arguments: ["exec", containerName, "cat", "/data/profile-value"],
                    redactions: launch.redactions, suppressOutputEvents: true, timeout: .seconds(20)
                ))
            }
            try #require(readValue.succeeded)
            #expect(readValue.standardOutput == "••••")
            #expect(!readValue.standardOutput.contains(fakeValue))

            let inspection = try await client.run(CommandRequest(
                arguments: ["inspect", containerName], redactions: launch.redactions,
                suppressOutputEvents: true, timeout: .seconds(20)
            ))
            try #require(inspection.succeeded && !inspection.outputTruncated)
            let containers = try #require(JSONSerialization.jsonObject(with: Data(inspection.standardOutput.utf8)) as? [[String: Any]])
            let container = try #require(containers.first)
            let stored = try #require(container["configuration"] as? [String: Any])
            let resources = try #require(stored["resources"] as? [String: Any])
            #expect(stored["id"] as? String == containerName)
            #expect(resources["cpus"] as? Int == 1)
            #expect(resources["memoryInBytes"] as? Int == 256 * 1_048_576)
            let process = try #require(stored["initProcess"] as? [String: Any])
            #expect((process["environment"] as? [String])?.contains("PROFILE_TEST_VALUE=••••") == true)
            let expectedCommand = try ContainerCommandTokenizer.tokenize(configuration.command)
            let executable = try #require(process["executable"] as? String)
            #expect(executable == "sh" || executable.hasSuffix("/sh"))
            #expect(process["arguments"] as? [String] == Array(expectedCommand.dropFirst()))
            let mounts = try #require(stored["mounts"] as? [[String: Any]])
            #expect(mounts.contains { mount in
                guard mount["destination"] as? String == "/data",
                      let type = mount["type"] as? [String: Any],
                      let volume = type["volume"] as? [String: Any] else { return false }
                return volume["name"] as? String == volumeName
            })
        } catch {
            await Task.detached { await cleanupOwned(client: client, containerName: containerName, volumeName: volumeName) }.value
            throw error
        }
        await Task.detached { await cleanupOwned(client: client, containerName: containerName, volumeName: volumeName) }.value
    }

    private func readOnly(_ arguments: [String]) -> CommandRequest {
        CommandRequest(arguments: arguments, suppressOutputEvents: true, timeout: .seconds(20))
    }

    private func cleanupOwned(client: ProcessContainerClient, containerName: String, volumeName: String) async {
        // Explicit generated identities only: no pruning, all flags, or service commands.
        _ = try? await client.run(CommandRequest(arguments: ["stop", "--time", "1", containerName], suppressOutputEvents: true, timeout: .seconds(15)))
        _ = try? await client.run(CommandRequest(arguments: ["delete", "--force", containerName], suppressOutputEvents: true, timeout: .seconds(20)))
        if let remaining = try? await client.run(readOnly(["inspect", containerName])) {
            #expect(!remaining.succeeded, "The generated smoke container must be removed.")
        } else { Issue.record("Could not verify smoke container cleanup: \(containerName)") }
        if let volume = try? await client.run(readOnly(["volume", "inspect", volumeName])) {
            if volume.succeeded {
                let deletion = try? await client.run(CommandRequest(arguments: ["volume", "delete", volumeName], suppressOutputEvents: true, timeout: .seconds(20)))
                #expect(deletion?.succeeded == true, "The generated smoke volume must be removed.")
            }
        } else { Issue.record("Could not verify smoke volume cleanup: \(volumeName)") }
    }
}
