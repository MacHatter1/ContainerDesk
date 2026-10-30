import Foundation
import Darwin
import Testing
import Synchronization
@testable import ContainerDeskCore

struct MLXExternalServerDiscoveryTests {
    @Test func stockServerDiscoveryRequiresLocalProcessIdentityAndTheRealHealthRoute() async {
        let stock = MLXLocalListener(processID: 1001, processName: "python3", address: "127.0.0.1", port: 18080, isMLXLMServer: true)
        let generic = MLXLocalListener(processID: 1002, processName: "python3", address: "127.0.0.1", port: 18081)
        let prober = LoopbackMLXServerProber(sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StockMLXURLProtocol.self]
            return configuration
        })
        let records = await MLXExternalServerDiscoverer(listenerEnumerator: FixedMLXListeners([stock, generic]), serverProber: prober).discover()
        #expect(records.map(\.processID) == [1001])
        #expect(records.first?.backend == "mlx-lm")
        #expect(records.first?.models.map(\.name) == ["owner/stock-model"])
        let stockPaths = StockMLXURLProtocol.paths.withLock { $0[18080] ?? [] }
        #expect(stockPaths == ["/v1/models", "/health"])
    }

    @Test func stockIdentityIsRecheckedAfterTheHTTPProbe() async {
        let listener = MLXLocalListener(processID: 1001, processName: "python3", address: "127.0.0.1", port: 18082, isMLXLMServer: true)
        let records = await MLXExternalServerDiscoverer(
            listenerEnumerator: ChangingStockListeners(listener: listener),
            serverProber: FixedMLXProber(results: [18082: MLXExternalProbeResult(status: .reachable, backend: "mlx-lm", requiresProcessIdentity: true)])
        ).discover()
        #expect(records.isEmpty)
    }

    @Test func processIdentityCannotComeFromAModelArgumentOrEnvironmentValue() {
        for arguments in [["python3", "-m", "mlx_lm.server", "--model", "owner/model"], ["/venv/python3.14", "/venv/bin/mlx_lm", "server"], ["mlx_lm.server", "--port", "8080"], ["python3", "-u", "-m", "mlx_lm", "server"]] {
            #expect(MLXServerProcessIdentity.isServer(arguments: arguments))
        }
        for arguments in [["python3", "other_server.py", "--model", "mlx_lm.server"], ["python3", "-m", "generic", "mlx_lm", "server"], ["mlx_lm", "generate"], ["python3", "-c", "import mlx_lm.server"]] {
            #expect(!MLXServerProcessIdentity.isServer(arguments: arguments))
        }
        let args = ["python3", "-m", "mlx_lm.server"]
        var count = Int32(args.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(Data(("/venv/python3\0\0" + args.joined(separator: "\0") + "\0SECRET=do-not-retain\0").utf8))
        #expect(MLXServerProcessIdentity.decodeArguments(data) == args)
        #expect(MLXServerProcessIdentity.decodeArguments(data.prefix(10)).isEmpty)
        #expect(!MLXServerProcessIdentity.arguments(processID: getpid()).isEmpty)
    }

    @Test func advertisedMLXLMBackendDoesNotRequirePythonArgv() async {
        let listener = MLXLocalListener(processID: 1010, processName: "jev", address: "127.0.0.1", port: 18083)
        let records = await MLXExternalServerDiscoverer(
            listenerEnumerator: FixedMLXListeners([listener]),
            serverProber: FixedMLXProber(results: [18083: MLXExternalProbeResult(status: .reachable, backend: "mlx-lm")])
        ).discover()
        #expect(records.count == 1)
    }

    @Test func parsesOnlyCurrentUserIPv4LoopbackListenerFields() {
        let output = [
            "p9146", "cpython", "f12", "n127.0.0.1:8765",
            "p9146", "cpython", "f13", "n*:8765",
            "p9150", "cjev-style-native", "f3", "nlocalhost:8768",
            "p9152", "cjev-review", "f4", "n192.168.1.20:8766",
        ].joined(separator: "\n")

        let listeners = LsofMLXListenerEnumerator.parse(output)
        #expect(listeners.count == 2)
        #expect(listeners.contains(MLXLocalListener(processID: 9146, processName: "python", address: "127.0.0.1", port: 8765)))
        #expect(listeners.contains(MLXLocalListener(processID: 9150, processName: "jev-style-native", address: "localhost", port: 8768)))
    }

    @Test func treatsEmptyLsofSelectionAsEmptyButSurfacesActualFailures() throws {
        let empty = CommandResult(standardOutput: "", standardError: "", exitCode: 1, terminationReason: .exit, duration: .zero)
        #expect(try LsofMLXListenerEnumerator.parseResult(empty).isEmpty)

        let failed = CommandResult(standardOutput: "", standardError: "permission denied", exitCode: 1, terminationReason: .exit, duration: .zero)
        #expect(throws: MLXError.self) { try LsofMLXListenerEnumerator.parseResult(failed) }
    }

    @Test func discoversJevAndExplicitMLXBackendsAsDisplayOnlyLoopbackEntries() async {
        let listeners = [
            MLXLocalListener(processID: 9146, processName: "jev-style-native", address: "127.0.0.1", port: 8765),
            MLXLocalListener(processID: 9150, processName: "python3.12", address: "127.0.0.1", port: 8766),
            MLXLocalListener(processID: 9151, processName: "python3.12", address: "127.0.0.1", port: 8767),
            MLXLocalListener(processID: 9152, processName: "curl", address: "127.0.0.1", port: 8768),
            MLXLocalListener(processID: 9153, processName: "jev-review", address: "192.168.1.20", port: 8769),
            MLXLocalListener(processID: 9154, processName: "jev-review", address: "127.0.0.1", port: 8770),
            MLXLocalListener(processID: 9155, processName: "jev-review", address: "127.0.0.1", port: 8771),
        ]
        let healthy = MLXExternalProbeResult(
            status: .reachable,
            backend: "mlx-metal",
            models: [MLXExternalModelRecord(name: "jev-style-2b-decision-v3", contextTokens: 25_600, backend: "mlx-metal")]
        )
        let discoverer = MLXExternalServerDiscoverer(
            listenerEnumerator: FixedMLXListeners(listeners),
            serverProber: FixedMLXProber(results: [
                8765: healthy,
                8766: healthy,
                8767: MLXExternalProbeResult(status: .reachable, backend: "unrelated"),
                8770: MLXExternalProbeResult(status: .unavailable, backend: "mlx-metal"),
                8771: MLXExternalProbeResult(status: .reachable),
            ])
        )

        let records = await discoverer.discover()
        #expect(records.count == 3)
        #expect(records.map(\.endpoint.port) == [8765, 8766, 8770])
        #expect(records.allSatisfy { $0.endpoint.host == "127.0.0.1" })
        #expect(records[0].status == .reachable)
        #expect(records[2].status == .unavailable)
        #expect(records[2].models.isEmpty)
        #expect(records.first?.models.first?.name == "jev-style-2b-decision-v3")
        #expect(records.first?.id == "9146:8765")
    }

    @Test func decodesJevOpenAIModelsAndHealthMetadataWithoutAssumingPaths() throws {
        let modelPayload = #"{"data":[{"id":"jev-style-2b-decision-v3","context_tokens":25600,"head_max_tokens":25600,"backend":"mlx-metal"}],"models":[{"name":"jev-style-2b-decision-v3","release_date":"2026-09-27","description":"Jev-Style 2B Decision v3, MLX bf16, native macOS Metal GPU"}]}"#
        let healthPayload = #"{"status":"ok","model":"jev-style-2b-decision-v3","backend":"mlx-metal","auth":false,"untrained":false,"release_kind":"release","extensions":["agent_approval"],"ext_errors":[]}"#
        let modelsObject = try #require(JSONSerialization.jsonObject(with: Data(modelPayload.utf8)) as? [String: Any])
        let healthObject = try #require(JSONSerialization.jsonObject(with: Data(healthPayload.utf8)) as? [String: Any])

        let result = try #require(LoopbackMLXServerProber.decode(modelsObject: modelsObject, healthObject: healthObject))
        #expect(result.status == .reachable)
        #expect(result.backend == "mlx-metal")
        #expect(result.models.count == 1)
        #expect(result.models[0].id == "jev-style-2b-decision-v3")
        #expect(result.models[0].description?.contains("native macOS Metal GPU") == true)
        #expect(result.models[0].contextTokens == 25_600)
        #expect(!String(describing: result).contains("auth"))

        let deciderPayload = #"{"model":"decider-4b-v2.1-dwq4","backend":"mlx-metal"}"#
        let deciderObject = try #require(JSONSerialization.jsonObject(with: Data(deciderPayload.utf8)) as? [String: Any])
        let decider = try #require(LoopbackMLXServerProber.decode(modelsObject: deciderObject, healthObject: deciderObject))
        #expect(decider.models.map(\.name) == ["decider-4b-v2.1-dwq4"])
    }

    @Test func distinguishesEmptyListenerScanFromEnumeratorFailure() async {
        let empty = await MLXExternalServerDiscoverer(
            listenerEnumerator: FixedMLXListeners([]),
            serverProber: FixedMLXProber(results: [:])
        ).scan()
        #expect(empty.servers.isEmpty)
        #expect(empty.failure == nil)

        let failed = await MLXExternalServerDiscoverer(
            listenerEnumerator: FailingMLXListeners(),
            serverProber: FixedMLXProber(results: [:])
        ).scan()
        #expect(failed.servers.isEmpty)
        #expect(failed.failure != nil)
    }
}

private actor ChangingStockListeners: MLXListenerEnumerating {
    let listener: MLXLocalListener
    private var calls = 0
    init(listener: MLXLocalListener) { self.listener = listener }
    func listeners() async throws -> [MLXLocalListener] {
        calls += 1
        return [MLXLocalListener(processID: listener.processID, processName: listener.processName, address: listener.address, port: listener.port, isMLXLMServer: calls == 1)]
    }
}

private final class StockMLXURLProtocol: URLProtocol, @unchecked Sendable {
    static let paths = Mutex<[Int: [String]]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.paths.withLock { $0[url.port ?? 0, default: []].append(url.path) }
        let status = url.path == "/healthz" && url.port == 18080 ? 404 : 200
        let body = url.path == "/v1/models"
            ? #"{"object":"list","data":[{"id":"owner/stock-model","object":"model","created":123}]}"#
            : #"{"status":"ok"}"#
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct MLXExternalServerLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTAINERDESK_EXTERNAL_MLX_LIVE_CHECK"] == "1"))
    func discoversExistingJevModelsOnCurrentUsersLoopbackListeners() async {
        let result = await MLXExternalServerDiscoverer().scan()
        #expect(result.failure == nil)
        let models = Set(result.servers.flatMap(\.models).map(\.name))
        #expect(models.contains("jev-style-2b-decision-v3"))
        #expect(models.contains("jev-style-0.8b-decision-v3"))
        #expect(result.servers.allSatisfy { $0.endpoint.host == "127.0.0.1" })
        #expect(result.servers.filter { $0.models.contains(where: { $0.name.hasPrefix("jev-style-") }) }.allSatisfy { $0.backend == "mlx-metal" })
    }
}

private struct FixedMLXListeners: MLXListenerEnumerating {
    let values: [MLXLocalListener]
    init(_ values: [MLXLocalListener]) { self.values = values }
    func listeners() async throws -> [MLXLocalListener] { values }
}

private struct FixedMLXProber: MLXExternalServerProbing {
    let results: [UInt16: MLXExternalProbeResult]

    func probe(listener: MLXLocalListener) async -> MLXExternalProbeResult? {
        return results[listener.port]
    }
}

private struct FailingMLXListeners: MLXListenerEnumerating {
    func listeners() async throws -> [MLXLocalListener] { throw MLXError.operationFailed("fixture failure") }
}
