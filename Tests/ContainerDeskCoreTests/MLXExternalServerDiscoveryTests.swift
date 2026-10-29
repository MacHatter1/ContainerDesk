import Foundation
import Testing
@testable import ContainerDeskCore

struct MLXExternalServerDiscoveryTests {
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
