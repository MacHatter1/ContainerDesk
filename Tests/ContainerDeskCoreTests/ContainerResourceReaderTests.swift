import Foundation
import Testing
@testable import ContainerDeskCore

struct ContainerResourceReaderTests {
    @Test func onlyAppleContainerMajorOnePassesNativeGate() {
        #expect(NativeContainerAPIGate.isSupportedAppleContainerVersion(#"[{"appName":"container","version":"1.5.0"}]"#))
        #expect(NativeContainerAPIGate.isSupportedAppleContainerVersion(#"[{"appName":"container","version":"1.5.99"}]"#))
        #expect(!NativeContainerAPIGate.isSupportedAppleContainerVersion(#"[{"appName":"other","version":"1.5.0"}]"#))
        #expect(!NativeContainerAPIGate.isSupportedAppleContainerVersion(#"[{"appName":"container","version":"2.0.0"}]"#))
        #expect(!NativeContainerAPIGate.isSupportedAppleContainerVersion(#"[{"appName":"container","version":"1.4.1"}]"#))
        #expect(!NativeContainerAPIGate.isSupportedAppleContainerVersion("container 1.5.0"))
    }

    @Test func nativeContainerListUsesTypedReaderAndReportsProvenance() async throws {
        let cli = StubContainerClient()
        let summary = ResourceSummary(id: "native-id", title: "native-container", state: "running")
        let api = StubAppleContainerAPI(summaries: [summary])
        let reader = ContainerResourceReader(cli: cli, nativeAPI: api)

        let result = try await reader.list(.containers)

        #expect(result.backend == .nativeAPI)
        #expect(result.fallbackReason == nil)
        #expect(result.value == [summary])
        #expect(await api.listCallCount == 1)
        #expect(cli.requests.map(\.arguments) == [["system", "version", "--format", "json"]])
    }

    @Test func nativeFailureFallsBackToCuratedCLISnapshot() async throws {
        let cli = StubContainerClient(listJSON: #"[{"id":"cli-id","configuration":{"name":"cli-container"},"status":{"state":"running"}}]"#)
        let api = StubAppleContainerAPI(listError: StubError.failed)
        let reader = ContainerResourceReader(cli: cli, nativeAPI: api)

        let result = try await reader.list(.containers)

        #expect(result.backend == .cli)
        #expect(result.fallbackReason != nil)
        #expect(result.value.map(\.title) == ["cli-container"])
        #expect(cli.requests.map(\.arguments).contains(["list", "--all", "--format", "json"]))
    }

    @Test func customCLIOverrideDisablesNativeReader() async throws {
        let cli = StubContainerClient(listJSON: #"[{"id":"cli-image","configuration":{"name":"registry.invalid/demo:tag"}}]"#)
        let api = StubAppleContainerAPI()
        let reader = ContainerResourceReader(cli: cli, nativeAPI: api, nativeAllowed: false)

        let result = try await reader.list(.images)

        #expect(result.backend == .cli)
        #expect(result.fallbackReason == nil)
        #expect(await api.listCallCount == 0)
        #expect(cli.requests.map(\.arguments) == [["image", "list", "--format", "json", "--verbose"]])
    }

    @Test func nativeGateRequiresVerifiedMatchingCLIAndServerVersion() async {
        let cli15 = StubContainerClient(versionJSON: #"[{"appName":"container","version":"1.5.0"}]"#)
        let mismatch = await NativeContainerAPIGate().availability(
            using: cli15,
            api: StubAppleContainerAPI(serverVersion: "2.0.0"),
            enabled: true
        )
        #expect(!mismatch.allowed)
        #expect(mismatch.reason?.contains("matching") == true)

        let cli20 = StubContainerClient(versionJSON: #"[{"appName":"container","version":"2.0.0"}]"#)
        let wrongCLI = await NativeContainerAPIGate().availability(using: cli20, api: StubAppleContainerAPI(), enabled: true)
        #expect(!wrongCLI.allowed)

        let cli16 = StubContainerClient(versionJSON: #"[{"appName":"container","version":"1.6.0"}]"#)
        let matchingButUnsupported = await NativeContainerAPIGate().availability(
            using: cli16,
            api: StubAppleContainerAPI(serverVersion: "1.6.0"),
            enabled: true
        )
        #expect(!matchingButUnsupported.allowed)

        let badCLI = StubContainerClient(versionJSON: "unparseable")
        let malformed = await NativeContainerAPIGate().availability(using: badCLI, api: StubAppleContainerAPI(), enabled: true)
        #expect(!malformed.allowed)

        let missingServer = await NativeContainerAPIGate().availability(
            using: cli15,
            api: StubAppleContainerAPI(serverIdentityError: true),
            enabled: true
        )
        #expect(!missingServer.allowed)
    }

    @Test func nativeEndpointCooldownDoesNotDisableOtherEndpoints() async {
        let gate = NativeContainerAPIGate()
        await gate.recordNativeFailure(for: .networks)
        #expect(!(await gate.availability(for: .networks)).allowed)
        #expect((await gate.availability(for: .containers)).allowed)
        #expect((await gate.availability(for: .stats)).allowed)
    }

    @Test func gateCancellationDetachesDuringCLIAndServerProbes() async throws {
        let cliGate = NativeContainerAPIGate()
        let delayedCLI = StubContainerClient(versionDelay: .seconds(30))
        let api = StubAppleContainerAPI()
        let cliTask = Task { await cliGate.availability(using: delayedCLI, api: api, enabled: true) }
        while await cliGate.activeVersionProbeWaiterCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let cliCancelStarted = ContinuousClock.now
        cliTask.cancel()
        let cliDecision = await cliTask.value
        #expect(!cliDecision.allowed)
        #expect(cliCancelStarted.duration(to: .now) < .seconds(1))
        #expect(await api.serverIdentityCallCount == 0)

        let serverGate = NativeContainerAPIGate()
        let normalCLI = StubContainerClient()
        let delayedAPI = StubAppleContainerAPI(serverIdentityDelay: .seconds(30))
        let serverTask = Task { await serverGate.availability(using: normalCLI, api: delayedAPI, enabled: true) }
        while await delayedAPI.serverIdentityCallCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let serverCancelStarted = ContinuousClock.now
        serverTask.cancel()
        let serverDecision = await serverTask.value
        #expect(!serverDecision.allowed)
        #expect(serverCancelStarted.duration(to: .now) < .seconds(1))
    }

    @Test func oneCancelledGateWaiterDoesNotAbortTheOtherWaiter() async throws {
        let gate = NativeContainerAPIGate()
        let cli = StubContainerClient(versionDelay: .milliseconds(150))
        let api = StubAppleContainerAPI()
        let first = Task { await gate.availability(using: cli, api: api, enabled: true) }
        let second = Task { await gate.availability(using: cli, api: api, enabled: true) }
        while await gate.activeVersionProbeWaiterCount < 2 { try await Task.sleep(for: .milliseconds(5)) }

        first.cancel()
        let firstDecision = await first.value
        #expect(!firstDecision.allowed)
        while await gate.activeVersionProbeWaiterCount > 1 { try await Task.sleep(for: .milliseconds(5)) }
        let secondDecision = await second.value
        #expect(secondDecision.allowed)
        #expect(cli.requests.filter { $0.arguments == ["system", "version", "--format", "json"] }.count == 1)
        #expect(await api.serverIdentityCallCount == 1)
    }

    @Test func nativeStatsKeepPerContainerFailuresAndMonotonicSampleTime() async throws {
        let cli = StubContainerClient()
        let sample = ContainerStatsSample(id: "healthy", cpuUsageUsec: 20, memoryUsageBytes: 512, sampledAtUptimeNanoseconds: 900)
        let api = StubAppleContainerAPI(stats: ["healthy": sample], statsFailures: ["stopped"])
        let reader = ContainerResourceReader(cli: cli, nativeAPI: api)

        let result = try await reader.stats(ids: ["healthy", "stopped"])

        #expect(result.backend == .nativeAPI, "Fallback reason: \(result.fallbackReason ?? "none")")
        #expect(result.value == [sample])
        #expect(result.value.first?.sampledAtUptimeNanoseconds == 900)
        #expect(result.failures["stopped"] != nil)
        #expect(!cli.requests.map(\.arguments).contains(["stats", "--no-stream", "--format", "json"]))
    }

    @Test func cliStatsFallbackIgnoresStaleIDsWithoutDroppingHealthySamples() async throws {
        let healthyJSON = #"[{"id":"healthy","cpuUsageUsec":100,"memoryUsageBytes":2048}]"#
        let cli = StubContainerClient(statsJSON: healthyJSON)
        let api = StubAppleContainerAPI(statsFailures: ["healthy", "stale"])
        let reader = ContainerResourceReader(cli: cli, nativeAPI: api, gate: NativeContainerAPIGate(failureCooldown: 0))

        let result = try await reader.stats(ids: ["healthy", "stale"])

        #expect(result.backend == .cli)
        #expect(result.value.map(\.id) == ["healthy"])
        #expect(cli.requests.map(\.arguments).contains(["stats", "--no-stream", "--format", "json"]))
        #expect(!cli.requests.map(\.arguments).contains(where: { $0.first == "stats" && $0.contains("stale") }))
    }

    @Test func nativeStatsMergeSamplesAndFailuresAcrossBatches() async throws {
        let cli = StubContainerClient()
        let samples = ["b", "e", "f"].map {
            ContainerStatsSample(id: $0, cpuUsageUsec: 20, memoryUsageBytes: 512, sampledAtUptimeNanoseconds: 900)
        }
        let api = StubAppleContainerAPI(
            stats: Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) }),
            statsFailures: ["a", "c", "d"]
        )
        let reader = ContainerResourceReader(cli: cli, nativeAPI: api)

        let result = try await reader.stats(ids: ["f", "a", "e", "d", "c", "b"])

        #expect(result.backend == .nativeAPI, "Fallback reason: \(result.fallbackReason ?? "none")")
        #expect(result.value == samples)
        #expect(Set(result.failures.keys) == ["a", "c", "d"])
        #expect(!cli.requests.map(\.arguments).contains(["stats", "--no-stream", "--format", "json"]))
    }

    @Test func cliInspectRedactsEnvironmentArgsAndCredentialFields() async throws {
        let cli = StubContainerClient(inspectJSON: #"{"configuration":{"initProcess":{"environment":["API_TOKEN=env-private","MODE=test"],"arguments":["--password","arg-private","--token=flag-private"]},"registryPassword":"field-private"}}"#)
        let reader = ContainerResourceReader(cli: cli, nativeAPI: nil)

        let result = try await reader.inspectContainer(id: "fixture-id")

        #expect(result.backend == .cli)
        #expect(!result.value.json.contains("env-private"))
        #expect(!result.value.json.contains("arg-private"))
        #expect(!result.value.json.contains("flag-private"))
        #expect(!result.value.json.contains("field-private"))
        #expect(result.value.json.contains("MODE=••••"))
    }

    @Test func cancellationDuringNativeReadDoesNotStartCLIRead() async throws {
        let cli = StubContainerClient()
        let api = StubAppleContainerAPI(delayList: true)
        let reader = ContainerResourceReader(cli: cli, nativeAPI: api)
        let readTask = Task { try await reader.list(.containers) }
        while await api.listCallCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        readTask.cancel()

        do {
            _ = try await readTask.value
            Issue.record("Expected cancellation to propagate.")
        } catch is CancellationError { }
        #expect(cli.requests.map(\.arguments) == [["system", "version", "--format", "json"]])
    }

    @Test func neverReplyNativeRequestIsClosedOnTimeoutAndCancellation() async throws {
        let timed = NeverReplyRequest()
        do {
            _ = try await BoundedNativeRequest.run(timeout: .milliseconds(40), operation: { try await timed.wait() }, cancel: { Task { await timed.close() } })
            Issue.record("Expected the native request timeout.")
        } catch is NativeAPITimeout { }
        while await timed.closeCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await timed.closeCount == 1)

        let cancelled = NeverReplyRequest()
        let task = Task {
            try await BoundedNativeRequest.run(timeout: .seconds(20), operation: { try await cancelled.wait() }, cancel: { Task { await cancelled.close() } })
        }
        while !(await cancelled.started) { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected native request cancellation.")
        } catch is CancellationError { }
        while await cancelled.closeCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await cancelled.closeCount == 1)
    }
}

private enum StubError: Error { case failed }

private actor NeverReplyRequest {
    private var continuation: CheckedContinuation<Int, Error>?
    private var wasClosed = false
    private(set) var started = false
    private(set) var closeCount = 0

    func wait() async throws -> Int {
        started = true
        if wasClosed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in self.continuation = continuation }
    }

    func close() {
        closeCount += 1
        wasClosed = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private final class StubContainerClient: ContainerClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [CommandRequest] = []
    private let listJSON: String
    private let versionJSON: String
    private let inspectJSON: String
    private let statsJSON: String
    private let versionDelay: Duration

    init(
        listJSON: String = "[]",
        versionJSON: String = #"[{"appName":"container","version":"1.5.0"}]"#,
        inspectJSON: String = "{}",
        statsJSON: String = "[]",
        versionDelay: Duration = .zero
    ) {
        self.listJSON = listJSON
        self.versionJSON = versionJSON
        self.inspectJSON = inspectJSON
        self.statsJSON = statsJSON
        self.versionDelay = versionDelay
    }

    var requests: [CommandRequest] { lock.withLock { recordedRequests } }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        lock.withLock { recordedRequests.append(request) }
        let output: String
        if request.arguments == ["system", "version", "--format", "json"] {
            if versionDelay > .zero { try await Task.sleep(for: versionDelay) }
            output = versionJSON
        } else if request.arguments.first == "inspect" {
            output = inspectJSON
        } else if request.arguments.first == "stats" {
            output = statsJSON
        } else {
            output = listJSON
        }
        return CommandResult(standardOutput: output, standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await run(request)
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}

private actor StubAppleContainerAPI: AppleContainerResourceAPI {
    private let summaries: [ResourceSummary]
    private let listError: Error?
    private let statsByID: [String: ContainerStatsSample]
    private let statsFailures: Set<String>
    private let delayList: Bool
    private let serverVersion: String
    private let serverIdentityError: Bool
    private let serverIdentityDelay: Duration
    private(set) var listCallCount = 0
    private(set) var serverIdentityCallCount = 0

    func serverIdentity() async throws -> NativeAPIServerIdentity {
        serverIdentityCallCount += 1
        if serverIdentityDelay > .zero { try await Task.sleep(for: serverIdentityDelay) }
        if serverIdentityError { throw StubError.failed }
        return NativeAPIServerIdentity(appName: "container-apiserver", version: serverVersion)
    }

    init(
        summaries: [ResourceSummary] = [],
        listError: Error? = nil,
        stats: [String: ContainerStatsSample] = [:],
        statsFailures: Set<String> = [],
        delayList: Bool = false,
        serverVersion: String = "1.5.0",
        serverIdentityError: Bool = false,
        serverIdentityDelay: Duration = .zero
    ) {
        self.summaries = summaries
        self.listError = listError
        self.statsByID = stats
        self.statsFailures = statsFailures
        self.delayList = delayList
        self.serverVersion = serverVersion
        self.serverIdentityError = serverIdentityError
        self.serverIdentityDelay = serverIdentityDelay
    }

    func list(_ section: ContainerSection) async throws -> [ResourceSummary] {
        listCallCount += 1
        if delayList { try await Task.sleep(for: .seconds(30)) }
        if let listError { throw listError }
        return summaries
    }

    func inspectContainer(id: String) async throws -> SanitizedContainerInspection {
        SanitizedContainerInspection(containerID: id, json: "{}")
    }

    func stats(id: String) async throws -> ContainerStatsSample {
        if statsFailures.contains(id) { throw StubError.failed }
        guard let sample = statsByID[id] else { throw StubError.failed }
        return sample
    }
}
