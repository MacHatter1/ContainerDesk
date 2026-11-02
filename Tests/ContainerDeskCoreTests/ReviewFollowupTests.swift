import Foundation
import Testing
@testable import ContainerDeskCore

struct ReviewFollowupTests {
    @Test func fastExitsAndTimeoutInstallationCanRaceWithoutLosingSuccess() async throws {
        let client = ProcessExecutableClient(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<16 {
                        let result = try await client.run(.init(arguments: [], captureLimit: 0, suppressOutputEvents: true, timeout: .seconds(30)))
                        #expect(result.succeeded && !result.timedOut)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test(arguments: [
        ["-X", "dev", "-m", "mlx_lm.server"],
        ["-Xdev", "-Wignore", "-u", "-m", "mlx_lm.server"],
        ["-W", "ignore::DeprecationWarning", "-X", "utf8", "/tools/mlx_lm.server"],
        ["-u", "-X", "dev", "-W", "default", "-m", "mlx_lm", "server"],
        ["--", "/tools/mlx_lm.server"],
    ])
    func pythonValueFlagsAreParsedBeforeTheServerCommand(flags: [String]) {
        #expect(MLXServerProcessIdentity.isServer(arguments: ["/framework/Python"] + flags))
    }

    @Test(arguments: [["-X"], ["-W"], ["--", "-m", "mlx_lm.server"], ["-X", "dev", "-m", "unrelated.server"], ["-Wignore", "-c", "import mlx_lm.server"]])
    func malformedFlagsAndPythonCodeAreNotClaimedAsServers(flags: [String]) {
        #expect(!MLXServerProcessIdentity.isServer(arguments: ["python3"] + flags))
    }

    @Test func OSCControlsAreStrippedAcrossChunksSourcesPipesAndLineBoundaries() {
        var logs = ContainerLogBuffer(maxBytes: 100)
        logs.append("before \u{1B}]8;;https://private", containerID: "web")
        logs.append("other\n", containerID: "db")
        logs.append("warning\n", containerID: "web", stderr: true)
        logs.append("/url\u{1B}", containerID: "web")
        logs.append("\\link 👩‍💻\u{1B}]8;;\u{1B}\\ after\n", containerID: "web")
        logs.append("\u{1B}]0;title\nnot visible\u{07}ready\n", containerID: "web")
        #expect(logs.entries.map(\.message) == ["other", "warning", "before link 👩‍💻 after", "ready"])
        #expect(!ContainerLogBuffer.export(logs.entries).contains("private"))
    }

    @Test func hugeUnterminatedOSCAndC1ControlsDoNotLeakOrFillTheLogBuffer() {
        var logs = ContainerLogBuffer(maxBytes: 64)
        logs.append("\u{9D}52;c;", containerID: "web")
        for _ in 0..<100 { logs.append(String(repeating: "secret", count: 1_000), containerID: "web") }
        logs.append("\u{9C}\u{9B}31mvisible\u{9B}0m\n", containerID: "web")
        #expect(logs.entries.map(\.message) == ["visible"])
        logs.append("\u{1B}]unterminated", containerID: "web")
        logs.finish(containerID: "web")
        logs.append("next stream\n", containerID: "web")
        #expect(logs.entries.last?.message == "next stream")
    }
}
