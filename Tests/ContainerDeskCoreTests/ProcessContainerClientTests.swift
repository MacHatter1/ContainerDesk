import Darwin
import Foundation
import Testing
@testable import ContainerDeskCore

@Suite(.serialized)
struct ProcessContainerClientTests {
    @Test func drainsFastProcessStdoutAndStderr() async throws {
        let client = try makeClient(script: "printf 'fast-output'; printf 'fast-error' >&2")
        let result = try await client.run(CommandRequest(arguments: []))
        #expect(result.succeeded)
        #expect(result.standardOutput == "fast-output")
        #expect(result.standardError == "fast-error")
    }

    @Test func drainsBeyondPipeCapacityAndReportsCaptureTruncation() async throws {
        let client = try makeClient(script: "head -c 131072 /dev/zero | tr '\\000' x")
        let result = try await client.run(CommandRequest(arguments: [], captureLimit: 2_048))
        #expect(result.succeeded)
        #expect(result.outputTruncated)
        #expect(result.standardOutput.count == 2_048)
    }

    @Test func slowStreamConsumerFailsExplicitlyWhenBoundedOutputBufferFills() async throws {
        let executable = try makeExecutable(script: "head -c 11534336 /dev/zero | tr '\\000' x")
        let execution = try ProcessExecutableClient(executableURL: executable).launch(CommandRequest(arguments: [], captureLimit: 1_024, timeout: .seconds(10)))
        try await waitForLeaderExit(execution)

        var sawOverflow = false
        do {
            for try await _ in execution.events {}
        } catch ContainerClientError.outputBufferExceeded {
            sawOverflow = true
        }
        #expect(sawOverflow)
        await execution.terminateAndWait()
    }

    @Test func slowConsumerCannotSilentlyLoseFinalProcessResult() async throws {
        let executable = try makeExecutable(script: "head -c 2097152 /dev/zero | tr '\\000' x")
        let execution = try ProcessExecutableClient(executableURL: executable).launch(CommandRequest(arguments: [], captureLimit: 1_024, timeout: .seconds(10)))
        try await waitForLeaderExit(execution)

        var sawOverflow = false
        do {
            for try await _ in execution.events {}
        } catch ContainerClientError.outputBufferExceeded {
            sawOverflow = true
        }
        #expect(sawOverflow)
        await execution.terminateAndWait()
    }

    @Test func quietLongLivedChildrenDoNotStarveFastCommandCompletion() async throws {
        let readyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesk-process-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: readyFolder, withIntermediateDirectories: true)
        let releaseFile = readyFolder.appendingPathComponent("release")
        defer {
            try? Data().write(to: releaseFile)
            try? FileManager.default.removeItem(at: readyFolder)
        }
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let readyFiles = (0..<6).map { readyFolder.appendingPathComponent("ready-\($0)") }
        let slowClients = try (0..<6).map { index in
            let waitForRelease = "counter=0; while [ ! -e \(shellQuote(releaseFile.path)) ] && [ $counter -lt 1500 ]; do sleep 0.01; counter=$((counter + 1)); done"
            return try makeClient(script: ": > \(shellQuote(readyFiles[index].path)); \(waitForRelease); printf 'slow-\(index)-finished'")
        }
        // `stream` launches its child synchronously. Retain each stream so the
        // process jobs stay alive while their children reach the ready barrier.
        let slowStreams = slowClients.map { $0.stream(CommandRequest(arguments: [])) }

        let readinessDeadline = Date.now.addingTimeInterval(15)
        while Date.now < readinessDeadline && !readyFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(readyFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Slow child processes did not reach the release barrier.")
        let fastClient = try makeClient(script: "printf fast-complete")
        let start = Date.now
        let fastResult = try await fastClient.run(CommandRequest(arguments: []))
        let elapsed = Date.now.timeIntervalSince(start)
        #expect(fastResult.succeeded)
        #expect(fastResult.standardOutput == "fast-complete")
        #expect(elapsed < 1.5)
        // Release is guaranteed before draining streams, including when assertions above fail.
        try Data().write(to: releaseFile)
        for stream in slowStreams {
            var succeeded = false
            for try await event in stream {
                if case .completed(let result) = event { succeeded = result.succeeded }
            }
            #expect(succeeded)
        }
    }

    @Test func spawnedCommandDoesNotInheritUnrelatedPipeWriter() async throws {
        var unrelatedPipe: [Int32] = [-1, -1]
        #expect(pipe(&unrelatedPipe) == 0)
        guard unrelatedPipe.allSatisfy({ $0 >= 0 }) else { return }
        defer { unrelatedPipe.forEach { if $0 >= 0 { _ = close($0) } } }
        let readFlags = fcntl(unrelatedPipe[0], F_GETFL)
        #expect(readFlags >= 0)
        #expect(fcntl(unrelatedPipe[0], F_SETFL, readFlags | O_NONBLOCK) == 0)

        let client = try makeClient(script: "sleep 2; printf child-finished")
        let childStream = client.stream(CommandRequest(arguments: []))
        _ = close(unrelatedPipe[1])
        unrelatedPipe[1] = -1

        let eofDeadline = Date.now.addingTimeInterval(1)
        var observedEOFBeforeChildExit = false
        while Date.now < eofDeadline {
            var byte: UInt8 = 0
            let count = read(unrelatedPipe[0], &byte, 1)
            if count == 0 {
                observedEOFBeforeChildExit = true
                break
            }
            if count < 0, errno != EAGAIN, errno != EINTR { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedEOFBeforeChildExit)

        var childSucceeded = false
        for try await event in childStream {
            if case .completed(let result) = event { childSucceeded = result.succeeded }
        }
        #expect(childSucceeded)
    }

    @Test func redactsSecretsAcrossReadsAndAvoidsPartialSecretAtCaptureLimit() async throws {
        let splitClient = try makeClient(script: "head -c 4095 /dev/zero | tr '\\000' A; printf 'SECRET'")
        var streamed = ""
        for try await event in splitClient.stream(CommandRequest(arguments: [], redactions: ["SECRET"])) {
            if case .standardOutput(let chunk) = event { streamed += chunk }
        }
        #expect(!streamed.contains("SECRET"))
        #expect(streamed.contains("••••"))

        let boundedClient = try makeClient(script: "printf 'prefix-SECRET-tail'")
        let result = try await boundedClient.run(CommandRequest(arguments: [], redactions: ["SECRET"], captureLimit: 10))
        #expect(result.outputTruncated)
        #expect(!result.standardOutput.contains("SEC"))
    }

    @Test func redactsSelfOverlappingAndOverlappingSecretsAtEveryChunking() {
        let cases: [(String, [String])] = [
            ("abab", ["abab"]),
            ("abcd", ["abc", "cd"]),
            ("abc", ["abc", "cd"]),
        ]
        for (value, secrets) in cases {
            let bytes = Array(value.utf8)
            for boundaryMask in 0..<(1 << max(0, bytes.count - 1)) {
                var redactor = StreamRedactor(secrets: secrets)
                var output = ""
                var chunkStart = 0
                for boundary in 0..<(bytes.count - 1) where boundaryMask & (1 << boundary) != 0 {
                    if let emitted = redactor.feed(Data(bytes[chunkStart...boundary])) { output += emitted }
                    chunkStart = boundary + 1
                }
                if chunkStart < bytes.count, let emitted = redactor.feed(Data(bytes[chunkStart...])) { output += emitted }
                if let emitted = redactor.finish() { output += emitted }
                #expect(!output.isEmpty && output.allSatisfy { $0 == "•" })
            }
        }

        let unicode = Array("🚀END".utf8)
        for boundaryMask in 0..<(1 << (unicode.count - 1)) {
            var redactor = StreamRedactor(secrets: ["🚀END"])
            var output = ""
            var chunkStart = 0
            for boundary in 0..<(unicode.count - 1) where boundaryMask & (1 << boundary) != 0 {
                if let emitted = redactor.feed(Data(unicode[chunkStart...boundary])) { output += emitted }
                chunkStart = boundary + 1
            }
            if chunkStart < unicode.count, let emitted = redactor.feed(Data(unicode[chunkStart...])) { output += emitted }
            if let emitted = redactor.finish() { output += emitted }
            #expect(!output.isEmpty && output.allSatisfy { $0 == "•" })
        }

        for (secretPrefix, secrets) in [("abc", ["abc", "cd"]), ("abab", ["abab"]) ] {
            var redactor = StreamRedactor(secrets: secrets)
            var output = redactor.feed(Data(secretPrefix.utf8)) ?? ""
            output += redactor.feed(Data("x".utf8)) ?? ""
            output += redactor.finish() ?? ""
            #expect(output == "••••x")
        }
    }

    @Test func repeatedOverlappingSecretsEmitAndKeepOnlyBoundedTail() {
        var redactor = StreamRedactor(secrets: ["aa"])
        let chunk = Data(repeating: 0x61, count: 4_096)
        var emittedChunks = 0
        for _ in 0..<128 {
            if let emitted = redactor.feed(chunk), !emitted.isEmpty { emittedChunks += 1 }
            #expect(redactor.bufferedByteCount <= 1)
        }
        #expect(emittedChunks > 0)
        if let tail = redactor.finish() { #expect(tail.isEmpty) }
    }

    @Test func aTimeoutCannotSucceedWhenTheChildHandlesTERMWithExitZero() async throws {
        let client = ProcessExecutableClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let result = try await client.run(CommandRequest(arguments: ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"], timeout: .milliseconds(100)))
        #expect(result.timedOut)
        #expect(result.exitCode == 0)
        #expect(!result.succeeded)
    }

    @Test func timeoutIsReportedSeparatelyFromOrdinaryExit() async throws {
        let client = try makeClient(script: "sleep 5")
        let result = try await client.run(CommandRequest(arguments: [], timeout: .milliseconds(50)))
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test func timeoutKillsOwnedWrapperChildAndClosesInheritedPipes() async throws {
        let client = try makeClient(script: "sleep 10 &\nwait")
        let start = ContinuousClock.now
        let result = try await client.run(CommandRequest(arguments: [], timeout: .milliseconds(100)))
        #expect(result.timedOut)
        #expect(start.duration(to: .now) < .seconds(6))
    }

    @Test func earlyChildExitWithStdinDoesNotDeliverProcessWideSIGPIPE() async throws {
        let client = try makeClient(script: "sleep 0.1; exit 0")
        let result = try await client.run(CommandRequest(arguments: [], stdin: Data(repeating: 66, count: 1_000_000), timeout: .seconds(10)))
        #expect(result.succeeded)
    }

    @Test func invalidUTF8StreamDoesNotAccumulateAndLaterTextStillArrives() async throws {
        let client = try makeClient(script: "head -c 100000 /dev/zero | tr '\\000' '\\377'; printf 'after-invalid-data'")
        var streamedTail = ""
        let request = CommandRequest(arguments: [], captureLimit: 1_024)
        for try await event in client.stream(request) {
            if case .standardOutput(let chunk) = event {
                streamedTail += chunk
                if streamedTail.count > 100 { streamedTail.removeFirst(streamedTail.count - 100) }
            }
        }
        #expect(streamedTail.contains("after-invalid-data"))
    }

    @Test func preservesUnicodeAcrossPipeReadBoundaries() async throws {
        let client = try makeClient(script: "head -c 4095 /dev/zero | tr '\\000' A; printf '🚀DONE'")
        let result = try await client.run(CommandRequest(arguments: []))
        #expect(result.standardOutput.hasSuffix("🚀DONE"))
    }

    @Test func streamsCompleteLineAndUnicodeScalarBeforeEOF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesk-stream-handshake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lineAck = folder.appendingPathComponent("line-seen")
        let scalarAck = folder.appendingPathComponent("scalar-seen")
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "printf 'complete-line\\n'; while [ ! -f \(shellQuote(lineAck.path)) ]; do sleep 0.01; done; printf '🚀'; while [ ! -f \(shellQuote(scalarAck.path)) ]; do sleep 0.01; done"
        let client = try makeClient(script: script)
        var observedOutput = ""
        var observedLine = false
        var observedScalar = false
        var commandResult: CommandResult?
        for try await event in client.stream(CommandRequest(arguments: [], timeout: .seconds(10))) {
            if case .standardOutput(let chunk) = event {
                observedOutput += chunk
                if !observedLine, observedOutput.contains("complete-line\n") {
                    observedLine = true
                    #expect(FileManager.default.createFile(atPath: lineAck.path, contents: Data()))
                }
                if chunk.contains("🚀") {
                    observedScalar = true
                    #expect(FileManager.default.createFile(atPath: scalarAck.path, contents: Data()))
                }
            } else if case .completed(let result) = event {
                commandResult = result
            }
        }
        #expect(commandResult?.succeeded == true)
        #expect(observedLine)
        #expect(observedScalar)
    }

    @Test func stdinAndWorkingDirectoryAreAppliedWithoutShellInterpolation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesk-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let client = try makeClient(script: "cat; printf '\\n'; pwd")
        let payload = Data(repeating: 65, count: 1_000_000)
        let result = try await client.run(CommandRequest(arguments: [], workingDirectory: folder, stdin: payload, captureLimit: 1_100_000))
        #expect(result.succeeded)
        let lines = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first?.count == 1_000_000)
        #expect(lines.dropLast().last?.hasSuffix(folder.lastPathComponent) == true)
    }

    private func makeClient(script: String) throws -> ProcessContainerClient {
        ProcessContainerClient(resolver: ExecutableResolver(overridePath: try makeExecutable(script: script).path))
    }

    private func makeExecutable(script: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("container")
        try ("#!/bin/sh\nset -eu\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func waitForLeaderExit(_ execution: ManagedProcessExecution) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while execution.isLeaderRunning, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!execution.isLeaderRunning, "The child did not exit or get canceled while producing the overflowing stream.")
    }
}
