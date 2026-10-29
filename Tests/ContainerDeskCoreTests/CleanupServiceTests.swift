import Foundation
import Testing
@testable import ContainerDeskCore

@Suite("Container cleanup review")
struct CleanupServiceTests {
    @Test func excludesPluginOwnedStoppedContainersButKeepsTheirResourcesReferenced() async throws {
        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [container("k8s-cluster", state: "stopped", image: "cluster-node:latest", volume: "cluster-data", network: "cluster-network", pluginOwner: "k8s"),
                         container("future-plugin-resource", state: "stopped", image: "future:latest", volume: nil, network: "", pluginOwner: "future-plugin"),
                         container("ordinary-stopped", state: "stopped", image: "ordinary:latest", volume: nil, network: "")],
            images: [image("cluster-node:latest", digest: "sha256:" + String(repeating: "a", count: 64)),
                     image("ordinary:latest", digest: "sha256:" + String(repeating: "b", count: 64)),
                     image("unused:latest", digest: "sha256:" + String(repeating: "c", count: 64))],
            networks: [network("cluster-network"), network("unused-network")],
            volumes: [volume("cluster-data"), volume("unused-volume")]
        ))

        let result = await ContainerCleanupService(client: client).scan()
        #expect(result.categoryFailures.isEmpty)
        #expect(result.candidates.contains { $0.resourceID == "ordinary-stopped" })
        #expect(!result.candidates.contains { $0.resourceID == "k8s-cluster" })
        #expect(!result.candidates.contains { $0.resourceID == "future-plugin-resource" })
        #expect(!result.candidates.contains { $0.resourceID == "cluster-node:latest" })
        #expect(!result.candidates.contains { $0.resourceID == "cluster-network" })
        #expect(!result.candidates.contains { $0.resourceID == "cluster-data" })
        #expect(result.candidates.contains { $0.resourceID == "unused:latest" })
        #expect(result.candidates.contains { $0.resourceID == "unused-network" })
        #expect(result.candidates.contains { $0.resourceID == "unused-volume" })
    }

    @Test func missingNullEmptyAndUnrelatedLabelsRemainEligible() async throws {
        let missing = container("missing-labels", state: "stopped", image: "base:latest", volume: nil, network: "")
        var nullLabels = container("null-labels", state: "stopped", image: "base:latest", volume: nil, network: "")
        var nullConfiguration = try #require(nullLabels["configuration"] as? [String: Any])
        nullConfiguration["labels"] = NSNull()
        nullLabels["configuration"] = nullConfiguration
        var emptyLabels = container("empty-labels", state: "stopped", image: "base:latest", volume: nil, network: "")
        var emptyConfiguration = try #require(emptyLabels["configuration"] as? [String: Any])
        emptyConfiguration["labels"] = [String: String]()
        emptyLabels["configuration"] = emptyConfiguration
        var unrelatedLabels = container("unrelated-labels", state: "stopped", image: "base:latest", volume: nil, network: "")
        var unrelatedConfiguration = try #require(unrelatedLabels["configuration"] as? [String: Any])
        unrelatedConfiguration["labels"] = ["project": "demo"]
        unrelatedLabels["configuration"] = unrelatedConfiguration

        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [missing, nullLabels, emptyLabels, unrelatedLabels],
            images: [], networks: [], volumes: []
        ))
        let result = await ContainerCleanupService(client: client).scan()

        #expect(result.categoryFailures.isEmpty)
        #expect(Set(result.candidates.map(\.resourceID)) == Set(["missing-labels", "null-labels", "empty-labels", "unrelated-labels"]))
    }

    @Test func malformedPluginLabelProtectsContainerAndPreservesItsDependencies() async throws {
        var malformed = container("uncertain-owner", state: "stopped", image: "cluster-node:latest", volume: "cluster-data", network: "cluster-network")
        var configuration = try #require(malformed["configuration"] as? [String: Any])
        configuration["labels"] = ["com.apple.container.plugin": 42]
        malformed["configuration"] = configuration
        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [malformed],
            images: [image("cluster-node:latest", digest: "sha256:" + String(repeating: "a", count: 64)),
                     image("unused:latest", digest: "sha256:" + String(repeating: "c", count: 64))],
            networks: [network("cluster-network"), network("unused-network")],
            volumes: [volume("cluster-data"), volume("unused-volume")]
        ))

        let result = await ContainerCleanupService(client: client).scan()
        #expect(result.categoryFailures.isEmpty)
        #expect(!result.candidates.contains { $0.resourceID == "uncertain-owner" })
        #expect(!result.candidates.contains { $0.resourceID == "cluster-node:latest" })
        #expect(!result.candidates.contains { $0.resourceID == "cluster-network" })
        #expect(!result.candidates.contains { $0.resourceID == "cluster-data" })
        #expect(result.candidates.contains { $0.resourceID == "unused:latest" })
        #expect(result.candidates.contains { $0.resourceID == "unused-network" })
        #expect(result.candidates.contains { $0.resourceID == "unused-volume" })
    }

    @Test func protectsStoppedReferencesAndImageAliasesButIncludesTaggedUnusedImages() async throws {
        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [container("stopped-1", state: "stopped", image: "docker.io/library/alpine:3", volume: "db-data", network: "private"),
                          container("digest-user", state: "stopped", image: "sha256:" + String(repeating: "c", count: 64), volume: nil, network: ""),
                          container("running-1", state: "running", image: "ghcr.io/example/app:stable", volume: nil, network: "bridge")],
            images: [image("alpine:3", digest: "sha256:" + String(repeating: "a", count: 64)),
                     image("docker.io/library/alpine:3", digest: "sha256:" + String(repeating: "a", count: 64)),
                     image("different-name:latest", digest: "sha256:" + String(repeating: "c", count: 64)),
                     image("unused:latest", digest: "sha256:" + String(repeating: "b", count: 64))],
            networks: [network("private"), network("bridge"), network("unused-net"), network("system", builtin: true)],
            volumes: [volume("db-data"), volume("unused-volume")]
        ))
        let result = await ContainerCleanupService(client: client).scan()
        #expect(result.categoryFailures.isEmpty)
        #expect(result.candidates.map(\.resourceID).contains("unused:latest"))
        #expect(!result.candidates.map(\.resourceID).contains("alpine:3"))
        #expect(!result.candidates.map(\.resourceID).contains("docker.io/library/alpine:3"))
        #expect(!result.candidates.map(\.resourceID).contains("different-name:latest"))
        #expect(!result.candidates.map(\.resourceID).contains("private"))
        #expect(!result.candidates.map(\.resourceID).contains("bridge"))
        #expect(!result.candidates.map(\.resourceID).contains("system"))
        #expect(!result.candidates.map(\.resourceID).contains("db-data"))
        #expect(result.candidates.map(\.resourceID).contains("unused-volume"))
        let unusedVolume = try #require(result.candidates.first { $0.resourceID == "unused-volume" })
        #expect(unusedVolume.sizeBytes == nil)
        #expect(unusedVolume.identity == .volume(name: "unused-volume", identityToken: "2026-01-01T00:00:00Z|local|ext4", sizeBytes: 64))
        #expect(result.candidates.map(\.resourceID).contains("stopped-1"))
        #expect(!result.candidates.map(\.resourceID).contains("running-1"))
    }

    @Test func protectsMachineBackingContainerAndBuilderAndInfrastructureImages() async throws {
        let machine = container("machine-backing", state: "stopped", image: "docker.io/library/base:latest", volume: "machine-volume", network: "machine-net")
        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [container("ordinary", state: "stopped", image: "used:latest", volume: nil, network: ""),
                         container("buildkit", state: "stopped", image: "apple/container-builder:latest", volume: "builder-data", network: "builder-net")],
            images: [image("base:latest", digest: "sha256:" + String(repeating: "c", count: 64)), image("used:latest", digest: "sha256:" + String(repeating: "d", count: 64)), image("unused:latest", digest: "sha256:" + String(repeating: "8", count: 64)), image("ghcr.io/apple/containerization/vminit:latest", digest: "sha256:" + String(repeating: "e", count: 64)), image("ghcr.io/apple/containerization/vminit:0.42.0", digest: "sha256:" + String(repeating: "6", count: 64)), image("apple/container-builder:latest", digest: "sha256:" + String(repeating: "9", count: 64)), image("apple/container-builder:old", digest: "sha256:" + String(repeating: "7", count: 64))],
            networks: [network("machine-net"), network("loose-net"), network("builder-net")], volumes: [volume("machine-volume"), volume("loose-volume"), volume("builder-data")],
            machines: [["id": "dev-machine", "status": "stopped"]],
            inspect: ["machine-backing": [machine]],
            machineInspections: ["dev-machine": ["id": "dev-machine", "image": ["reference": "base:latest", "descriptor": ["digest": "sha256:" + String(repeating: "a", count: 64)]], "containerId": "machine-backing"]],
            builderStatus: [container("buildkit", state: "stopped", image: "apple/container-builder:latest", volume: "builder-data", network: "builder-net")]
        ))
        let result = await ContainerCleanupService(client: client).scan()
        #expect(result.categoryFailures.isEmpty)
        #expect(!result.candidates.contains { $0.resourceID == "machine-backing" })
        #expect(!result.candidates.contains { $0.resourceID == "base:latest" })
        #expect(!result.candidates.contains { $0.resourceID == "machine-net" })
        #expect(!result.candidates.contains { $0.resourceID == "machine-volume" })
        #expect(!result.candidates.contains { $0.resourceID == "ghcr.io/apple/containerization/vminit:latest" })
        #expect(!result.candidates.contains { $0.resourceID == "ghcr.io/apple/containerization/vminit:0.42.0" })
        #expect(!result.candidates.contains { $0.resourceID == "apple/container-builder:latest" })
        #expect(!result.candidates.contains { $0.resourceID == "apple/container-builder:old" })
        #expect(!result.candidates.contains { $0.resourceID == "builder-net" })
        #expect(!result.candidates.contains { $0.resourceID == "builder-data" })
        #expect(!result.candidates.contains { $0.resourceID == "buildkit" })
        #expect(result.candidates.contains { $0.resourceID == "ordinary" })
        #expect(result.candidates.contains { $0.resourceID == "unused:latest" })
        #expect(result.candidates.contains { $0.resourceID == "loose-net" })
        #expect(result.candidates.contains { $0.resourceID == "loose-volume" })
    }

    @Test func missingMachineBackingInspectionDisablesAllDependencyCategories() async throws {
        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [container("orphan", state: "stopped", image: "unused:latest", volume: nil, network: "")],
            images: [image("unused:latest", digest: "sha256:" + String(repeating: "4", count: 64))],
            networks: [network("unused-net")], volumes: [volume("unused-volume")],
            machines: [["id": "dev", "status": "stopped"]],
            machineInspections: ["dev": ["id": "dev", "image": ["reference": "base:latest", "descriptor": ["digest": "sha256:" + String(repeating: "a", count: 64)]], "containerId": "missing-backing"]]
        ))
        let result = await ContainerCleanupService(client: client).scan()
        #expect(result.candidates.isEmpty)
        #expect(result.categoryFailures[.containers] != nil)
        #expect(result.categoryFailures[.images] != nil)
        #expect(result.categoryFailures[.networks] != nil)
        #expect(result.categoryFailures[.volumes] != nil)
    }

    @Test func failedOrTruncatedDependencyReadsDisableDependentCleanup() async throws {
        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [container("orphan", state: "stopped", image: "unused:latest", volume: nil, network: "")],
            images: [image("unused:latest", digest: "sha256:" + String(repeating: "f", count: 64))],
            networks: [network("unused-net")], volumes: [volume("unused-volume")]
        ), overrides: ["list --all --format json": .truncated("[]")])
        let result = await ContainerCleanupService(client: client).scan()
        #expect(result.candidates.isEmpty)
        #expect(result.categoryFailures[.containers] != nil)
        #expect(result.categoryFailures[.images] != nil)
        #expect(result.categoryFailures[.networks] != nil)
        #expect(result.categoryFailures[.volumes] != nil)
        #expect(!result.warnings.isEmpty)
    }

    @Test func malformedCategoryInventoryOnlyDisablesThatCategory() async throws {
        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [container("orphan", state: "stopped", image: "used:latest", volume: nil, network: "")],
            images: [image("used:latest", digest: "sha256:" + String(repeating: "1", count: 64)), image("unused:latest", digest: "sha256:" + String(repeating: "5", count: 64))],
            networks: [network("unused-net")], volumes: [volume("unused-volume")]
        ), overrides: ["network list --format json": .malformed("not-json")])
        let result = await ContainerCleanupService(client: client).scan()
        #expect(result.categoryFailures[.networks] != nil)
        #expect(result.candidates.contains { $0.category == .containers })
        #expect(result.candidates.contains { $0.category == .images })
        #expect(result.candidates.contains { $0.category == .volumes })
        #expect(!result.candidates.contains { $0.category == .networks })
    }

    @Test func revalidationRejectsChangedDependenciesAndDisappearedItems() async throws {
        let before = FixtureSet.complete(containers: [container("stopped", state: "stopped", image: "old:tag", volume: nil, network: "")], images: [image("free:tag", digest: "sha256:" + String(repeating: "2", count: 64))], networks: [], volumes: [])
        let changed = FixtureSet.complete(containers: [container("stopped", state: "stopped", image: "new:tag", volume: nil, network: "")], images: [image("free:tag", digest: "sha256:" + String(repeating: "2", count: 64))], networks: [], volumes: [])
        let recreated = FixtureSet.complete(containers: [container("stopped", state: "stopped", image: "old:tag", volume: nil, network: "", creationDate: "2026-02-01T00:00:00Z")], images: [image("free:tag", digest: "sha256:" + String(repeating: "2", count: 64))], networks: [], volumes: [])
        let missing = FixtureSet.complete(containers: [], images: [], networks: [], volumes: [])
        let client = ScriptedCleanupClient(sequence: [before, changed, recreated, missing])
        let service = ContainerCleanupService(client: client)
        let review = await service.scan()
        let candidate = try #require(review.candidates.first { $0.resourceID == "stopped" })
        #expect(!(await service.revalidate(candidate)).eligible)
        #expect(!(await service.revalidate(candidate)).eligible)
        #expect(!(await service.revalidate(candidate)).eligible)
    }

    @Test func revalidationRejectsStoppedContainerThatGainsPluginOwnership() async throws {
        let before = FixtureSet.complete(
            containers: [container("stopped", state: "stopped", image: "base:latest", volume: nil, network: "")],
            images: [], networks: [], volumes: []
        )
        let newlyPluginOwned = FixtureSet.complete(
            containers: [container("stopped", state: "stopped", image: "base:latest", volume: nil, network: "", pluginOwner: "k8s")],
            images: [], networks: [], volumes: []
        )
        let service = ContainerCleanupService(client: ScriptedCleanupClient(sequence: [before, newlyPluginOwned]))

        let review = await service.scan()
        let candidate = try #require(review.candidates.first { $0.resourceID == "stopped" })
        let eligibility = await service.revalidate(candidate)
        #expect(!eligibility.eligible)
    }

    @Test func missingContainerCreationIdentityDisablesDependentCleanup() async throws {
        let client = ScriptedCleanupClient(fixtures: .complete(
            containers: [container("uncertain", state: "stopped", image: "free:tag", volume: nil, network: "", creationDate: nil)],
            images: [image("free:tag", digest: "sha256:" + String(repeating: "2", count: 64))],
            networks: [network("unused-net")], volumes: [volume("unused-volume")]
        ))
        let result = await ContainerCleanupService(client: client).scan()
        #expect(result.candidates.isEmpty)
        #expect(result.categoryFailures[.containers] != nil)
        #expect(result.categoryFailures[.images] != nil)
        #expect(result.categoryFailures[.networks] != nil)
        #expect(result.categoryFailures[.volumes] != nil)
    }

    @Test func commandsUseExactReviewedOperandAndTerminateOptionParsing() throws {
        let service = ContainerCleanupService(client: ScriptedCleanupClient(fixtures: .empty))
        let candidate = CleanupCandidate(category: .images, resourceID: "--odd:tag", title: "--odd:tag", reason: "unused", identity: .image(digest: "sha256:" + String(repeating: "3", count: 64), reference: "--odd:tag", aliases: ["--odd:tag"], sizeBytes: nil))
        #expect(try service.command(for: candidate).arguments == ["image", "delete", "--", "--odd:tag"])
        let mismatch = CleanupCandidate(category: .volumes, resourceID: "--all", title: "", reason: "", identity: .volume(name: "different", identityToken: "", sizeBytes: nil))
        #expect(throws: CleanupCommandError.self) { try service.command(for: mismatch) }
    }

    @Test func removalVerificationRequiresAnExplicitSuccessfulInventory() async throws {
        let candidate = CleanupCandidate(category: .containers, resourceID: "gone", title: "gone", reason: "stopped", identity: .container(id: "gone", creationDate: "2026-01-01T00:00:00Z", state: "stopped", image: "base:latest", imageDigest: "sha256:" + String(repeating: "a", count: 64), volumes: [], networks: []))
        let removed = await ContainerCleanupService(client: ScriptedCleanupClient(fixtures: .empty)).verifyRemoval(candidate)
        #expect(removed == .removed)

        let presentClient = ScriptedCleanupClient(fixtures: .complete(containers: [container("gone", state: "stopped", image: "base:latest", volume: nil, network: "")], images: [], networks: [], volumes: []))
        let present = await ContainerCleanupService(client: presentClient).verifyRemoval(candidate)
        #expect(present == .stillPresent("The reviewed resource is still present."))

        let malformedClient = ScriptedCleanupClient(fixtures: .empty, overrides: ["list --all --format json": .malformed("truncated { json")])
        let malformed = await ContainerCleanupService(client: malformedClient).verifyRemoval(candidate)
        #expect(malformed == .unverified("Could not verify whether the reviewed resource was removed."))

        let truncatedClient = ScriptedCleanupClient(fixtures: .empty, overrides: ["list --all --format json": .truncated("[]")])
        let truncated = await ContainerCleanupService(client: truncatedClient).verifyRemoval(candidate)
        #expect(truncated == .unverified("Could not verify whether the reviewed resource was removed."))
    }

    private func container(_ id: String, state: String, image: String, volume: String?, network: String, creationDate: String? = "2026-01-01T00:00:00Z", pluginOwner: String? = nil) -> [String: Any] {
        var mounts: [[String: Any]] = []
        if let volume { mounts = [["type": ["volume": ["name": volume]], "source": volume, "destination": "/data", "options": []]] }
        let networks: [[String: Any]] = network.isEmpty ? [] : [["network": network, "options": ["hostname": id]]]
        var configuration: [String: Any] = ["id": id, "image": ["reference": image, "descriptor": ["digest": "sha256:" + String(repeating: "a", count: 64), "mediaType": "application/vnd.oci.image.index.v1+json"]], "mounts": mounts, "networks": networks]
        if let creationDate { configuration["creationDate"] = creationDate }
        if let pluginOwner { configuration["labels"] = ["com.apple.container.plugin": pluginOwner] }
        return ["id": id, "configuration": configuration, "status": ["state": state, "networks": []]]
    }
    private func image(_ ref: String, digest: String) -> [String: Any] {
        ["id": String(digest.dropFirst("sha256:".count)), "configuration": ["name": ref, "descriptor": ["digest": digest]], "variants": [["digest": digest, "size": 120]]]
    }
    private func network(_ name: String, builtin: Bool = false) -> [String: Any] {
        ["id": name, "configuration": ["name": name, "labels": builtin ? ["com.apple.container.resource.role": "builtin"] : [:], "creationDate": "2026-01-01T00:00:00Z", "plugin": "vmnet", "mode": "bridged"], "status": [:]]
    }
    private func volume(_ name: String) -> [String: Any] {
        ["id": name, "configuration": ["name": name, "driver": "local", "format": "ext4", "source": "/tmp/volume", "sizeInBytes": 64, "creationDate": "2026-01-01T00:00:00Z"]]
    }
}

private struct FixtureSet: Sendable {
    let commands: [String: String]
    let inspect: [String: String]
    let machineInspect: [String: String]

    static let empty = complete(containers: [], images: [], networks: [], volumes: [])

    static func complete(containers: [[String: Any]], images: [[String: Any]], networks: [[String: Any]], volumes: [[String: Any]], machines: [[String: Any]] = [], inspect: [String: [[String: Any]]] = [:], machineInspections: [String: [String: Any]] = [:], builderStatus: [[String: Any]] = []) -> FixtureSet {
        func encoded(_ value: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), encoding: .utf8) ?? "" }
        let commands = [
            "list --all --format json": encoded(containers),
            "image list --format json --verbose": encoded(images),
            "network list --format json": encoded(networks),
            "volume list --format json": encoded(volumes),
            "builder status --format json": encoded(builderStatus),
            "machine list --format json": encoded(machines),
            "system property list --format json": encoded(["build": ["image": "apple/container-builder:latest"], "vminit": ["image": "ghcr.io/apple/containerization/vminit:0.42.1"]]),
            "system df --format json": encoded(["images": ["total": images.count, "active": 0, "sizeInBytes": 1_024, "reclaimable": 1_024], "containers": ["total": containers.count, "active": 0, "sizeInBytes": 2_048, "reclaimable": 1_024], "volumes": ["total": volumes.count, "active": 0, "sizeInBytes": 3_072, "reclaimable": 2_048]])
        ]
        var inspects: [String: String] = [:]
        for (id, rows) in inspect { inspects["inspect -- \(id)"] = encoded(rows) }
        var machineInspect = [String: String]()
        for (id, row) in machineInspections { machineInspect["machine inspect -- \(id)"] = encoded([row]) }
        return FixtureSet(commands: commands, inspect: inspects, machineInspect: machineInspect)
    }
}

private actor ScriptedCleanupClient: ContainerClient {
    enum Override: Sendable { case truncated(String), malformed(String) }
    private var sets: [FixtureSet]
    private var activeSet: FixtureSet?
    private var overrides: [String: Override]

    init(fixtures: FixtureSet, overrides: [String: Override] = [:]) { self.sets = [fixtures]; self.activeSet = fixtures; self.overrides = overrides }
    init(sequence: [FixtureSet]) { self.sets = sequence; self.activeSet = nil; self.overrides = [:] }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let key = request.arguments.joined(separator: " ")
        if let override = overrides[key] {
            switch override {
            case .truncated(let output): return result(output, truncated: true)
            case .malformed(let output): return result(output)
            }
        }
        if key == "list --all --format json" {
            activeSet = sets.first ?? .empty
            if sets.count > 1 { sets.removeFirst() }
        }
        let current = activeSet ?? sets.first ?? .empty
        let output = current.commands[key] ?? current.inspect[key] ?? current.machineInspect[key] ?? "[]"
        return result(output)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    private func result(_ output: String, truncated: Bool = false) -> CommandResult {
        CommandResult(standardOutput: output, standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero, outputTruncated: truncated)
    }
}
