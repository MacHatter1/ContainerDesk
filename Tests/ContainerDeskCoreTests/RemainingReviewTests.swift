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

    @Test func normalLeaderExitBoundsInheritedPipesWithoutCommandTimeout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NormalExitPipe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("pid")
        defer {
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        let script = "import os,sys,time; pid=os.fork();\nif pid == 0:\n os.setsid(); open(sys.argv[1], 'w').write(str(os.getpid())); time.sleep(30)\nelse:\n print('leader output', flush=True)\n"
        // The timeout bounds a stuck pipe; normal leader exit must finish without
        // timing out. Elapsed time also includes scheduling by parallel fixtures.
        let result = try await ProcessExecutableClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"))
            .run(.init(arguments: ["-c", script, marker.path], timeout: .seconds(3)))
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("leader output"))
        #expect(result.outputTruncated, "An inherited pipe cut off before EOF must be disclosed.")
    }
}
