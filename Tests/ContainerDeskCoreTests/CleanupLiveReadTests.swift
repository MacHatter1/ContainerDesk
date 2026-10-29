import Foundation
import Testing
@testable import ContainerDeskCore

struct CleanupLiveReadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTAINERDESK_CLEANUP_LIVE_READ_CHECK"] == "1"))
    func actualRuntimeScanProtectsReferencedResources() async throws {
        let client = ProcessContainerClient()
        let scan = await ContainerCleanupService(client: client).scan()
        #expect(scan.categoryFailures.isEmpty, "Cleanup could not decode the installed runtime inventory: \(scan.categoryFailures)")
        let raw = try await client.run(CommandRequest(arguments: ["list", "--all", "--format", "json"], suppressOutputEvents: true))
        #expect(raw.succeeded && !raw.outputTruncated)
        let containers = try #require(JSONSerialization.jsonObject(with: Data(raw.standardOutput.utf8)) as? [[String: Any]])
        var runningIDs = Set<String>()
        var usedVolumes = Set<String>()
        var usedNetworks = Set<String>()
        var usedImageDigests = Set<String>()
        for item in containers {
            let config = try #require(item["configuration"] as? [String: Any])
            let status = try #require(item["status"] as? [String: Any])
            if status["state"] as? String == "running", let id = config["id"] as? String { runningIDs.insert(id) }
            for mount in (config["mounts"] as? [[String: Any]]) ?? [] {
                if let type = mount["type"] as? [String: Any], let volume = type["volume"] as? [String: Any], let name = volume["name"] as? String { usedVolumes.insert(name) }
            }
            for network in (config["networks"] as? [[String: Any]]) ?? [] {
                if let name = network["network"] as? String { usedNetworks.insert(name) }
            }
            if let image = config["image"] as? [String: Any], let descriptor = image["descriptor"] as? [String: Any], let digest = descriptor["digest"] as? String { usedImageDigests.insert(digest) }
        }
        for candidate in scan.candidates {
            switch candidate.category {
            case .containers:
                #expect(!runningIDs.contains(candidate.resourceID))
                #expect(candidate.resourceID != "buildkit")
            case .volumes: #expect(!usedVolumes.contains(candidate.resourceID))
            case .networks: #expect(!usedNetworks.contains(candidate.resourceID))
            case .images:
                if case .image(let digest, _, _, _) = candidate.identity { #expect(!usedImageDigests.contains(digest)) }
            }
        }
        print("cleanup_live candidates=\(scan.candidates.count) disabled_categories=\(scan.categoryFailures.count) storage_available=\(scan.diskUsage != nil)")
    }
}
