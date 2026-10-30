import Testing
@testable import ContainerDeskCore

struct StackWorkspaceCatalogTests {
    @Test func explicitComposeProjectLabelsTakePriorityOverNameInference() {
        let containers = [
            container("api", labels: ["com.docker.compose.project": "shop", "com.apple.container.stack": "other"]),
            container("worker", labels: ["com.docker.compose.project": "shop"]),
        ]

        let workspaces = StackWorkspaceCatalog.build(containers: containers)

        #expect(workspaces.count == 1)
        #expect(workspaces[0].id == "label:com.docker.compose.project=shop")
        #expect(workspaces[0].title == "shop")
        #expect(workspaces[0].grouping == .explicitLabel(key: "com.docker.compose.project", value: "shop"))
        #expect(workspaces[0].containers.map(\.id) == ["api-id", "worker-id"])
    }

    @Test func recognizesContainerDeskAndAppleComposeStackLabels() {
        let containers = [
            container("one", labels: ["com.apple.container.compose.project": "apple-compose"]),
            container("two", labels: ["dev.containerdesk.stack": "desk"]),
            container("three", labels: ["containerdesk.stack": "legacy-desk"]),
            container("four", labels: ["com.apple.container.stack": "apple-stack"]),
        ]

        let workspaces = StackWorkspaceCatalog.build(containers: containers)

        #expect(workspaces.map(\.title) == ["apple-compose", "apple-stack", "desk", "legacy-desk"])
        #expect(workspaces.allSatisfy { $0.allowsLifecycleActions })
    }

    @Test func groupsSharedSafePrefixesOnlyWhenAtLeastTwoContainersMatch() {
        let workspaces = StackWorkspaceCatalog.build(containers: [
            container("storefront-api"),
            container("storefront-db"),
            container("standalone"),
        ])

        #expect(workspaces.map(\.title) == ["standalone", "storefront"])
        #expect(workspaces.first(where: { $0.title == "storefront" })?.grouping == .sharedNamePrefix("storefront"))
        #expect(workspaces.first(where: { $0.title == "standalone" })?.grouping == .standalone(containerID: "standalone-id"))
    }

    @Test func doesNotGroupNamesWithOnlyACommonSubstringOrUnsafeBoundary() {
        let workspaces = StackWorkspaceCatalog.build(containers: [
            container("storefront-api"),
            container("storefronted-worker"),
            container("api-storefront-db"),
        ])

        #expect(workspaces.count == 3)
        #expect(workspaces.allSatisfy { if case .standalone = $0.grouping { true } else { false } })
    }

    @Test func inferredGroupingUsesTheLongestSharedPrefixInsteadOfACommonShortPrefix() {
        let workspaces = StackWorkspaceCatalog.build(containers: [
            container("la-abc-database"),
            container("la-abc-redis"),
            container("la-def-database"),
            container("la-def-redis"),
        ])

        #expect(workspaces.map(\.title) == ["la-abc", "la-def"])
        #expect(workspaces.map { $0.containers.count } == [2, 2])
    }

    @Test func uniqueDeeperPrefixDoesNotStealAMemberFromASharedPrefix() {
        let workspaces = StackWorkspaceCatalog.build(containers: [
            container("storefront-api-v2"),
            container("storefront-worker"),
        ])

        #expect(workspaces.map(\.title) == ["storefront"])
        #expect(workspaces[0].containers.map(\.title) == ["storefront-api-v2", "storefront-worker"])
    }

    @Test func attachesLabelMatchedNetworksAndVolumesAndExactReferencedImages() throws {
        let containers = [container("shop-api", labels: ["com.docker.compose.project": "shop"], image: "example.invalid/shop/api:v2")]
        let images = [
            ResourceSummary(id: "img-api", title: "example.invalid/shop/api", details: ResourceDetails(imageReference: "example.invalid/shop/api:v2")),
            ResourceSummary(id: "img-other", title: "example.invalid/shop/api", details: ResourceDetails(imageReference: "example.invalid/shop/api:v1")),
        ]
        let volumes = [
            ResourceSummary(id: "vol-db", title: "shop-db", details: ResourceDetails(labels: ["com.docker.compose.project": "shop"])),
            ResourceSummary(id: "vol-other", title: "cache", details: ResourceDetails(labels: ["com.docker.compose.project": "other"])),
        ]
        let networks = [ResourceSummary(id: "net-shop", title: "shop_default", details: ResourceDetails(labels: ["com.docker.compose.project": "shop"]))]

        let workspace = try #require(StackWorkspaceCatalog.build(containers: containers, images: images, volumes: volumes, networks: networks).first)

        #expect(workspace.images.map(\.id) == ["img-api"])
        #expect(workspace.volumes.map(\.id) == ["vol-db"])
        #expect(workspace.networks.map(\.id) == ["net-shop"])
    }

    @Test func workspaceOrderingAndMemberOrderingAreDeterministic() {
        let containers = [
            container("zeta-worker", labels: ["com.docker.compose.project": "zeta"]),
            container("beta-db", labels: ["com.docker.compose.project": "beta"]),
            container("alpha-api", labels: ["com.docker.compose.project": "alpha"]),
            container("beta-api", labels: ["com.docker.compose.project": "beta"]),
        ]

        let workspaces = StackWorkspaceCatalog.build(containers: containers)

        #expect(workspaces.map(\.title) == ["alpha", "beta", "zeta"])
        #expect(workspaces[1].containers.map(\.title) == ["beta-api", "beta-db"])
    }

    @Test func aggregatesLiveMetricsAndContainerStateCounts() {
        let containers = [
            container("shop-api", labels: ["com.docker.compose.project": "shop"], state: "running", cpus: 2, memoryLimit: 1000),
            container("shop-worker", labels: ["com.docker.compose.project": "shop"], state: "running", cpus: 1, memoryLimit: 2000),
            container("shop-old", labels: ["com.docker.compose.project": "shop"], state: "stopped"),
            container("shop-pending", labels: ["com.docker.compose.project": "shop"], state: "created"),
        ]
        let metrics = ["shop-api-id": ContainerMetric(cpuPercent: 25, memoryUsageBytes: 400), "shop-worker-id": ContainerMetric(cpuPercent: 10, memoryUsageBytes: 600)]

        let workspace = StackWorkspaceCatalog.build(containers: containers, metrics: metrics)[0]

        #expect(workspace.runningCount == 2)
        #expect(workspace.stoppedCount == 1)
        #expect(workspace.otherCount == 1)
        #expect(workspace.cpuPercent == 35)
        #expect(workspace.memoryUsageBytes == 1000)
        #expect(workspace.memoryLimitBytes == 3000)
    }

    @Test func lifecyclePlansAreUnavailableForInferredOrStandaloneMembership() {
        let inferred = StackWorkspaceCatalog.build(containers: [container("storefront-api"), container("storefront-db")])
        let standalone = StackWorkspaceCatalog.build(containers: [container("one-off")])

        #expect(inferred[0].allowsLifecycleActions == false)
        #expect(StackWorkspaceCatalog.plan(.stop, for: inferred[0]).isEmpty)
        #expect(standalone[0].allowsLifecycleActions == false)
        #expect(StackWorkspaceCatalog.plan(.start, for: standalone[0]).isEmpty)
    }

    @Test func actionPlansUseLiteralTargetTerminatorAndRestartIsStopThenStart() throws {
        let workspace = StackWorkspaceCatalog.build(containers: [
            container("shop-api", id: "--all", labels: ["com.docker.compose.project": "shop"], state: "running"),
            container("shop-db", id: "db-id", labels: ["com.docker.compose.project": "shop"], state: "stopped"),
        ])[0]

        let start = StackWorkspaceCatalog.plan(.start, for: workspace)
        let stop = StackWorkspaceCatalog.plan(.stop, for: workspace)
        let restart = StackWorkspaceCatalog.plan(.restart, for: workspace)

        #expect(start.map(\.arguments) == [["start", "--", "db-id"]])
        #expect(stop.map(\.arguments) == [["stop", "--", "--all"]])
        #expect(restart.map(\.arguments) == [["stop", "--", "--all"], ["start", "--", "--all"]])
        #expect(restart.map(\.phase) == [.stop, .start])
    }

    @Test func actionPlansSkipMembersWhoseCurrentStateDoesNotFitTheAction() {
        let workspace = StackWorkspaceCatalog.build(containers: [
            container("shop-running", id: "running-id", labels: ["com.docker.compose.project": "shop"], state: "running"),
            container("shop-stopped", id: "stopped-id", labels: ["com.docker.compose.project": "shop"], state: "exited"),
            container("shop-created", id: "created-id", labels: ["com.docker.compose.project": "shop"], state: "created"),
            container("shop-unknown", id: "unknown-id", labels: ["com.docker.compose.project": "shop"]),
        ])[0]

        #expect(StackWorkspaceCatalog.plan(.start, for: workspace).map(\.arguments) == [["start", "--", "stopped-id"]])
        #expect(StackWorkspaceCatalog.plan(.stop, for: workspace).map(\.arguments) == [["stop", "--", "running-id"]])
        #expect(StackWorkspaceCatalog.plan(.restart, for: workspace).map(\.arguments) == [["stop", "--", "running-id"], ["start", "--", "running-id"]])
    }

    private func container(
        _ name: String,
        id: String? = nil,
        labels: [String: String] = [:],
        image: String? = nil,
        state: String? = nil,
        cpus: Int? = nil,
        memoryLimit: Int64? = nil
    ) -> ResourceSummary {
        ResourceSummary(
            id: id ?? name + "-id",
            title: name,
            state: state,
            details: ResourceDetails(
                imageReference: image,
                labels: labels,
                cpuAllocation: cpus,
                memoryLimitBytes: memoryLimit
            )
        )
    }
}
