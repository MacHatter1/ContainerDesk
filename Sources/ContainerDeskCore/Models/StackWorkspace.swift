import Foundation

public enum StackWorkspaceGrouping: Sendable, Equatable {
    case managed(stackID: UUID)
    case explicitLabel(key: String, value: String)
    case sharedNamePrefix(String)
    case standalone(containerID: String)

    public var isStandalone: Bool {
        if case .standalone = self { return true }
        return false
    }
}

public enum StackWorkspaceAction: Sendable, Equatable {
    case start
    case stop
    case restart
}

public enum StackWorkspaceCommandPhase: Sendable, Equatable {
    case start
    case stop
}

public struct StackWorkspaceCommand: Sendable, Equatable {
    public let phase: StackWorkspaceCommandPhase
    public let arguments: [String]

    public init(phase: StackWorkspaceCommandPhase, arguments: [String]) {
        self.phase = phase
        self.arguments = arguments
    }
}

/// A read-only view of containers and their label-verified related resources.
public struct StackWorkspace: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let grouping: StackWorkspaceGrouping
    public let containers: [ResourceSummary]
    public let images: [ResourceSummary]
    public let volumes: [ResourceSummary]
    public let networks: [ResourceSummary]
    public let runningCount: Int
    public let stoppedCount: Int
    public let otherCount: Int
    public var missingContainerIDs: [String] = []
    /// Sum of member CPU percentages. Nil when no running member has a current sample.
    public let cpuPercent: Double?
    /// Sum of live member memory. Nil when no running member has a current sample.
    public let memoryUsageBytes: Int64?
    /// Sum of configured member limits. Members without an explicit limit do
    /// not prevent the workspace from reporting the limits that are known.
    public let memoryLimitBytes: Int64?

    public var allowsLifecycleActions: Bool {
        if case .managed = grouping { return true }
        if case .explicitLabel = grouping { return true }
        return false
    }

    public init(
        id: String,
        title: String,
        grouping: StackWorkspaceGrouping,
        containers: [ResourceSummary],
        images: [ResourceSummary] = [],
        volumes: [ResourceSummary] = [],
        networks: [ResourceSummary] = [],
        runningCount: Int,
        stoppedCount: Int,
        otherCount: Int,
        cpuPercent: Double? = nil,
        memoryUsageBytes: Int64? = nil,
        memoryLimitBytes: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.grouping = grouping
        self.containers = containers
        self.images = images
        self.volumes = volumes
        self.networks = networks
        self.runningCount = runningCount
        self.stoppedCount = stoppedCount
        self.otherCount = otherCount
        self.cpuPercent = cpuPercent
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
    }
}

/// Builds stable stack workspaces from already-sanitized resource summaries.
/// Explicit user membership takes priority over runtime labels and inferred
/// names. Unconfirmed inferred groups and individual containers are read-only.
public enum StackWorkspaceCatalog {
    private static let projectLabelKeys = [
        "com.docker.compose.project",
        "com.apple.container.compose.project",
        "dev.containerdesk.stack",
        "containerdesk.stack",
        "com.apple.container.stack",
    ]

    public static func build(
        containers: [ResourceSummary],
        images: [ResourceSummary] = [],
        volumes: [ResourceSummary] = [],
        networks: [ResourceSummary] = [],
        metrics: [String: ContainerMetric] = [:],
        managedStacks: [ManagedStack] = [],
        ungroupedContainerIDs: Set<String> = []
    ) -> [StackWorkspace] {
        let sortedContainers = containers.sorted(by: resourceOrder)
        let managedIDs = managedStacks.reduce(into: Set<String>()) { $0.formUnion($1.containerIDs) }
        let discoveredContainers = sortedContainers.filter { !managedIDs.contains($0.id) }
        var managedWorkspaces = managedStacks.map { stack in
            let members = sortedContainers.filter { stack.containerIDs.contains($0.id) }
            var workspace = makeWorkspace(
                id: stack.workspaceID, title: stack.name, grouping: .managed(stackID: stack.id),
                containers: members, images: images, volumes: volumes, networks: networks, metrics: metrics, label: nil
            )
            workspace.missingContainerIDs = stack.containerIDs.subtracting(members.map(\.id)).sorted()
            return workspace
        }
        var explicitGroups: [LabelGroup: [ResourceSummary]] = [:]
        var unlabelled: [ResourceSummary] = []

        for container in discoveredContainers where !ungroupedContainerIDs.contains(container.id) {
            if let label = projectLabel(in: container.details.labels) {
                explicitGroups[LabelGroup(key: label.key, value: label.value), default: []].append(container)
            } else {
                unlabelled.append(container)
            }
        }

        let explicitKeys = explicitGroups.keys.sorted(by: labelGroupOrder)
        var workspaces = explicitKeys.map { group in
            makeWorkspace(
                id: "label:\(group.key)=\(group.value)",
                title: group.value,
                grouping: .explicitLabel(key: group.key, value: group.value),
                containers: explicitGroups[group] ?? [],
                images: images,
                volumes: volumes,
                networks: networks,
                metrics: metrics,
                label: group
            )
        }

        let inferredGroups = inferNamePrefixGroups(unlabelled)
        workspaces.append(contentsOf: inferredGroups.map { prefix, members in
            makeWorkspace(
                id: "prefix:\(prefix)",
                title: prefix,
                grouping: .sharedNamePrefix(prefix),
                containers: members,
                images: images,
                volumes: volumes,
                networks: networks,
                metrics: metrics,
                label: nil
            )
        })

        let groupedIDs = Set(explicitGroups.values.flatMap { $0.map(\.id) } + inferredGroups.flatMap { $0.members.map(\.id) })
        for container in discoveredContainers where !groupedIDs.contains(container.id) {
            workspaces.append(makeWorkspace(
                id: "container:\(container.id)",
                title: container.title,
                grouping: .standalone(containerID: container.id),
                containers: [container],
                images: images,
                volumes: volumes,
                networks: networks,
                metrics: metrics,
                label: nil
            ))
        }

        managedWorkspaces.append(contentsOf: workspaces)
        return managedWorkspaces.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
        }
    }

    /// Returns no commands for inferred or standalone membership. Explicitly
    /// saved or labeled stacks are processed in stable member order and stop/start use
    /// the CLI's positional terminator so option-shaped IDs remain literal.
    public static func plan(_ action: StackWorkspaceAction, for workspace: StackWorkspace) -> [StackWorkspaceCommand] {
        guard workspace.allowsLifecycleActions else { return [] }
        let members = workspace.containers.sorted(by: resourceOrder)
        switch action {
        case .start:
            return members.filter(isStopped).map { .init(phase: .start, arguments: ["start", "--", $0.id]) }
        case .stop:
            return members.filter(isRunning).map { .init(phase: .stop, arguments: ["stop", "--", $0.id]) }
        case .restart:
            let running = members.filter(isRunning)
            return running.map { .init(phase: .stop, arguments: ["stop", "--", $0.id]) }
                + running.map { .init(phase: .start, arguments: ["start", "--", $0.id]) }
        }
    }

    private static func makeWorkspace(
        id: String,
        title: String,
        grouping: StackWorkspaceGrouping,
        containers: [ResourceSummary],
        images: [ResourceSummary],
        volumes: [ResourceSummary],
        networks: [ResourceSummary],
        metrics: [String: ContainerMetric],
        label: LabelGroup?
    ) -> StackWorkspace {
        let members = containers.sorted(by: resourceOrder)
        let running = members.filter(isRunning)
        let stopped = members.filter(isStopped)
        let cpuSamples = running.compactMap { metrics[$0.id]?.cpuPercent }.filter(\.isFinite)
        let memorySamples = running.compactMap { metrics[$0.id]?.memoryUsageBytes }
        let referencedImages = Set(members.compactMap { $0.details.imageReference })
        let relatedLabels: [LabelGroup]
        if let label { relatedLabels = [label] }
        else if case .managed = grouping { relatedLabels = Array(Set(members.compactMap { projectLabel(in: $0.details.labels) })) }
        else { relatedLabels = [] }
        return StackWorkspace(
            id: id,
            title: title,
            grouping: grouping,
            containers: members,
            images: images.filter { referencedImages.contains($0.details.imageReference ?? $0.id) }.sorted(by: resourceOrder),
            volumes: volumes.filter { resource in relatedLabels.contains { hasMatchingLabel(resource.details.labels, group: $0) } }.sorted(by: resourceOrder),
            networks: networks.filter { resource in relatedLabels.contains { hasMatchingLabel(resource.details.labels, group: $0) } }.sorted(by: resourceOrder),
            runningCount: running.count,
            stoppedCount: stopped.count,
            otherCount: members.count - running.count - stopped.count,
            cpuPercent: !running.isEmpty && cpuSamples.count == running.count ? cpuSamples.reduce(0, +) : nil,
            memoryUsageBytes: !running.isEmpty && memorySamples.count == running.count ? memorySamples.reduce(0, +) : nil,
            memoryLimitBytes: sum(members.compactMap(\.details.memoryLimitBytes))
        )
    }

    private static func projectLabel(in labels: [String: String]) -> LabelGroup? {
        for key in projectLabelKeys {
            if let value = labels[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return LabelGroup(key: key, value: value)
            }
        }
        return nil
    }

    private static func hasMatchingLabel(_ labels: [String: String], group: LabelGroup) -> Bool {
        labels[group.key]?.trimmingCharacters(in: .whitespacesAndNewlines) == group.value
    }

    private static func inferNamePrefixGroups(_ containers: [ResourceSummary]) -> [(prefix: String, members: [ResourceSummary])] {
        var candidateNames = Set<String>()
        for container in containers {
            for separator in container.title.indices where container.title[separator] == "-" || container.title[separator] == "_" {
                let prefix = String(container.title[..<separator])
                if isSafePrefix(prefix) { candidateNames.insert(prefix) }
            }
        }

        // A more-specific prefix from only one name must not steal that
        // container from a broader prefix genuinely shared by the stack.
        let sharedCandidates = candidateNames.filter { prefix in
            containers.lazy.filter { hasNamePrefix($0.title, prefix: prefix) }.prefix(2).count == 2
        }

        // Prefer the longest shared segment prefix. This avoids collapsing
        // independent `la-abc-*` and `la-def-*` projects into a broad `la` group.
        var membersByPrefix: [String: [ResourceSummary]] = [:]
        for container in containers {
            let matched = sharedCandidates
                .filter { hasNamePrefix(container.title, prefix: $0) }
                .sorted { $0.count > $1.count }
            guard let longest = matched.first else { continue }
            membersByPrefix[longest, default: []].append(container)
        }

        return membersByPrefix
            .filter { $0.value.count >= 2 }
            .map { ($0.key, $0.value.sorted(by: resourceOrder)) }
            .sorted { $0.prefix.localizedStandardCompare($1.prefix) == .orderedAscending }
    }

    private static func hasNamePrefix(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix), name.count > prefix.count else { return false }
        let boundaryIndex = name.index(name.startIndex, offsetBy: prefix.count)
        return name[boundaryIndex] == "-" || name[boundaryIndex] == "_"
    }

    private static func isSafePrefix(_ prefix: String) -> Bool {
        guard prefix.count >= 3, prefix.count <= 40 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return prefix.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isRunning(_ resource: ResourceSummary) -> Bool {
        (resource.state ?? "").localizedCaseInsensitiveContains("running")
    }

    private static func isStopped(_ resource: ResourceSummary) -> Bool {
        let state = (resource.state ?? "").lowercased()
        return state.contains("stopped") || state.contains("exited")
    }

    private static func sum(_ values: [Int64]) -> Int64? {
        guard !values.isEmpty else { return nil }
        return values.reduce(Int64(0)) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : result
        }
    }

    private static func resourceOrder(_ lhs: ResourceSummary, _ rhs: ResourceSummary) -> Bool {
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
    }

    private static func labelGroupOrder(_ lhs: LabelGroup, _ rhs: LabelGroup) -> Bool {
        if lhs.value != rhs.value { return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending }
        return lhs.key < rhs.key
    }

    private struct LabelGroup: Hashable {
        let key: String
        let value: String
    }
}
