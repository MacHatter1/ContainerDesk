import Darwin
import Foundation

/// Runs the installed CLI directly in an owned process group. It never invokes a shell.
public struct ProcessContainerClient: ContainerClient {
    public var resolver: ExecutableResolver
    public init(resolver: ExecutableResolver = ExecutableResolver()) { self.resolver = resolver }

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        try Task.checkCancellation()
        return try await launch(request).completedResult()
    }

    public func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        do { return try launch(request).events }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
    }

    public func launch(_ request: CommandRequest) throws -> ManagedProcessExecution {
        guard let executable = resolver.resolve() else { throw ContainerClientError.executableNotFound }
        return try ProcessExecutableClient(executableURL: executable).launch(request)
    }
}

/// Runs a specific executable with argv while reusing the app's bounded, cancellable process-group runner.
/// Unlike `ProcessContainerClient`, this client never searches for or invokes the Apple container CLI.
public struct ProcessExecutableClient: ContainerClient {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL.standardizedFileURL
    }

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        try Task.checkCancellation()
        return try await launch(request).completedResult()
    }

    public func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        do { return try launch(request).events }
        catch { return AsyncThrowingStream { $0.finish(throwing: ContainerClientError.launchFailed(request.redact(error.localizedDescription))) } }
    }

    /// Starts a process and returns an owned handle whose shutdown waits for waitpid and both pipe drains.
    public func launch(_ request: CommandRequest) throws -> ManagedProcessExecution {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw ContainerClientError.executableNotFound }
        let (stream, continuation) = AsyncThrowingStream<CommandEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let job = ProcessJob(executable: executableURL, request: request, continuation: continuation)
        continuation.onTermination = { @Sendable _ in job.cancel() }
        do { try job.launch() }
        catch { continuation.finish(throwing: ContainerClientError.launchFailed(request.redact(error.localizedDescription))); throw error }
        return ManagedProcessExecution(events: stream, isLeaderRunning: { job.isLeaderRunning }) { await job.terminateAndWait() }
    }
}

public struct ManagedProcessExecution: Sendable {
    public let events: AsyncThrowingStream<CommandEvent, Error>
    private let terminateBody: @Sendable () async -> Void
    private let leaderRunningBody: @Sendable () -> Bool

    public init(events: AsyncThrowingStream<CommandEvent, Error>, isLeaderRunning: @escaping @Sendable () -> Bool = { true }, terminateAndWait: @escaping @Sendable () async -> Void) {
        self.events = events
        self.leaderRunningBody = isLeaderRunning
        self.terminateBody = terminateAndWait
    }

    public var isLeaderRunning: Bool { leaderRunningBody() }
    public func terminateAndWait() async { await terminateBody() }
}

private extension ManagedProcessExecution {
    func completedResult() async throws -> CommandResult {
        let outcome: Result<CommandResult, any Error>
        do {
            var result: CommandResult?
            for try await event in events {
                if case .completed(let value) = event { result = value }
            }
            try Task.checkCancellation()
            guard let result else { throw ContainerClientError.launchFailed("The command ended without a result.") }
            outcome = .success(result)
        } catch { outcome = .failure(error) }
        // Stream iteration ends immediately on cancellation; process shutdown
        // does not. Keep callers suspended until TERM/KILL, waitpid and drains finish.
        await terminateAndWait()
        return try outcome.get()
    }
}

private final class ProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private let request: CommandRequest
    private let continuation: AsyncThrowingStream<CommandEvent, Error>.Continuation
    private let start = ContinuousClock.now
    private var pid: pid_t = 0
    private var stdoutFD: Int32 = -1
    private var stderrFD: Int32 = -1
    private var stdinFD: Int32 = -1
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutTruncated = false
    private var stderrTruncated = false
    private var finished = false
    private var streamBufferExceeded = false
    private var leaderExited = false
    private var timedOut = false
    private var timeoutTask: Task<Void, Never>?
    private let completionGroup = DispatchGroup()
    private let finishedGroup = DispatchGroup()

    init(executable: URL, request: CommandRequest, continuation: AsyncThrowingStream<CommandEvent, Error>.Continuation) {
        self.executable = executable
        self.request = request
        self.continuation = continuation
        finishedGroup.enter()
    }

    private let executable: URL

    func launch() throws {
        try ProcessDescriptorLock.withLock { try launchWhileProtectingDescriptors() }
    }

    private func launchWhileProtectingDescriptors() throws {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        var inputPipe: [Int32] = [-1, -1]
        let outPipeError = pipe(&outPipe)
        guard outPipeError == 0 else {
            closeIfOpen(outPipe[0]); closeIfOpen(outPipe[1])
            throw POSIXLaunchError(errno: errno)
        }
        do { try setCloseOnExec(outPipe) }
        catch { closeAll(outPipe); throw error }
        let errPipeError = pipe(&errPipe)
        guard errPipeError == 0 else {
            closeIfOpen(outPipe[0]); closeIfOpen(outPipe[1]); closeIfOpen(errPipe[0]); closeIfOpen(errPipe[1])
            throw POSIXLaunchError(errno: errno)
        }
        do { try setCloseOnExec(errPipe) }
        catch { closeAll(outPipe + errPipe); throw error }
        if request.stdin != nil, socketpair(AF_UNIX, SOCK_STREAM, 0, &inputPipe) != 0 {
            closeIfOpen(outPipe[0]); closeIfOpen(outPipe[1]); closeIfOpen(errPipe[0]); closeIfOpen(errPipe[1])
            throw POSIXLaunchError(errno: errno)
        }
        if request.stdin != nil {
            do { try setCloseOnExec(inputPipe) }
            catch { closeAll(outPipe + errPipe + inputPipe); throw error }
            var noSigPipe: Int32 = 1
            guard setsockopt(inputPipe[1], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                let issue = errno
                closeAll(outPipe + errPipe + inputPipe)
                throw POSIXLaunchError(errno: issue)
            }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionsError = posix_spawn_file_actions_init(&actions)
        guard actionsError == 0 else {
            closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: actionsError)
        }
        let attributesError = posix_spawnattr_init(&attributes)
        guard attributesError == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: attributesError)
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }

        let nullInput = request.stdin == nil ? open("/dev/null", O_RDONLY | O_CLOEXEC) : -1
        guard request.stdin != nil || nullInput >= 0 else { closeAll(outPipe + errPipe + inputPipe); throw POSIXLaunchError(errno: errno) }
        let childInput = request.stdin == nil ? nullInput : inputPipe[0]
        if let directory = request.workingDirectory {
            let chdirResult = directory.path.withCString { posix_spawn_file_actions_addchdir(&actions, $0) }
            guard chdirResult == 0 else {
                closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
                throw POSIXLaunchError(errno: chdirResult)
            }
        }
        let duplicateActions = [(childInput, STDIN_FILENO), (outPipe[1], STDOUT_FILENO), (errPipe[1], STDERR_FILENO)]
        for (source, destination) in duplicateActions {
            let actionError = posix_spawn_file_actions_adddup2(&actions, source, destination)
            guard actionError == 0 else {
                closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
                throw POSIXLaunchError(errno: actionError)
            }
        }
        for descriptor in outPipe + errPipe + inputPipe where descriptor >= 0 {
            let actionError = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard actionError == 0 else {
                closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
                throw POSIXLaunchError(errno: actionError)
            }
        }
        if nullInput >= 0 {
            let actionError = posix_spawn_file_actions_addclose(&actions, nullInput)
            guard actionError == 0 else {
                closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
                throw POSIXLaunchError(errno: actionError)
            }
        }
        var defaultSignals = sigset_t()
        let emptySignalsError = sigemptyset(&defaultSignals)
        guard emptySignalsError == 0 else {
            closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: errno)
        }
        let termSignalError = sigaddset(&defaultSignals, SIGTERM)
        let intSignalError = sigaddset(&defaultSignals, SIGINT)
        guard termSignalError == 0, intSignalError == 0 else {
            closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: errno)
        }
        let defaultSignalsError = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard defaultSignalsError == 0 else {
            closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: defaultSignalsError)
        }
        // Start children with an empty blocked-signal mask as well as default TERM/INT
        // dispositions. The app may block signals for its own DispatchSource handlers;
        // POSIX exec preserves that mask unless the spawn attributes replace it.
        var childSignalMask = sigset_t()
        let childSignalMaskInitError = sigemptyset(&childSignalMask)
        guard childSignalMaskInitError == 0 else {
            closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: errno)
        }
        let signalMaskError = posix_spawnattr_setsigmask(&attributes, &childSignalMask)
        guard signalMaskError == 0 else {
            closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: signalMaskError)
        }
        let attributeFlagsError = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        guard attributeFlagsError == 0 else {
            closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: attributeFlagsError)
        }
        let processGroupError = posix_spawnattr_setpgroup(&attributes, 0)
        guard processGroupError == 0 else {
            closeIfOpen(nullInput); closeAll(outPipe + errPipe + inputPipe)
            throw POSIXLaunchError(errno: processGroupError)
        }

        let argvStrings = [executable.path] + request.arguments
        let env = ExecutableResolver.normalizedEnvironment(additional: request.environment)
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        var childPID: pid_t = 0
        let errorCode = argvStrings.withCStringVector { argv in
            envStrings.withCStringVector { envp in
                posix_spawn(&childPID, executable.path, &actions, &attributes, argv, envp)
            }
        }
        closeIfOpen(nullInput)
        closeIfOpen(outPipe[1]); closeIfOpen(errPipe[1]); closeIfOpen(inputPipe[0])
        guard errorCode == 0 else {
            closeIfOpen(outPipe[0]); closeIfOpen(errPipe[0]); closeIfOpen(inputPipe[1])
            throw POSIXLaunchError(errno: errorCode)
        }
        lock.lock()
        pid = childPID; stdoutFD = outPipe[0]; stderrFD = errPipe[0]; stdinFD = inputPipe[1]
        lock.unlock()

        let readOutFD = outPipe[0]
        let readErrFD = errPipe[0]
        let spawnedPID = childPID
        // Pipe reads and waitpid intentionally block until this child progresses. Give
        // each one a dedicated thread so quiet commands cannot occupy the shared GCD pool.
        completionGroup.enter()
        Thread.detachNewThread { [self] in drain(fd: readOutFD, isError: false); completionGroup.leave() }
        completionGroup.enter()
        Thread.detachNewThread { [self] in drain(fd: readErrFD, isError: true); completionGroup.leave() }
        completionGroup.enter()
        Thread.detachNewThread { [self] in reap(spawnedPID); completionGroup.leave() }
        completionGroup.notify(queue: .global(qos: .utility)) { [self] in complete() }

        if let input = request.stdin {
            let fd = inputPipe[1]
            Thread.detachNewThread { [weak self] in
                writeAll(input, to: fd)
                closeIfOpen(fd)
                self?.lock.lock(); self?.stdinFD = -1; self?.lock.unlock()
            }
        }
        if let timeout = request.timeout {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.cancel(isTimeout: true)
            }
        }
    }

    private func drain(fd: Int32, isError: Bool) {
        var redactor = StreamRedactor(secrets: request.redactions)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            let data = Data(buffer.prefix(count))
            if let safeText = redactor.feed(data), !safeText.isEmpty { receive(safeText, isError: isError) }
        }
        if let safeText = redactor.finish(), !safeText.isEmpty { receive(safeText, isError: isError) }
        closeIfOpen(fd)
    }

    private func receive(_ text: String, isError: Bool) {
        let data = Data(text.utf8)
        lock.lock()
        if isError {
            let available = max(0, request.captureLimit - stderr.count)
            stderr.append(data.prefix(available)); stderrTruncated = stderrTruncated || data.count > available
        } else {
            let available = max(0, request.captureLimit - stdout.count)
            stdout.append(data.prefix(available)); stdoutTruncated = stdoutTruncated || data.count > available
        }
        lock.unlock()
        if !request.suppressOutputEvents {
            if case .dropped = continuation.yield(isError ? .standardError(text) : .standardOutput(text)) {
                lock.lock(); streamBufferExceeded = true; lock.unlock()
                cancel()
            }
        }
    }

    private func reap(_ childPID: pid_t) {
        var status: Int32 = 0
        while waitpid(childPID, &status, 0) < 0 && errno == EINTR {}
        lock.lock(); waitStatus = status; leaderExited = true; lock.unlock()
    }

    private var waitStatus: Int32 = 0

    private func complete() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let out = String(decoding: stdout, as: UTF8.self)
        let err = String(decoding: stderr, as: UTF8.self)
        let truncated = stdoutTruncated || stderrTruncated
        let status = waitStatus
        let didTimeout = timedOut
        let didOverflow = streamBufferExceeded
        lock.unlock()
        timeoutTask?.cancel()
        if didOverflow {
            continuation.finish(throwing: ContainerClientError.outputBufferExceeded)
            finishedGroup.leave()
            return
        }
        let exited = status & 0x7f == 0
        let exitCode = exited ? ((status >> 8) & 0xff) : (128 + (status & 0x7f))
        let result = CommandResult(standardOutput: out, standardError: err, exitCode: exitCode, terminationReason: exited ? .exit : .uncaughtSignal, duration: start.duration(to: .now), outputTruncated: truncated, timedOut: didTimeout)
        if case .dropped = continuation.yield(.completed(result)) {
            continuation.finish(throwing: ContainerClientError.outputBufferExceeded)
        } else {
            continuation.finish()
        }
        finishedGroup.leave()
    }

    func cancel(isTimeout: Bool = false) {
        lock.lock()
        let shouldTerminate = !finished && pid > 0
        let ownedGroup = pid
        timedOut = timedOut || isTimeout
        lock.unlock()
        guard shouldTerminate else { return }
        _ = kill(-ownedGroup, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let shouldKill = !self.finished && self.pid == ownedGroup; self.lock.unlock()
            if shouldKill { _ = kill(-ownedGroup, SIGKILL) }
        }
    }

    func terminateAndWait() async {
        cancel()
        await withCheckedContinuation { continuation in
            finishedGroup.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }
    }

    var isLeaderRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return pid > 0 && !leaderExited
    }

    private func closeAll(_ descriptors: [Int32]) { descriptors.forEach(closeIfOpen) }
}

private struct POSIXLaunchError: Error, LocalizedError {
    let errno: Int32
    var errorDescription: String? { String(cString: strerror(errno)) }
}

private func closeIfOpen(_ descriptor: Int32) {
    if descriptor >= 0 { _ = close(descriptor) }
}

private func setCloseOnExec(_ descriptors: [Int32]) throws {
    for descriptor in descriptors where descriptor >= 0 {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) >= 0 else {
            throw POSIXLaunchError(errno: errno)
        }
    }
}

private func writeAll(_ data: Data, to fd: Int32) {
    // Block SIGPIPE only on this writer thread so an early-closing child cannot terminate the app.
    var pipeSignal = sigset_t()
    sigemptyset(&pipeSignal)
    sigaddset(&pipeSignal, SIGPIPE)
    var previousMask = sigset_t()
    let maskInstalled = pthread_sigmask(SIG_BLOCK, &pipeSignal, &previousMask) == 0
    defer {
        if maskInstalled {
            var pending = sigset_t()
            if sigpending(&pending) == 0, sigismember(&pending, SIGPIPE) == 1 {
                var received: Int32 = 0
                _ = sigwait(&pipeSignal, &received)
            }
            _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil)
        }
    }
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let written = write(fd, base.advanced(by: offset), raw.count - offset)
            if written > 0 { offset += written }
            else if written < 0 && errno == EINTR { continue }
            else { break }
        }
    }
}

private extension Array where Element == String {
    func withCStringVector<R>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let vector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
        for (index, value) in enumerated() { vector[index] = strdup(value) }
        vector[count] = nil
        defer {
            for index in indices { free(vector[index]) }
            vector.deallocate()
        }
        return body(vector)
    }
}

/// Retains possible secret prefixes and incomplete UTF-8 scalars until the following read arrives.
struct StreamRedactor {
    private let secrets: [String]
    private var pending = Data()
    /// Bytes in `pending` already matched part of a secret. This matters when
    /// another, longer secret overlaps and later fails to complete.
    private var coveredPendingBytes: [Bool] = []
    private var redactionRunIsOpen = false

    var bufferedByteCount: Int { pending.count }

    init(secrets: [String]) { self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count } }

    mutating func feed(_ data: Data) -> String? {
        pending.append(data)
        coveredPendingBytes.append(contentsOf: repeatElement(false, count: data.count))
        let safeCount = utf8SafePrefixLength(pending, proposedCount: pending.count)
        guard safeCount > 0 else { return nil }
        let bytes = Array(pending.prefix(safeCount))
        let matches = mergedMatches(in: bytes)
        let overlap = longestSecretPrefixSuffixLength(in: bytes)
        let count = safeCount - overlap
        guard count > 0 else { return nil }
        let safeData = redactedPrefix(bytes, count: count, matches: matches, priorCoverage: coveredPendingBytes)
        for match in matches where match.upperBound > count {
            let start = max(count, match.lowerBound)
            for index in start..<min(safeCount, match.upperBound) { coveredPendingBytes[index] = true }
        }
        pending.removeFirst(count)
        coveredPendingBytes.removeFirst(count)
        return String(decoding: safeData, as: UTF8.self)
    }

    mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        defer {
            pending.removeAll(keepingCapacity: false)
            coveredPendingBytes.removeAll(keepingCapacity: false)
            redactionRunIsOpen = false
        }
        let bytes = Array(pending)
        let safeCount = utf8SafePrefixLength(pending, proposedCount: pending.count)
        let matches = mergedMatches(in: Array(bytes.prefix(safeCount)))
        let overlap = longestSecretPrefixSuffixLength(in: Array(bytes.prefix(safeCount)))
        var count = safeCount
        if overlap > 0 {
            let start = safeCount - overlap
            if !isCovered(start..<safeCount, by: matches, priorCoverage: coveredPendingBytes) { count = start }
        }
        let safeData = redactedPrefix(Array(bytes.prefix(safeCount)), count: count, matches: matches, priorCoverage: coveredPendingBytes)
        return String(decoding: safeData, as: UTF8.self)
    }

    private func longestSecretPrefixSuffixLength(in bytes: [UInt8]) -> Int {
        var longest = 0
        for secret in secrets {
            let secretBytes = Array(secret.utf8)
            guard secretBytes.count > 1 else { continue }
            let maximum = min(bytes.count, secretBytes.count - 1)
            guard maximum > longest else { continue }
            for length in stride(from: maximum, through: 1, by: -1) {
                if bytes.suffix(length).elementsEqual(secretBytes.prefix(length)) {
                    longest = length
                    break
                }
            }
        }
        return longest
    }

    private func mergedMatches(in bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for secret in secrets {
            let secretBytes = Array(secret.utf8)
            guard secretBytes.count <= bytes.count else { continue }
            for start in 0...(bytes.count - secretBytes.count) {
                if bytes[start..<(start + secretBytes.count)].elementsEqual(secretBytes) {
                    ranges.append(start..<(start + secretBytes.count))
                }
            }
        }
        ranges.sort { lhs, rhs in lhs.lowerBound == rhs.lowerBound ? lhs.upperBound < rhs.upperBound : lhs.lowerBound < rhs.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }

    private func isCovered(_ range: Range<Int>, by matches: [Range<Int>], priorCoverage: [Bool]) -> Bool {
        range.allSatisfy { index in
            (index < priorCoverage.count && priorCoverage[index]) || matches.contains { $0.contains(index) }
        }
    }

    private mutating func redactedPrefix(_ bytes: [UInt8], count: Int, matches: [Range<Int>], priorCoverage: [Bool]) -> Data {
        var output = Data()
        var index = 0
        while index < count {
            let isCovered = (index < priorCoverage.count && priorCoverage[index]) || matches.contains { $0.contains(index) }
            if isCovered {
                if !redactionRunIsOpen { output.append(contentsOf: "••••".utf8) }
                redactionRunIsOpen = true
                repeat {
                    index += 1
                } while index < count && ((index < priorCoverage.count && priorCoverage[index]) || matches.contains { $0.contains(index) })
            } else {
                redactionRunIsOpen = false
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }
}

private func utf8SafePrefixLength(_ data: Data, proposedCount: Int) -> Int {
    guard proposedCount > 0 else { return 0 }
    let bytes = data.prefix(proposedCount)
    var continuationCount = 0
    for byte in bytes.reversed() {
        if byte & 0b1100_0000 == 0b1000_0000 { continuationCount += 1 }
        else { break }
    }
    let leadOffset = bytes.count - continuationCount - 1
    guard leadOffset >= 0 else { return proposedCount }
    let lead = bytes[bytes.index(bytes.startIndex, offsetBy: leadOffset)]
    let expectedLength: Int
    switch lead {
    case 0xC2...0xDF: expectedLength = 2
    case 0xE0...0xEF: expectedLength = 3
    case 0xF0...0xF4: expectedLength = 4
    default: return proposedCount
    }
    return bytes.count - leadOffset < expectedLength ? leadOffset : proposedCount
}
