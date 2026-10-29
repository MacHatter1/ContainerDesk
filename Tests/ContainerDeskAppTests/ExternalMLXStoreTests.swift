import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct ExternalMLXStoreTests {
    @MainActor
    @Test func exposesVerifiedLoopbackModelsAndExcludesAppOwnedPorts() async throws {
        let discoverer = MLXExternalServerDiscoverer(
            listenerEnumerator: FixedMLXListeners([
                MLXLocalListener(processID: 12, processName: "jev-style", address: "127.0.0.1", port: 8_765),
                MLXLocalListener(processID: 13, processName: "mlx_lm", address: "127.0.0.1", port: 8_766),
                MLXLocalListener(processID: 14, processName: "jev-other", address: "0.0.0.0", port: 8_767),
            ]),
            serverProber: FixedMLXProbe()
        )
        let store = ExternalMLXStore(discoverer: discoverer)

        await store.refresh()

        #expect(store.hasCompletedScan)
        #expect(store.scanFailure == nil)
        #expect(store.servers.count == 2)
        #expect(store.servers.flatMap(\.models).map(\.name).sorted() == ["jev-style-0.8b-decision-v3", "jev-style-2b-decision-v3"])
        #expect(store.visibleServers(excludingPorts: [8_765]).map { $0.endpoint.port ?? 0 } == [8_766])
    }

    @MainActor
    @Test func reportsListenerScanFailureSeparatelyFromAnEmptyScan() async {
        let store = ExternalMLXStore(discoverer: MLXExternalServerDiscoverer(
            listenerEnumerator: FailedMLXListeners(),
            serverProber: FixedMLXProbe()
        ))

        await store.refresh()

        #expect(!store.hasCompletedScan)
        #expect(store.scanFailure == "Could not inspect this user's local listeners.")
        #expect(store.servers.isEmpty)
    }

    @MainActor
    @Test func discoveryContinuesUntilLastVisibleWindowLeaves() async throws {
        let listeners = BlockingMLXListeners()
        let store = ExternalMLXStore(discoverer: MLXExternalServerDiscoverer(
            listenerEnumerator: listeners,
            serverProber: FixedMLXProbe()
        ))

        let firstWindowToken = store.beginObserving(sceneID: "window-a")
        let secondWindowToken = store.beginObserving(sceneID: "window-b")
        try await waitUntil { await listeners.startedCount() == 1 }
        store.endObserving(subscriptionID: firstWindowToken)
        let cancelledAfterFirstWindow = await listeners.cancelledCount() > 0
        #expect(!cancelledAfterFirstWindow)

        let reactivatedWindowToken = store.beginObserving(sceneID: "window-a")
        store.endObserving(subscriptionID: firstWindowToken)
        let cancelledAfterOldRegistrationEnds = await listeners.cancelledCount() > 0
        #expect(!cancelledAfterOldRegistrationEnds)

        store.endObserving(subscriptionID: secondWindowToken)
        let cancelledAfterOtherWindowLeaves = await listeners.cancelledCount() > 0
        #expect(!cancelledAfterOtherWindowLeaves)
        store.endObserving(subscriptionID: reactivatedWindowToken)
        try await waitUntil { await listeners.cancelledCount() == 1 }
        let cancelledAfterLastWindow = await listeners.cancelledCount() == 1
        #expect(cancelledAfterLastWindow)

        let finalWindowToken = store.beginObserving(sceneID: "window-a")
        try await waitUntil { await listeners.startedCount() == 2 }
        store.endObserving(subscriptionID: finalWindowToken)
        try await waitUntil { await listeners.cancelledCount() == 2 }
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for external discovery.")
    }
}

private struct FixedMLXListeners: MLXListenerEnumerating {
    let value: [MLXLocalListener]
    init(_ value: [MLXLocalListener]) { self.value = value }
    func listeners() async throws -> [MLXLocalListener] { value }
}

private struct FailedMLXListeners: MLXListenerEnumerating {
    func listeners() async throws -> [MLXLocalListener] { throw LocalListenerFailure.failed }
}

private enum LocalListenerFailure: Error { case failed }

private struct FixedMLXProbe: MLXExternalServerProbing {
    func probe(listener: MLXLocalListener) async -> MLXExternalProbeResult? {
        MLXExternalProbeResult(
            status: .reachable,
            backend: "mlx-metal",
            models: [MLXExternalModelRecord(name: listener.port == 8_765 ? "jev-style-2b-decision-v3" : "jev-style-0.8b-decision-v3", backend: "mlx-metal")]
        )
    }
}

private actor BlockingMLXListeners: MLXListenerEnumerating {
    private var starts = 0
    private var cancellations = 0

    func listeners() async throws -> [MLXLocalListener] {
        starts += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancellations += 1
        }
        return []
    }

    func startedCount() -> Int { starts }
    func cancelledCount() -> Int { cancellations }
}
