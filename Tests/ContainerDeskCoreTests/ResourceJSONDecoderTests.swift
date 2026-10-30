import Foundation
import Testing
@testable import ContainerDeskCore

struct ResourceJSONDecoderTests {
    @Test(arguments: [ContainerSection.containers, .volumes, .networks])
    func summariesApplyTheSameCredentialKeyPolicyAsInspect(_ section: ContainerSection) throws {
        let labels = ["apiKey": "hidden-camel", "com.example.api-key": "hidden-hyphen", "privateKey": "hidden-private", "access_key": "hidden-access", "com.docker.compose.project": "storefront", "com.apple.container.plugin": "compose"]
        let data = try JSONSerialization.data(withJSONObject: [["id": "fixture", "configuration": ["name": "fixture", "labels": labels]]])
        let item = try #require(ResourceJSONDecoder.summaries(from: data, section: section).first)
        #expect(item.details.labels == ["com.docker.compose.project": "storefront", "com.apple.container.plugin": "compose"])
        let inspect = try ResourceJSONRedactor.redact(String(decoding: data, as: UTF8.self))
        #expect(!inspect.contains("hidden-"))
        #expect(inspect.contains("storefront"))
    }

    @Test func decodesPinnedMachineListResourceFields() throws {
        let json = #"[{"id":"dev","status":"running","default":true,"cpus":4,"memory":4294967296}]"#
        let machine = try #require(ResourceJSONDecoder.summaries(from: Data(json.utf8), section: .machines).first)
        #expect(machine.details.cpuCount == 4)
        #expect(machine.details.memoryBytes == 4_294_967_296)
        #expect(machine.details.isDefault == true)
    }

    @Test func decodesOnlyCuratedContainerMetadata() throws {
        let json = #"[{"id":"fixture-container-1","configuration":{"image":{"reference":"example.invalid/demo:dev"},"initProcess":{"environment":["TOKEN=fixture-only"]},"publishedPorts":[{"containerPort":3000,"hostPort":8080,"hostAddress":"127.0.0.1","proto":"tcp","count":1}],"resources":{"cpus":2,"memoryInBytes":536870912},"labels":{"project":"fixture","password":"do-not-retain"}},"status":{"state":"running"}}]"#
        let items = try ResourceJSONDecoder.summaries(from: Data(json.utf8), section: .containers)
        #expect(items == [ResourceSummary(
            id: "fixture-container-1",
            title: "fixture-container-1",
            subtitle: nil,
            state: "running",
            details: ResourceDetails(
                imageReference: "example.invalid/demo:dev",
                publishedPorts: [PublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 3000, proto: "tcp", count: 1)],
                labels: ["project": "fixture"],
                cpuAllocation: 2,
                memoryLimitBytes: 536870912
            )
        )])
        #expect(!String(describing: items).contains("fixture-only"))
        #expect(!String(describing: items).contains("do-not-retain"))
    }

    @Test func imageSizeComesFromVerboseVariantAndParsesHostPortTag() throws {
        let json = #"[{"id":"shared-content-digest","configuration":{"name":"localhost:5000/team/demo:v2","descriptor":{"size":9}},"variants":[{"digest":"sha256:fixture-digest","platform":{"os":"linux","architecture":"arm64"},"size":2048},{"digest":"sha256:attestation","platform":{"os":"unknown","architecture":"unknown"},"size":4096}]}]"#
        let items = try ResourceJSONDecoder.summaries(from: Data(json.utf8), section: .images)
        #expect(items == [ResourceSummary(
            id: "localhost:5000/team/demo:v2",
            title: "localhost:5000/team/demo",
            details: ResourceDetails(
                imageReference: "localhost:5000/team/demo:v2",
                imageRepository: "localhost:5000/team/demo",
                imageTag: "v2",
                platform: "linux/arm64",
                sizeBytes: 2048,
                digest: "sha256:fixture-digest"
            )
        )])
    }

    @Test func imageAliasesWithSameContentDigestKeepDistinctReferenceIDs() throws {
        let json = #"[{"id":"same-digest","configuration":{"name":"docker.io/library/demo:stable"},"variants":[{"digest":"sha256:same","platform":{"os":"linux","architecture":"arm64"},"size":100}]},{"id":"same-digest","configuration":{"name":"docker.io/library/demo@sha256:same"},"variants":[{"digest":"sha256:same","platform":{"os":"linux","architecture":"arm64"},"size":100}]}]"#
        let items = try ResourceJSONDecoder.summaries(from: Data(json.utf8), section: .images)
        #expect(items.map(\.id) == ["docker.io/library/demo:stable", "docker.io/library/demo@sha256:same"])
        #expect(items.map(\.details.digest) == ["sha256:same", "sha256:same"])
    }

    @Test func digestReferenceDoesNotBecomeATag() throws {
        let json = #"[{"id":"img-digest","configuration":{"name":"localhost:5000/team/demo@sha256:fixturehash","descriptor":{"size":9}},"variants":[]}]"#
        let items = try ResourceJSONDecoder.summaries(from: Data(json.utf8), section: .images)
        #expect(items.first?.title == "localhost:5000/team/demo")
        #expect(items.first?.details.imageTag == nil)
        #expect(items.first?.details.digest == "sha256:fixturehash")
    }

    @Test func decodesVolumeNetworkMachineAndRegistryAllowlist() throws {
        let fixtures: [(String, ResourceSummary, ContainerSection)] = [
            (
                #"[{"id":"volume-fixture","configuration":{"name":"cache","driver":"local","sizeInBytes":42,"labels":{"service":"cache"}}}]"#,
                ResourceSummary(id: "volume-fixture", title: "cache", subtitle: "volume-fixtu", details: ResourceDetails(sizeBytes: 42, driver: "local", labels: ["service": "cache"])),
                .volumes
            ),
            (
                #"[{"id":"network-fixture","configuration":{"name":"private","plugin":"bridge","mode":"nat","options":{"internal":true},"labels":{"project":"fixture"}},"status":{"ipv4Subnet":"192.0.2.0/24"}}]"#,
                ResourceSummary(id: "network-fixture", title: "private", subtitle: "network-fixt", details: ResourceDetails(driver: "bridge", ipv4Subnet: "192.0.2.0/24", isInternal: true, labels: ["project": "fixture"])),
                .networks
            ),
            (
                #"[{"id":"machine-fixture","configuration":{"name":"dev","resources":{"cpus":4,"memoryInBytes":4294967296},"isDefault":true},"status":{"state":"running"}}]"#,
                ResourceSummary(id: "machine-fixture", title: "dev", subtitle: "machine-fixt", state: "running", details: ResourceDetails(cpuCount: 4, memoryBytes: 4294967296, isDefault: true)),
                .machines
            ),
            (
                #"[{"id":"ghcr.io","username":"fixture-user"}]"#,
                ResourceSummary(id: "ghcr.io", title: "ghcr.io", details: ResourceDetails(registryUsername: "fixture-user")),
                .registries
            ),
        ]
        for (json, expected, section) in fixtures {
            #expect(try ResourceJSONDecoder.summaries(from: Data(json.utf8), section: section) == [expected])
        }
    }

    @Test func rejectsUnexpectedJSONShapeInsteadOfShowingAnEmptyList() {
        #expect(throws: ResourceJSONDecoder.DecodeError.self) {
            try ResourceJSONDecoder.summaries(from: Data(#"{"notAResourceList":[]}"#.utf8))
        }
    }
}
