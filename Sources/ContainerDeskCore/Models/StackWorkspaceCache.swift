import Foundation

/// Topology changes only with inventory/membership. Metric ticks update aggregates alone.
public struct StackWorkspaceCache {
    private struct Inputs: Equatable {
        let containers: [ResourceSummary]
        let images: [ResourceSummary]
        let volumes: [ResourceSummary]
        let networks: [ResourceSummary]
        let stacks: [ManagedStack]
        let ungrouped: Set<String>
    }
    private var inputs: Inputs?
    private var topology: [StackWorkspace] = []
    private var metrics: [String: ContainerMetric]?
    private var result: [StackWorkspace] = []
    private(set) var topologyBuildCount = 0

    public init() {}

    public mutating func workspaces(
        containers: [ResourceSummary], images: [ResourceSummary] = [],
        volumes: [ResourceSummary] = [], networks: [ResourceSummary] = [],
        metrics: [String: ContainerMetric] = [:], managedStacks: [ManagedStack] = [],
        ungroupedContainerIDs: Set<String> = []
    ) -> [StackWorkspace] {
        let next = Inputs(containers: containers, images: images, volumes: volumes, networks: networks, stacks: managedStacks, ungrouped: ungroupedContainerIDs)
        if inputs != next {
            topology = StackWorkspaceCatalog.build(containers: containers, images: images, volumes: volumes, networks: networks, managedStacks: managedStacks, ungroupedContainerIDs: ungroupedContainerIDs)
            inputs = next
            self.metrics = nil
            topologyBuildCount += 1
        }
        if self.metrics != metrics {
            result = topology.map { $0.applyingMetrics(metrics) }
            self.metrics = metrics
        }
        return result
    }
}
