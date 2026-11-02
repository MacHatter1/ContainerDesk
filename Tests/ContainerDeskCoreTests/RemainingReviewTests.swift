import Darwin
import Foundation
import Testing
@testable import ContainerDeskCore

struct RemainingReviewCoreTests {
    @Test(arguments: ["\\\n", "  \\\n  ", "echo \\\n word", "echo a\\\nb", "echo \"\\\n\"", "echo '' \\\n"])
    func lineContinuationDoesNotCreateAnArgument(input: String) throws {
        let expected: [String]
        switch input {
        case "\\\n", "  \\\n  ": expected = []
        case "echo \\\n word": expected = ["echo", "word"]
        case "echo a\\\nb": expected = ["echo", "ab"]
        default: expected = ["echo", ""]
        }
        #expect(try ContainerCommandTokenizer.tokenize(input) == expected)
    }

    @Test(.timeLimit(.minutes(1))) func normalLeaderExitBoundsInheritedPipesWithoutCommandTimeout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NormalExitPipe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("pid")
        defer {
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        // Normal exit does not kill the process group, so a native shell and
        // background sleep can hold the pipes without a cold Python startup.
        let script = "/bin/sleep 30 & child=$!; printf '%s\\n' \"$child\" > \"$1\"; printf 'leader output\\n'"
        let result = try await ProcessExecutableClient(executableURL: URL(fileURLWithPath: "/bin/sh"), registry: ProcessRegistry())
            .run(.init(arguments: ["-c", script, "pipe-fixture", marker.path], timeout: .seconds(15)))
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("leader output"))
        #expect(result.outputTruncated, "An inherited pipe cut off before EOF must be disclosed.")
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0, "The pipe holder must still be alive when the command completes.")
    }
}
