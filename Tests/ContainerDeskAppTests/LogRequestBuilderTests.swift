import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct LogRequestBuilderTests {
    @Test func boundsSnapshotsAndKeepsMachineRouting() {
        let container = LogRequestBuilder.make(source: .container("--web"), mode: .snapshot)
        #expect(container.arguments == ["logs", "-n", "200", "--", "--web"])
        #expect(container.captureLimit == 500_000)
        #expect(container.suppressOutputEvents)
        let machine = LogRequestBuilder.make(source: .machine("desktop"), mode: .snapshot)
        #expect(machine.arguments == ["machine", "logs", "-n", "200", "--", "desktop"])
    }

    @Test func followsRecentTailWithoutCapturingAndResumesAtEnd() {
        for source in [LogRequestBuilder.Source.container("web"), .machine("desktop")] {
            let follow = LogRequestBuilder.make(source: source, mode: .follow)
            #expect(follow.arguments.contains("--follow"))
            #expect(follow.arguments.suffix(4).dropLast(2) == ["-n", "200"])
            #expect(follow.captureLimit == 0)
            #expect(!follow.suppressOutputEvents)
            let resume = LogRequestBuilder.make(source: source, mode: .resume)
            #expect(resume.arguments.suffix(4).dropLast(2) == ["-n", "0"])
            #expect(resume.captureLimit == 0)
        }
    }

    @Test(arguments: [false, true], [0, 250])
    func followsEmptyOrRecentLogsAndDeliversALaterLine(machine: Bool, historyCount: Int) async throws {
        let fixture = try LogProcessFixture()
        defer { fixture.remove() }
        let history = (0..<historyCount).map { "history \($0)\n" }
        try history.joined().write(to: fixture.log, atomically: false, encoding: .utf8)
        var request = LogRequestBuilder.make(source: machine ? .machine("fixture") : .container("fixture"), mode: .follow)
        request.environment = fixture.environment
        request.timeout = .seconds(5)
        let execution = try ProcessExecutableClient(executableURL: fixture.executable).launch(request)
        let recentHistory = history.suffix(200).joined()
        let (initialTail, initialTailContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            defer { initialTailContinuation.finish() }
            var output = ""
            for try await event in execution.events {
                if case .standardOutput(let chunk) = event {
                    output += chunk
                    if output == recentHistory { initialTailContinuation.yield(()) }
                    if output.contains("later line\n") { break }
                }
            }
            return output
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: fixture.ready.path), execution.isLeaderRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(FileManager.default.fileExists(atPath: fixture.ready.path), "The empty log must reach follow mode.")
            #expect(execution.isLeaderRunning)
            if !history.isEmpty { for await _ in initialTail { break } }
            let writer = try FileHandle(forWritingTo: fixture.log)
            try writer.seekToEnd()
            try writer.write(contentsOf: Data("later line\n".utf8))
            try writer.close()
            #expect(try await consumer.value == recentHistory + "later line\n")
            await execution.terminateAndWait()
        } catch {
            consumer.cancel()
            await execution.terminateAndWait()
            throw error
        }
    }

    @Test func snapshotReturnsOnlyTheMostRecent200Lines() async throws {
        let fixture = try LogProcessFixture()
        defer { fixture.remove() }
        let history = (1...250).map { "line \($0)\n" }
        try history.joined().write(to: fixture.log, atomically: false, encoding: .utf8)
        var request = LogRequestBuilder.make(source: .container("fixture"), mode: .snapshot)
        request.environment = fixture.environment
        let result = try await ProcessExecutableClient(executableURL: fixture.executable).run(request)
        #expect(result.succeeded)
        #expect(result.standardOutput == history.suffix(200).joined())
    }
}

private struct LogProcessFixture {
    let root: URL
    var executable: URL { root.appendingPathComponent("container") }
    var log: URL { root.appendingPathComponent("stdio.log") }
    var ready: URL { root.appendingPathComponent("following") }
    var environment: [String: String] { ["LOG_FILE": log.path, "READY_FILE": ready.path] }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LogRequest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: log)
        // Model the pinned CLI's empty-file exit when -n is absent, then use real tail I/O.
        try """
        #!/bin/sh
        if [ "$1" = machine ]; then shift; fi
        [ "$1" = logs ] || exit 2
        shift
        lines=
        follow=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --follow) follow=1; shift ;;
            -n) lines="$2"; shift 2 ;;
            --) shift; break ;;
            *) break ;;
          esac
        done
        [ "$1" = fixture ] || exit 2
        if [ -z "$lines" ] && [ ! -s "$LOG_FILE" ]; then exit 0; fi
        if [ -n "$follow" ]; then
          : > "$READY_FILE"
          exec /usr/bin/tail -n "${lines:-200}" -f "$LOG_FILE"
        fi
        if [ -n "$lines" ]; then exec /usr/bin/tail -n "$lines" "$LOG_FILE"; fi
        exec /bin/cat "$LOG_FILE"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
