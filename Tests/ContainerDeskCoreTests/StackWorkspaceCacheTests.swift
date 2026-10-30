import Foundation
import Testing
@testable import ContainerDeskCore

struct StackWorkspaceCacheTests {
    @Test func metricTicksReuseTopologyAndKeepMissingSamplesUnknown() {
        let containers = [item("shop-api"), item("shop-worker")]
        var cache = StackWorkspaceCache()
        let initial = cache.workspaces(containers: containers)
        #expect(initial.first?.cpuPercent == nil)
        let metrics = ["shop-api": ContainerMetric(cpuPercent: 20, memoryUsageBytes: 100), "shop-worker": ContainerMetric(cpuPercent: 30, memoryUsageBytes: 200)]
        let measured = cache.workspaces(containers: containers, metrics: metrics)
        #expect(measured == StackWorkspaceCatalog.build(containers: containers, metrics: metrics))
        #expect(measured.first?.cpuPercent == 50)
        #expect(measured.first?.memoryUsageBytes == 300)
        for _ in 0..<20 { #expect(cache.workspaces(containers: containers, metrics: metrics) == measured) }
        #expect(cache.topologyBuildCount == 1)
        let partial = cache.workspaces(containers: containers, metrics: ["shop-api": metrics["shop-api"]!])
        #expect(partial.first?.cpuPercent == nil)
        #expect(partial.first?.memoryUsageBytes == nil)
        #expect(cache.topologyBuildCount == 1)
    }

    @Test func inventoryMembershipRelatedResourcesAndUngroupingInvalidateTopology() {
        let label = ["com.docker.compose.project": "shop"]
        let containers = [item("shop-api", labels: label), item("shop-worker", labels: label)]
        let volume = ResourceSummary(id: "data", title: "data", details: .init(labels: label))
        let network = ResourceSummary(id: "net", title: "net", details: .init(labels: label))
        let image = ResourceSummary(id: "image", title: "image", details: .init(imageReference: "example/app:v1"))
        let stack = ManagedStack(name: "Manual", containerIDs: ["shop-api", "missing"])
        var cache = StackWorkspaceCache()
        _ = cache.workspaces(containers: containers)
        let withResources = cache.workspaces(containers: containers, images: [image], volumes: [volume], networks: [network])
        #expect(withResources == StackWorkspaceCatalog.build(containers: containers, images: [image], volumes: [volume], networks: [network]))
        #expect(cache.topologyBuildCount == 2)
        let managed = cache.workspaces(containers: containers, managedStacks: [stack])
        #expect(managed.first { $0.id == stack.workspaceID }?.missingContainerIDs == ["missing"])
        #expect(cache.topologyBuildCount == 3)
        let ungrouped = cache.workspaces(containers: containers, ungroupedContainerIDs: ["shop-api"])
        #expect(ungrouped == StackWorkspaceCatalog.build(containers: containers, ungroupedContainerIDs: ["shop-api"]))
        #expect(cache.topologyBuildCount == 4)
        #expect(cache.workspaces(containers: []).isEmpty)
        #expect(cache.topologyBuildCount == 5)
    }

    private func item(_ id: String, labels: [String: String] = [:]) -> ResourceSummary {
        ResourceSummary(id: id, title: id, state: "running", details: .init(imageReference: "example/app:v1", labels: labels, memoryLimitBytes: 1_000))
    }
}
