import ContainerAPIClient
import ContainerResource
import ContainerXPC
import Foundation

public enum ResourceReadBackend: String, Sendable, Equatable {
    case nativeAPI
    case cli
}

public struct ResourceReadResult<Value: Sendable>: Sendable {
    public let value: Value
    public let backend: ResourceReadBackend
    public let fallbackReason: String?
    /// Per-resource failures are retained when a multi-resource native request partially succeeds.
    public let failures: [String: String]

    public init(value: Value, backend: ResourceReadBackend, fallbackReason: String? = nil, failures: [String: String] = [:]) {
        self.value = value
        self.backend = backend
        self.fallbackReason = fallbackReason
        self.failures = failures
    }
}

public struct SanitizedContainerInspection: Sendable, Equatable {
    public let containerID: String
    /// Pretty JSON with environment values and credential-shaped fields redacted before it leaves Core.
    public let json: String

    public init(containerID: String, json: String) {
        self.containerID = containerID
        self.json = json
    }
}

/// Narrow seam around Apple's public ContainerAPIClient; test doubles can verify routing without XPC.
public protocol AppleContainerResourceAPI: Sendable {
    func serverIdentity() async throws -> NativeAPIServerIdentity
    func list(_ section: ContainerSection) async throws -> [ResourceSummary]
    func inspectContainer(id: String) async throws -> SanitizedContainerInspection
    func stats(id: String) async throws -> ContainerStatsSample
}

public struct NativeAPIServerIdentity: Sendable, Equatable {
    public let appName: String
    public let version: String
    public init(appName: String, version: String) { self.appName = appName; self.version = version }
}

public enum ContainerResourceReaderError: Error, LocalizedError {
    case commandFailed(String)
    case truncatedOutput
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .truncatedOutput: "The container CLI response exceeded the safe decode limit."
        case .invalidPayload: "The container CLI returned an unexpected resource response."
        }
    }
}

/// Reads resource data through Apple's stable, public API where available and falls back to the CLI.
/// Mutations and all unsupported/plugin resources remain on the CLI management path.
public struct ContainerResourceReader: Sendable {
    private let cli: any ContainerClient
    private let nativeAPI: (any AppleContainerResourceAPI)?
    private let nativeAllowed: Bool
    private let gate: NativeContainerAPIGate

    /// Set `nativeAllowed` to false for a user-selected CLI override; the override remains authoritative.
    public init(
        cli: any ContainerClient,
        nativeAPI: (any AppleContainerResourceAPI)? = AppleContainerResourceAPIClient(),
        nativeAllowed: Bool = true,
        gate: NativeContainerAPIGate = NativeContainerAPIGate()
    ) {
        self.cli = cli
        self.nativeAPI = nativeAPI
        self.nativeAllowed = nativeAllowed
        self.gate = gate
    }

    public func list(_ section: ContainerSection) async throws -> ResourceReadResult<[ResourceSummary]> {
        if Self.nativeListSections.contains(section), let nativeAPI {
            let kind = NativeAPIReadKind.list(section)
            var decision = await gate.availability(using: cli, api: nativeAPI, enabled: nativeAllowed)
            if decision.allowed { decision = await gate.availability(for: kind) }
            guard !Task.isCancelled else { throw CancellationError() }
            if decision.allowed {
                do {
                    let items = try await nativeAPI.list(section)
                    try Task.checkCancellation()
                    return ResourceReadResult(value: items, backend: .nativeAPI)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    await gate.recordNativeFailure(for: kind)
                    return try await cliList(section, fallbackReason: "Native API read failed; showing CLI data.")
                }
            }
            return try await cliList(section, fallbackReason: decision.reason)
        }
        return try await cliList(section, fallbackReason: nil)
    }

    public func inspectContainer(id: String) async throws -> ResourceReadResult<SanitizedContainerInspection> {
        if let nativeAPI {
            let kind = NativeAPIReadKind.inspect
            var decision = await gate.availability(using: cli, api: nativeAPI, enabled: nativeAllowed)
            if decision.allowed { decision = await gate.availability(for: kind) }
            guard !Task.isCancelled else { throw CancellationError() }
            if decision.allowed {
                do {
                    let inspection = try await nativeAPI.inspectContainer(id: id)
                    try Task.checkCancellation()
                    return ResourceReadResult(value: inspection, backend: .nativeAPI)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    await gate.recordNativeFailure(for: kind)
                    return try await cliInspect(id: id, fallbackReason: "Native API read failed; showing CLI data.")
                }
            }
            return try await cliInspect(id: id, fallbackReason: decision.reason)
        }
        return try await cliInspect(id: id, fallbackReason: nil)
    }

    public func stats(ids: [String]) async throws -> ResourceReadResult<[ContainerStatsSample]> {
        let requestedIDs = Array(Set(ids)).sorted()
        guard !requestedIDs.isEmpty else { return ResourceReadResult(value: [], backend: .cli) }

        if let nativeAPI {
            let kind = NativeAPIReadKind.stats
            var decision = await gate.availability(using: cli, api: nativeAPI, enabled: nativeAllowed)
            if decision.allowed { decision = await gate.availability(for: kind) }
            guard !Task.isCancelled else { throw CancellationError() }
            if decision.allowed {
                let (samples, failures) = try await nativeStats(nativeAPI, ids: requestedIDs)
                try Task.checkCancellation()
                if !samples.isEmpty || requestedIDs.isEmpty {
                    return ResourceReadResult(value: samples, backend: .nativeAPI, failures: failures)
                }
                await gate.recordNativeFailure(for: kind)
                return try await cliStats(ids: requestedIDs, fallbackReason: "Native stats read failed; showing CLI data.")
            }
            return try await cliStats(ids: requestedIDs, fallbackReason: decision.reason)
        }
        return try await cliStats(ids: requestedIDs, fallbackReason: nil)
    }

    private static let nativeListSections: Set<ContainerSection> = [.containers, .volumes, .networks]

    private func cliList(_ section: ContainerSection, fallbackReason: String?) async throws -> ResourceReadResult<[ResourceSummary]> {
        guard let arguments = Self.listArguments(for: section) else {
            return ResourceReadResult(value: [], backend: .cli, fallbackReason: fallbackReason)
        }
        let result = try await runRead(arguments)
        let summaries = try ResourceJSONDecoder.summaries(from: Data(result.standardOutput.utf8), section: section)
        return ResourceReadResult(value: summaries, backend: .cli, fallbackReason: fallbackReason)
    }

    private func cliInspect(id: String, fallbackReason: String?) async throws -> ResourceReadResult<SanitizedContainerInspection> {
        let result = try await runRead(["inspect", id])
        let safeJSON = try SensitiveJSONRedactor.redact(result.standardOutput)
        return ResourceReadResult(value: SanitizedContainerInspection(containerID: id, json: safeJSON), backend: .cli, fallbackReason: fallbackReason)
    }

    private func cliStats(ids: [String], fallbackReason: String?) async throws -> ResourceReadResult<[ContainerStatsSample]> {
        // A snapshot ID can disappear between the list and stats calls. Asking for all
        // currently running samples avoids one stale ID failing the entire CLI request.
        let result = try await runRead(["stats", "--no-stream", "--format", "json"])
        let requested = Set(ids)
        let samples = try ContainerStatsJSONDecoder.samples(from: Data(result.standardOutput.utf8)).filter { requested.contains($0.id) }
        return ResourceReadResult(value: samples, backend: .cli, fallbackReason: fallbackReason)
    }

    private func nativeStats(_ api: any AppleContainerResourceAPI, ids: [String]) async throws -> ([ContainerStatsSample], [String: String]) {
        var samples: [ContainerStatsSample] = []
        var failures: [String: String] = [:]
        // XPC stats requests are independent; cap fan-out so a large container set does not
        // create an unbounded number of connections or server requests.
        for offset in stride(from: 0, to: ids.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(ids[offset..<min(offset + 4, ids.count)])
            await withTaskGroup(of: (String, Result<ContainerStatsSample, Error>).self) { group in
                for id in batch {
                    group.addTask {
                        do { return (id, .success(try await api.stats(id: id))) }
                        catch { return (id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    switch result {
                    case .success(let sample): samples.append(sample)
                    case .failure(let error):
                        if error is CancellationError { continue }
                        failures[id] = "Statistics are unavailable for this container."
                    }
                }
            }
        }
        try Task.checkCancellation()
        return (samples.sorted { $0.id < $1.id }, failures)
    }

    private func runRead(_ arguments: [String]) async throws -> CommandResult {
        try Task.checkCancellation()
        let result = try await cli.run(CommandRequest(arguments: arguments, captureLimit: 2_000_000, suppressOutputEvents: true, timeout: .seconds(30)))
        try Task.checkCancellation()
        guard result.succeeded else { throw ContainerResourceReaderError.commandFailed("The container CLI read failed with status \(result.exitCode).") }
        guard !result.outputTruncated else { throw ContainerResourceReaderError.truncatedOutput }
        return result
    }

    private static func listArguments(for section: ContainerSection) -> [String]? {
        switch section {
        case .containers: ["list", "--all", "--format", "json"]
        case .images: ["image", "list", "--format", "json", "--verbose"]
        case .volumes: ["volume", "list", "--format", "json"]
        case .networks: ["network", "list", "--format", "json"]
        case .registries: ["registry", "list", "--format", "json"]
        case .machines: ["machine", "list", "--format", "json"]
        default: nil
        }
    }
}

/// Cached version eligibility and a short native-failure cooldown prevent repeated XPC/help probes.
public actor NativeContainerAPIGate {
    private var cachedDecision: NativeAPIGateDecision?
    private var lastVersionProbe: Date?
    private var operationFailures: [NativeAPIReadKind: Date] = [:]
    private var versionProbe: VersionProbe?
    private var versionProbeWaiters: [UUID: (probeID: UUID, waiter: GateProbeWaiter)] = [:]
    private let cacheDuration: TimeInterval
    private let failureCooldown: TimeInterval

    public init(cacheDuration: TimeInterval = 60, failureCooldown: TimeInterval = 15) {
        self.cacheDuration = cacheDuration
        self.failureCooldown = failureCooldown
    }

    var activeVersionProbeWaiterCount: Int { versionProbeWaiters.count }

    public func availability(using cli: any ContainerClient, api: any AppleContainerResourceAPI, enabled: Bool) async -> NativeAPIGateDecision {
        guard !Task.isCancelled else { return NativeAPIGateDecision(allowed: false, reason: "Native API check was cancelled.") }
        guard enabled else { return NativeAPIGateDecision(allowed: false, reason: "Native reads are disabled for the selected CLI path.") }
        if let cachedDecision, let lastVersionProbe, Date.now.timeIntervalSince(lastVersionProbe) < cacheDuration {
            return cachedDecision
        }
        let probe: VersionProbe
        if let versionProbe {
            probe = versionProbe
        } else {
            let probeID = UUID()
            let task = Task {
                do {
                    let result = try await cli.run(CommandRequest(arguments: ["system", "version", "--format", "json"], captureLimit: 128_000, suppressOutputEvents: true, timeout: .seconds(10)))
                    try Task.checkCancellation()
                    guard result.succeeded, !result.outputTruncated,
                          let cliVersion = Self.appleContainerVersion(result.standardOutput) else {
                        return NativeAPIGateDecision(allowed: false, reason: "Native reads require a verified Apple container 1.5.x CLI.")
                    }
                    guard cliVersion.0 == 1, cliVersion.1 == 5 else {
                        return NativeAPIGateDecision(allowed: false, reason: "The native client is pinned to Apple container 1.5.x; using CLI reads.")
                    }
                    let server = try await api.serverIdentity()
                    try Task.checkCancellation()
                    let serverVersion = Self.versionFamily(server.version)
                    guard server.appName.localizedCaseInsensitiveContains("container"),
                          serverVersion?.0 == 1, serverVersion?.1 == 5,
                          serverVersion?.0 == cliVersion.0, serverVersion?.1 == cliVersion.1 else {
                        return NativeAPIGateDecision(allowed: false, reason: "Native reads require matching Apple container CLI and API server 1.5.x versions.")
                    }
                    return NativeAPIGateDecision(allowed: true, reason: nil)
                } catch is CancellationError {
                    return NativeAPIGateDecision(allowed: false, reason: "Native API check was cancelled.")
                } catch {
                    return NativeAPIGateDecision(allowed: false, reason: "Could not verify the Apple container API server; using CLI reads.")
                }
            }
            probe = VersionProbe(id: probeID, task: task)
            versionProbe = probe
        }
        let waiterID = UUID()
        let waiter = GateProbeWaiter()
        versionProbeWaiters[waiterID] = (probe.id, waiter)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waiter.install(continuation) else { return }
                Task { [weak self] in
                    let decision = await probe.task.value
                    await self?.finishProbe(probeID: probe.id, waiterID: waiterID, decision: decision)
                }
            }
        } onCancel: {
            waiter.complete(NativeAPIGateDecision(allowed: false, reason: "Native API check was cancelled."))
            Task { await self.cancelProbeWaiter(waiterID, probeID: probe.id) }
        }
    }

    private func finishProbe(probeID: UUID, waiterID: UUID, decision: NativeAPIGateDecision) {
        guard let registration = versionProbeWaiters[waiterID], registration.probeID == probeID else { return }
        versionProbeWaiters[waiterID] = nil
        if versionProbe?.id == probeID {
            versionProbe = nil
            cachedDecision = decision
            lastVersionProbe = .now
            operationFailures.removeAll()
        }
        registration.waiter.complete(decision)
    }

    private func cancelProbeWaiter(_ waiterID: UUID, probeID: UUID) {
        guard let registration = versionProbeWaiters[waiterID], registration.probeID == probeID else { return }
        versionProbeWaiters[waiterID] = nil
        let hasOtherWaiters = versionProbeWaiters.values.contains { $0.probeID == probeID }
        if !hasOtherWaiters, versionProbe?.id == probeID {
            versionProbe?.task.cancel()
            versionProbe = nil
        }
    }

    public func availability(for kind: NativeAPIReadKind) -> NativeAPIGateDecision {
        guard let until = operationFailures[kind], Date.now < until else {
            operationFailures[kind] = nil
            return NativeAPIGateDecision(allowed: true, reason: nil)
        }
        return NativeAPIGateDecision(allowed: false, reason: "The native \(kind.label) endpoint is temporarily unavailable; using CLI reads.")
    }

    public func recordNativeFailure(for kind: NativeAPIReadKind) {
        operationFailures[kind] = .now.addingTimeInterval(failureCooldown)
    }

    public static func isSupportedAppleContainerVersion(_ source: String) -> Bool {
        guard let family = appleContainerVersion(source) else { return false }
        return family.0 == 1 && family.1 == 5
    }

    private static func appleContainerVersion(_ source: String) -> (Int, Int)? {
        guard let data = source.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows = (root as? [[String: Any]]) ?? ((root as? [String: Any]).map { [$0] } ?? [])
        return rows.compactMap { row -> (Int, Int)? in
            guard let name = row["appName"] as? String, name.localizedCaseInsensitiveContains("container"),
                  let version = row["version"] as? String,
                  let family = versionFamily(version) else { return nil }
            return family
        }.first
    }

    private static func versionFamily(_ version: String) -> (Int, Int)? {
        let components = version.split(separator: ".")
        guard components.count >= 2, let major = Int(components[0]), let minor = Int(components[1]) else { return nil }
        return (major, minor)
    }
}

private struct VersionProbe: Sendable {
    let id: UUID
    let task: Task<NativeAPIGateDecision, Never>
}

private final class GateProbeWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NativeAPIGateDecision, Never>?
    private var outcome: NativeAPIGateDecision?

    func install(_ continuation: CheckedContinuation<NativeAPIGateDecision, Never>) -> Bool {
        let outcome = lock.withLock { () -> NativeAPIGateDecision? in
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let outcome {
            continuation.resume(returning: outcome)
            return false
        }
        return true
    }

    @discardableResult
    func complete(_ outcome: NativeAPIGateDecision) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<NativeAPIGateDecision, Never>? in
            guard self.outcome == nil else { return nil }
            self.outcome = outcome
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(returning: outcome)
        return true
    }
}

public enum NativeAPIReadKind: Hashable, Sendable {
    case containers
    case volumes
    case networks
    case inspect
    case stats

    static func list(_ section: ContainerSection) -> NativeAPIReadKind {
        switch section {
        case .containers: .containers
        case .volumes: .volumes
        case .networks: .networks
        default: .containers
        }
    }

    var label: String {
        switch self {
        case .containers: "container list"
        case .volumes: "volume list"
        case .networks: "network list"
        case .inspect: "container inspect"
        case .stats: "container stats"
        }
    }
}

public struct NativeAPIGateDecision: Sendable, Equatable {
    public let allowed: Bool
    public let reason: String?
    public init(allowed: Bool, reason: String?) { self.allowed = allowed; self.reason = reason }
}

private enum SensitiveJSONRedactor {
    private static let sensitiveFragments = ["password", "passwd", "token", "secret", "authorization", "credential", "privatekey", "accesskey", "apikey"]
    private static let assignment = try! NSRegularExpression(pattern: #"(?i)((?:[A-Z0-9_.-]*(?:password|passwd|token|secret|authorization|api[_-]?key|access[_-]?key|private[_-]?key)[A-Z0-9_.-]*)\s*=\s*)[^,;\r\n}]+"#)

    static func redact(_ source: String) throws -> String {
        guard let data = source.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "(Inspect output hidden because it could not be safely redacted.)"
        }
        let safe = redactObject(object)
        guard JSONSerialization.isValidJSONObject(safe),
              let encoded = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else {
            return "(Inspect output hidden because it could not be safely redacted.)"
        }
        return text
    }

    private static func redactObject(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                let key = item.key.lowercased().filter(\.isLetter)
                if key == "environment" || key == "env" {
                    result[item.key] = redactEnvironment(item.value)
                } else if sensitiveFragments.contains(where: key.contains) {
                    result[item.key] = "••••"
                } else {
                    result[item.key] = redactObject(item.value)
                }
            }
        }
        if let array = object as? [Any] { return redactArray(array) }
        if let string = object as? String { return redactAssignments(string) }
        return object
    }

    private static func redactEnvironment(_ value: Any) -> Any {
        if let array = value as? [String] {
            return array.map { line in
                guard let separator = line.firstIndex(of: "=") else { return line }
                return String(line[...separator]) + "••••"
            }
        }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { _ in "••••" } }
        return "••••"
    }

    private static func redactArray(_ values: [Any]) -> [Any] {
        var output: [Any] = []
        var index = 0
        let secretFlags: Set<String> = ["--password", "--passwd", "--token", "--secret", "--authorization", "--api-key", "--access-key", "--secret-key"]
        while index < values.count {
            guard let text = values[index] as? String else {
                output.append(redactObject(values[index]))
                index += 1
                continue
            }
            let lower = text.lowercased()
            if secretFlags.contains(lower) {
                output.append(text)
                if index + 1 < values.count {
                    output.append("••••")
                    index += 2
                } else { index += 1 }
            } else if secretFlags.contains(where: { lower.hasPrefix($0 + "=") }) {
                output.append(String(text.prefix { $0 != "=" }) + "=••••")
                index += 1
            } else {
                output.append(redactObject(text))
                index += 1
            }
        }
        return output
    }

    private static func redactAssignments(_ source: String) -> String {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return assignment.stringByReplacingMatches(in: source, range: range, withTemplate: "$1••••")
    }
}

public protocol NativeXPCTransporting: Sendable {
    func send(service: String, message: XPCMessage, timeout: Duration) async throws -> XPCMessage
}

public struct CancellableNativeXPCTransport: NativeXPCTransporting {
    public init() {}

    public func send(service: String, message: XPCMessage, timeout: Duration = .seconds(8)) async throws -> XPCMessage {
        let client = XPCClient(service: service)
        return try await BoundedNativeRequest.run(
            timeout: timeout,
            operation: { try await client.send(message) },
            cancel: { client.close() }
        )
    }
}

struct NativeAPITimeout: Error, LocalizedError {
    var errorDescription: String? { "The container API server did not respond before the read timed out." }
}

enum BoundedNativeRequest {
    static func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value,
        cancel: @escaping @Sendable () -> Void
    ) async throws -> Value {
        let response = AsyncResultLatch<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard response.install(continuation) else { return }
                let operationTask = Task {
                    do { response.complete(.success(try await operation())) }
                    catch { response.complete(.failure(error)) }
                }
                let timeoutTask = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    response.complete(.failure(NativeAPITimeout()))
                }
                response.setCleanup {
                    operationTask.cancel()
                    timeoutTask.cancel()
                    cancel()
                }
            }
        } onCancel: {
            response.complete(.failure(CancellationError()))
        }
    }
}

private final class AsyncResultLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?
    private var cleanup: (@Sendable () -> Void)?

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let immediate = lock.withLock { () -> Result<Value, Error>? in
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let immediate {
            continuation.resume(with: immediate)
            return false
        }
        return true
    }

    @discardableResult
    func complete(_ outcome: Result<Value, Error>) -> Bool {
        let values = lock.withLock { () -> (CheckedContinuation<Value, Error>?, (@Sendable () -> Void)?)? in
            guard self.outcome == nil else { return nil }
            self.outcome = outcome
            let values = (continuation, cleanup)
            continuation = nil
            cleanup = nil
            return values
        }
        guard let values else { return false }
        values.1?()
        values.0?.resume(with: outcome)
        return true
    }

    func setCleanup(_ cleanup: @escaping @Sendable () -> Void) {
        let runImmediately = lock.withLock { () -> Bool in
            guard outcome == nil else { return true }
            self.cleanup = cleanup
            return false
        }
        if runImmediately { cleanup() }
    }
}

/// Public Apple Container 1.x main API adapter. It uses only published main-server
/// routes and owns one closeable XPC connection per read so cancel/timeout bounds latency.
public struct AppleContainerResourceAPIClient: AppleContainerResourceAPI {
    private static let mainService = "com.apple.container.apiserver"
    private let transport: any NativeXPCTransporting

    public init(transport: any NativeXPCTransporting = CancellableNativeXPCTransport()) { self.transport = transport }

    public func serverIdentity() async throws -> NativeAPIServerIdentity {
        let response = try await transport.send(service: Self.mainService, message: XPCMessage(route: XPCRoute.ping), timeout: .seconds(8))
        guard let appName = response.string(key: XPCKeys.apiServerAppName),
              let version = response.string(key: XPCKeys.apiServerVersion) else { throw ContainerResourceReaderError.invalidPayload }
        return NativeAPIServerIdentity(appName: appName, version: version)
    }

    public func list(_ section: ContainerSection) async throws -> [ResourceSummary] {
        switch section {
        case .containers:
            let request = XPCMessage(route: XPCRoute.containerList)
            request.set(key: XPCKeys.listFilters, value: try JSONEncoder().encode(ContainerListFilters.all.withoutMachines()))
            let response = try await transport.send(service: Self.mainService, message: request, timeout: .seconds(8))
            let data = response.dataNoCopy(key: XPCKeys.containers) ?? Data("[]".utf8)
            let snapshots = try JSONDecoder().decode([ContainerSnapshot].self, from: data)
            let objects = try snapshots.map { snapshot -> [String: Any] in
                let encoded = try JSONEncoder().encode(snapshot)
                guard var item = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw ContainerResourceReaderError.invalidPayload }
                item["id"] = snapshot.id
                return item
            }
            return try ResourceJSONDecoder.summaries(from: JSONSerialization.data(withJSONObject: objects), section: .containers)
        case .volumes:
            let response = try await transport.send(service: Self.mainService, message: XPCMessage(route: XPCRoute.volumeList), timeout: .seconds(8))
            let data = response.dataNoCopy(key: XPCKeys.volumes) ?? Data("[]".utf8)
            let volumes = try JSONDecoder().decode([VolumeConfiguration].self, from: data)
            let objects = try volumes.map { volume -> [String: Any] in
                let encoded = try JSONEncoder().encode(volume)
                guard let config = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw ContainerResourceReaderError.invalidPayload }
                return ["id": volume.id, "configuration": config]
            }
            return try ResourceJSONDecoder.summaries(from: JSONSerialization.data(withJSONObject: objects), section: .volumes)
        case .networks:
            let response = try await transport.send(service: Self.mainService, message: XPCMessage(route: XPCRoute.networkList), timeout: .seconds(8))
            let data = response.dataNoCopy(key: XPCKeys.networkResources) ?? Data("[]".utf8)
            let networks = try JSONDecoder().decode([NetworkResource].self, from: data)
            let encoded = try JSONEncoder().encode(networks)
            return try ResourceJSONDecoder.summaries(from: encoded, section: .networks)
        default:
            throw ContainerResourceReaderError.invalidPayload
        }
    }

    public func inspectContainer(id: String) async throws -> SanitizedContainerInspection {
        let request = XPCMessage(route: XPCRoute.containerList)
        request.set(key: XPCKeys.listFilters, value: try JSONEncoder().encode(ContainerListFilters(ids: [id])))
        let response = try await transport.send(service: Self.mainService, message: request, timeout: .seconds(8))
        guard let data = response.dataNoCopy(key: XPCKeys.containers),
              let snapshot = try JSONDecoder().decode([ContainerSnapshot].self, from: data).first else {
            throw ContainerResourceReaderError.invalidPayload
        }
        let payload = try JSONEncoder().encode(snapshot)
        guard let json = String(data: payload, encoding: .utf8) else { throw ContainerResourceReaderError.invalidPayload }
        return SanitizedContainerInspection(containerID: id, json: try SensitiveJSONRedactor.redact(json))
    }

    public func stats(id: String) async throws -> ContainerStatsSample {
        let request = XPCMessage(route: XPCRoute.containerStats)
        request.set(key: XPCKeys.id, value: id)
        let response = try await transport.send(service: Self.mainService, message: request, timeout: .seconds(8))
        guard let data = response.dataNoCopy(key: XPCKeys.statistics),
              let stats = try? JSONDecoder().decode(ContainerStats.self, from: data),
              let cpu = stats.cpuUsageUsec,
              let memory = stats.memoryUsageBytes else { throw ContainerResourceReaderError.invalidPayload }
        return ContainerStatsSample(
            id: stats.id,
            cpuUsageUsec: Int64(clamping: cpu),
            memoryUsageBytes: Int64(clamping: memory),
            sampledAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }
}
