import CFNetwork
import Darwin
import Foundation

/// A current-user listener eligible for a loopback-only service probe.
public struct MLXLocalListener: Sendable, Hashable, Identifiable {
    public var id: String { "\(processID):\(port)" }
    public let processID: Int32
    public let processName: String
    public let address: String
    public let port: UInt16
    /// Derived locally from the owning process's argv, never from an HTTP claim.
    public let isMLXLMServer: Bool

    public init(processID: Int32, processName: String, address: String, port: UInt16, isMLXLMServer: Bool = false) {
        self.processID = processID
        self.processName = safeExternalText(processName, limit: 128)
        self.address = safeExternalText(address, limit: 64)
        self.port = port
        self.isMLXLMServer = isMLXLMServer
    }
}

public enum MLXExternalServerStatus: String, Sendable, Equatable {
    case reachable
    case unavailable
}

/// Metadata returned by an external server. It contains no inferred filesystem path or ownership.
public struct MLXExternalModelRecord: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String?
    public let contextTokens: Int?
    public let backend: String?

    public init(name: String, description: String? = nil, contextTokens: Int? = nil, backend: String? = nil) {
        self.name = safeExternalText(name, limit: 256)
        self.description = description.map { safeExternalText($0, limit: 512) }
        self.contextTokens = contextTokens.flatMap { (1...1_000_000).contains($0) ? $0 : nil }
        self.backend = backend.map { safeExternalText($0, limit: 128) }
    }
}

/// Display-only information about an independently managed loopback service.
public struct MLXExternalServerRecord: Sendable, Equatable, Identifiable {
    public var id: String { "\(processID):\(endpoint.port ?? 0)" }
    public let processID: Int32
    public let processName: String
    public let endpoint: URL
    public let status: MLXExternalServerStatus
    public let backend: String?
    public let models: [MLXExternalModelRecord]
    public let detail: String?

    public init(processID: Int32, processName: String, endpoint: URL, status: MLXExternalServerStatus, backend: String? = nil, models: [MLXExternalModelRecord] = [], detail: String? = nil) {
        self.processID = processID
        self.processName = safeExternalText(processName, limit: 128)
        self.endpoint = endpoint
        self.status = status
        self.backend = backend.map { safeExternalText($0, limit: 128) }
        self.models = Array(models.prefix(64))
        self.detail = detail.map { safeExternalText($0, limit: 256) }
    }
}

public struct MLXExternalProbeResult: Sendable, Equatable {
    public let status: MLXExternalServerStatus
    public let backend: String?
    public let models: [MLXExternalModelRecord]
    public let requiresProcessIdentity: Bool

    public init(status: MLXExternalServerStatus, backend: String? = nil, models: [MLXExternalModelRecord] = [], requiresProcessIdentity: Bool = false) {
        self.status = status
        self.backend = backend
        self.models = Array(models.prefix(64))
        self.requiresProcessIdentity = requiresProcessIdentity
    }
}

public struct MLXExternalServerDiscoveryResult: Sendable, Equatable {
    public let servers: [MLXExternalServerRecord]
    /// A short, safe description of a whole-scan failure. Per-listener probe failures are records.
    public let failure: String?

    public init(servers: [MLXExternalServerRecord], failure: String? = nil) {
        self.servers = servers
        self.failure = failure.map { String($0.prefix(256)) }
    }
}

public protocol MLXListenerEnumerating: Sendable {
    func listeners() async throws -> [MLXLocalListener]
}

public protocol MLXExternalServerProbing: Sendable {
    func probe(listener: MLXLocalListener) async -> MLXExternalProbeResult?
}

/// Finds current-user MLX/Jev-compatible services without taking ownership of them.
public struct MLXExternalServerDiscoverer: Sendable {
    private struct VerifiedProbe: Sendable {
        let record: MLXExternalServerRecord
        let requiresProcessIdentity: Bool
    }
    private let listenerEnumerator: any MLXListenerEnumerating
    private let serverProber: any MLXExternalServerProbing
    private let maximumListeners: Int
    private let maximumConcurrentProbes: Int

    public init() {
        self.init(listenerEnumerator: LsofMLXListenerEnumerator(), serverProber: LoopbackMLXServerProber())
    }

    public init(
        listenerEnumerator: any MLXListenerEnumerating,
        serverProber: any MLXExternalServerProbing,
        maximumListeners: Int = 32,
        maximumConcurrentProbes: Int = 4
    ) {
        self.listenerEnumerator = listenerEnumerator
        self.serverProber = serverProber
        self.maximumListeners = min(64, max(1, maximumListeners))
        self.maximumConcurrentProbes = min(8, max(1, maximumConcurrentProbes))
    }

    public func discover() async -> [MLXExternalServerRecord] {
        await scan().servers
    }

    public func scan() async -> MLXExternalServerDiscoveryResult {
        guard !Task.isCancelled else { return MLXExternalServerDiscoveryResult(servers: []) }
        let listeners: [MLXLocalListener]
        do {
            listeners = try await listenerEnumerator.listeners()
        } catch {
            guard !Task.isCancelled else { return MLXExternalServerDiscoveryResult(servers: []) }
            return MLXExternalServerDiscoveryResult(servers: [], failure: "Could not inspect this user's local listeners.")
        }
        guard !Task.isCancelled else { return MLXExternalServerDiscoveryResult(servers: []) }
        let orderedListeners = listeners.filter(Self.isCandidate).sorted {
            let lhsProduct = Self.isStrongProcessCandidate($0.processName)
            let rhsProduct = Self.isStrongProcessCandidate($1.processName)
            if lhsProduct != rhsProduct { return lhsProduct }
            if $0.processID == $1.processID { return $0.port < $1.port }
            return $0.processID < $1.processID
        }
        var seenListeners = Set<String>()
        let candidates = Array(orderedListeners.filter { seenListeners.insert($0.id).inserted }.prefix(maximumListeners))
        guard !candidates.isEmpty else { return MLXExternalServerDiscoveryResult(servers: []) }

        var records: [VerifiedProbe] = []
        await withTaskGroup(of: VerifiedProbe?.self) { group in
            var nextIndex = 0
            let initialCount = min(maximumConcurrentProbes, candidates.count)
            for _ in 0..<initialCount {
                let listener = candidates[nextIndex]
                nextIndex += 1
                group.addTask { await Self.probeRecord(listener, using: serverProber) }
            }
            while let result = await group.next() {
                if let result { records.append(result) }
                guard !Task.isCancelled, nextIndex < candidates.count else { continue }
                let listener = candidates[nextIndex]
                nextIndex += 1
                group.addTask { await Self.probeRecord(listener, using: serverProber) }
            }
        }
        guard !Task.isCancelled else { return MLXExternalServerDiscoveryResult(servers: []) }
        let currentListeners: [MLXLocalListener]
        do {
            currentListeners = try await listenerEnumerator.listeners()
        } catch {
            guard !Task.isCancelled else { return MLXExternalServerDiscoveryResult(servers: []) }
            return MLXExternalServerDiscoveryResult(servers: [], failure: "Could not verify local listener ownership after probing.")
        }
        guard !Task.isCancelled else { return MLXExternalServerDiscoveryResult(servers: []) }
        let currentKeys = Set(currentListeners.filter(Self.isCandidate).map(\.id))
        let stockKeys = Set(currentListeners.filter(\.isMLXLMServer).map(\.id))
        let verifiedRecords = records.filter { currentKeys.contains($0.record.id) && (!$0.requiresProcessIdentity || stockKeys.contains($0.record.id)) }.map(\.record)
        return MLXExternalServerDiscoveryResult(servers: verifiedRecords.sorted {
            if $0.endpoint.port == $1.endpoint.port { return $0.processID < $1.processID }
            return ($0.endpoint.port ?? 0) < ($1.endpoint.port ?? 0)
        })
    }

    private static func isCandidate(_ listener: MLXLocalListener) -> Bool {
        let address = listener.address.lowercased()
        guard listener.processID > 0,
              listener.port > 0,
              address == "127.0.0.1" || address == "localhost" else { return false }
        let name = listener.processName.lowercased()
        return name.contains("python") || isStrongProcessCandidate(name)
    }

    private static func isStrongProcessCandidate(_ processName: String) -> Bool {
        let name = processName.lowercased()
        return name.contains("mlx") || name.contains("jev")
    }

    private static func probeRecord(_ listener: MLXLocalListener, using prober: any MLXExternalServerProbing) async -> VerifiedProbe? {
        guard !Task.isCancelled else { return nil }
        let endpoint = URL(string: "http://127.0.0.1:\(listener.port)")!
        guard let probe = await prober.probe(listener: listener),
              probe.backend?.localizedLowercase.contains("mlx") == true else { return nil }
        let record = MLXExternalServerRecord(
            processID: listener.processID,
            processName: listener.processName,
            endpoint: endpoint,
            status: probe.status,
            backend: probe.backend,
            models: probe.models,
            detail: probe.status == .reachable ? "Responding on loopback; not managed by this app instance." : "The local service reported that it is not healthy."
        )
        return VerifiedProbe(record: record, requiresProcessIdentity: probe.requiresProcessIdentity)
    }
}

/// Uses lsof's field output, restricted to the current user and IPv4 loopback listeners.
public struct LsofMLXListenerEnumerator: MLXListenerEnumerating, Sendable {
    public let executableURL: URL
    public let userName: String

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof"), userName: String = NSUserName()) {
        self.executableURL = executableURL
        self.userName = userName
    }

    public func listeners() async throws -> [MLXLocalListener] {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MLXError.operationFailed("The local listener inspection tool is unavailable.")
        }
        let request = CommandRequest(
            arguments: ["-nP", "-a", "-u", userName, "-iTCP", "-sTCP:LISTEN", "-Fpcn"],
            captureLimit: 64 * 1024,
            suppressOutputEvents: true,
            timeout: .seconds(3)
        )
        let result = try await ProcessExecutableClient(executableURL: executableURL).run(request)
        let listeners = try Self.parseResult(result)
        var stockProcesses: [Int32: Bool] = [:]
        return listeners.map { listener in
            let stock = stockProcesses[listener.processID] ?? MLXServerProcessIdentity.isServer(arguments: MLXServerProcessIdentity.arguments(processID: listener.processID))
            stockProcesses[listener.processID] = stock
            return MLXLocalListener(processID: listener.processID, processName: listener.processName, address: listener.address, port: listener.port, isMLXLMServer: stock)
        }
    }

    static func parseResult(_ result: CommandResult) throws -> [MLXLocalListener] {
        guard !result.outputTruncated else { throw MLXError.operationFailed("Local listener inspection output exceeded its safety limit.") }
        if result.succeeded { return Self.parse(result.standardOutput) }
        // lsof uses exit status 1 when the selection matched no open files. Empty streams
        // distinguish that ordinary case from permission, invocation, or parsing failures.
        if result.exitCode == 1, result.standardOutput.isEmpty, result.standardError.isEmpty { return [] }
        throw MLXError.operationFailed("Local listener inspection did not complete successfully.")
    }

    static func parse(_ output: String) -> [MLXLocalListener] {
        var processID: Int32?
        var processName: String?
        var found: [MLXLocalListener] = []
        for line in output.split(whereSeparator: \.isNewline).prefix(20_000) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p": processID = Int32(value)
            case "c": processName = String(value.prefix(128))
            case "n":
                guard let processID, let processName,
                      let parsed = Self.parseAddress(value) else { continue }
                found.append(MLXLocalListener(processID: processID, processName: processName, address: parsed.address, port: parsed.port))
            default: continue
            }
        }
        return Array(Set(found)).prefix(256).map { $0 }
    }

    private static func parseAddress(_ value: String) -> (address: String, port: UInt16)? {
        guard let colon = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: colon)...]), port > 0 else { return nil }
        var address = String(value[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") { address.removeFirst(); address.removeLast() }
        guard address == "127.0.0.1" || address.lowercased() == "localhost" else { return nil }
        return (address, port)
    }
}

/// Probes only fixed unauthenticated JSON endpoints on 127.0.0.1.
public struct LoopbackMLXServerProber: MLXExternalServerProbing, Sendable {
    public let requestTimeout: TimeInterval
    public let maximumResponseBytes: Int
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration

    public init(requestTimeout: TimeInterval = 1.5, maximumResponseBytes: Int = 64 * 1024, sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.requestTimeout = min(3, max(0.2, requestTimeout))
        self.maximumResponseBytes = min(128 * 1024, max(1_024, maximumResponseBytes))
        self.sessionConfiguration = sessionConfiguration
    }

    public func probe(listener: MLXLocalListener) async -> MLXExternalProbeResult? {
        guard !Task.isCancelled, listener.port > 0 else { return nil }
        let modelObject = await fetchJSON(port: listener.port, path: "/v1/models")
        guard !Task.isCancelled else { return nil }
        let modelBackend = Self.string("backend", in: modelObject)
            ?? (modelObject?["data"] as? [[String: Any]])?.compactMap { $0["backend"] as? String }.first
        let healthObject: [String: Any]?
        if modelBackend == nil { healthObject = await fetchJSON(port: listener.port, path: listener.isMLXLMServer ? "/health" : "/healthz") }
        else { healthObject = nil }
        guard !Task.isCancelled else { return nil }
        guard modelObject != nil || healthObject != nil else { return nil }

        return Self.decode(modelsObject: modelObject, healthObject: healthObject, isMLXLMServer: listener.isMLXLMServer)
    }

    static func decode(modelsObject: [String: Any]?, healthObject: [String: Any]?, isMLXLMServer: Bool = false) -> MLXExternalProbeResult? {
        guard modelsObject != nil || healthObject != nil else { return nil }
        let modelBackend = (modelsObject?["data"] as? [[String: Any]])?.compactMap { $0["backend"] as? String }.first
        var backend = Self.string("backend", in: healthObject) ?? Self.string("backend", in: modelsObject) ?? modelBackend
        var requiresProcessIdentity = false
        if backend == nil, isMLXLMServer, modelsObject?["object"] as? String == "list",
           modelsObject?["data"] is [[String: Any]], Self.string("status", in: healthObject) == "ok" {
            backend = "mlx-lm"
            requiresProcessIdentity = true
        }
        var models = Self.models(from: modelsObject, fallbackBackend: backend)
        if models.isEmpty, let name = Self.string("model", in: healthObject) ?? Self.string("model", in: modelsObject) {
            models = [MLXExternalModelRecord(name: name, backend: backend)]
        }
        let healthStatus = Self.string("status", in: healthObject)?.lowercased()
        let isHealthy: Bool
        if let healthStatus { isHealthy = ["ok", "healthy", "ready", "running"].contains(healthStatus) }
        else { isHealthy = modelsObject != nil }
        return MLXExternalProbeResult(status: isHealthy ? .reachable : .unavailable, backend: backend, models: models, requiresProcessIdentity: requiresProcessIdentity)
    }

    private func fetchJSON(port: UInt16, path: String) async -> [String: Any]? {
        guard ["/v1/models", "/healthz", "/health"].contains(path),
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        let delegate = ExternalNoRedirectDelegate()
        let config = sessionConfiguration()
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
        ]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return nil }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < maximumResponseBytes else { return nil }
                body.append(byte)
            }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func models(from object: [String: Any]?, fallbackBackend: String?) -> [MLXExternalModelRecord] {
        guard let object else { return [] }
        var descriptions: [String: String] = [:]
        if let advertised = object["models"] as? [[String: Any]] {
            for item in advertised.prefix(64) {
                guard let name = (item["name"] as? String) ?? (item["id"] as? String), !safeExternalText(name, limit: 256).isEmpty else { continue }
                if let description = item["description"] as? String { descriptions[name] = safeExternalText(description, limit: 512) }
            }
        }
        var result: [MLXExternalModelRecord] = []
        if let data = object["data"] as? [[String: Any]] {
            for item in data.prefix(64) {
                guard let name = (item["id"] as? String) ?? (item["name"] as? String), !safeExternalText(name, limit: 256).isEmpty else { continue }
                let context = (item["context_tokens"] as? NSNumber)?.intValue ?? (item["context_length"] as? NSNumber)?.intValue
                result.append(MLXExternalModelRecord(
                    name: name,
                    description: descriptions[name] ?? (item["description"] as? String),
                    contextTokens: context,
                    backend: item["backend"] as? String ?? fallbackBackend
                ))
            }
        }
        if result.isEmpty, let name = Self.string("model", in: object) {
            result.append(MLXExternalModelRecord(name: name, description: descriptions[name], backend: fallbackBackend ?? Self.string("backend", in: object)))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.name).inserted }
    }

    private static func string(_ key: String, in object: [String: Any]?) -> String? {
        guard let value = object?[key] as? String, !value.isEmpty else { return nil }
        return safeExternalText(value, limit: 256)
    }
}

private func safeExternalText(_ value: String, limit: Int) -> String {
    var output = ""
    var count = 0
    for scalar in value.unicodeScalars {
        guard count < limit else { break }
        if CharacterSet.controlCharacters.contains(scalar) { output.append(" ") }
        else { output.unicodeScalars.append(scalar) }
        count += 1
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class ExternalNoRedirectDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
