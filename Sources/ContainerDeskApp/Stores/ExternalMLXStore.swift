import ContainerDeskCore
import Foundation
import Observation

@MainActor
@Observable
final class ExternalMLXStore {
    private(set) var servers: [MLXExternalServerRecord] = []
    private(set) var isRefreshing = false
    private(set) var hasCompletedScan = false
    private(set) var scanFailure: String?
    private(set) var refreshedAt: Date?

    private let discoverer: MLXExternalServerDiscoverer
    private var refreshTask: Task<MLXExternalServerDiscoveryResult, Never>?
    private var pollingTask: Task<Void, Never>?
    private var visibleSubscriptions: [UUID: String] = [:]
    private var refreshGeneration: UInt64 = 0

    init(discoverer: MLXExternalServerDiscoverer = MLXExternalServerDiscoverer()) {
        self.discoverer = discoverer
    }

    func visibleServers(excludingPorts ownedPorts: Set<UInt16>) -> [MLXExternalServerRecord] {
        servers.filter { server in
            guard let integerPort = server.endpoint.port,
                  let port = UInt16(exactly: integerPort) else { return true }
            return !ownedPorts.contains(port)
        }
    }

    @discardableResult
    func beginObserving(sceneID: String) -> UUID {
        let subscriptionID = UUID()
        visibleSubscriptions[subscriptionID] = sceneID
        if pollingTask == nil {
            pollingTask = Task { @MainActor in await pollWhileVisible() }
        }
        return subscriptionID
    }

    func endObserving(subscriptionID: UUID) {
        visibleSubscriptions[subscriptionID] = nil
        guard visibleSubscriptions.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration &+= 1
        isRefreshing = false
    }

    func refresh(force: Bool = false) async {
        if !force, let refreshTask {
            _ = await refreshTask.value
            return
        }

        if force { refreshTask?.cancel() }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true

        let task = Task { await discoverer.scan() }
        refreshTask = task
        let updated = await task.value
        guard generation == refreshGeneration else { return }
        scanFailure = updated.failure
        if updated.failure == nil {
            servers = updated.servers
            hasCompletedScan = true
        }
        refreshedAt = Date()
        isRefreshing = false
        refreshTask = nil
    }

    private func pollWhileVisible() async {
        while !Task.isCancelled, !visibleSubscriptions.isEmpty {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }
}
