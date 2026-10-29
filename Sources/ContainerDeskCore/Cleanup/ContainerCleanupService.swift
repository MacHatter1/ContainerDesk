import Foundation

/// Builds a fresh dependency-aware cleanup review from structured CLI output.
/// Every read is bounded and parsed through an allowlist; raw command output is never
/// copied into candidates or warnings.
public struct ContainerCleanupService: Sendable {
    private let client: any ContainerClient

    public init(client: any ContainerClient) {
        self.client = client
    }

    public func scan() async -> CleanupScan {
        var warnings: [String] = []
        var failures: [CleanupCategory: String] = [:]

        let containersRead = await readJSON(["list", "--all", "--format", "json"], label: "container inventory")
        let imagesRead = await readJSON(["image", "list", "--format", "json", "--verbose"], label: "image inventory")
        let networksRead = await readJSON(["network", "list", "--format", "json"], label: "network inventory")
        let volumesRead = await readJSON(["volume", "list", "--format", "json"], label: "volume inventory")
        let builderRead = await readJSON(["builder", "status", "--format", "json"], label: "builder status")
        let machinesRead = await readJSON(["machine", "list", "--format", "json"], label: "machine inventory")
        let systemConfigRead = await readJSON(["system", "property", "list", "--format", "json"], label: "system properties")
        let diskRead = await readJSON(["system", "df", "--format", "json"], label: "disk usage")

        func recordFailure(_ category: CleanupCategory, _ result: ReadResult, detail: String) {
            guard case .failure(let reason) = result else { return }
            failures[category] = reason
            warnings.append("\(detail) unavailable; \(category.title.lowercased()) cleanup is disabled.")
        }

        recordFailure(.containers, containersRead, detail: "Container dependency inventory")
        recordFailure(.images, imagesRead, detail: "Image inventory")
        recordFailure(.networks, networksRead, detail: "Network inventory")
        recordFailure(.volumes, volumesRead, detail: "Volume inventory")

        let infrastructureRepositories: Set<String>
        if case .success(let json) = systemConfigRead,
           let object = json as? [String: Any],
           let build = object["build"] as? [String: Any], let builderImage = Self.string(build["image"]),
           let vminit = object["vminit"] as? [String: Any], let initImage = Self.string(vminit["image"]) {
            infrastructureRepositories = Self.knownInfrastructureRepositories
                .union([builderImage, initImage].reduce(into: Set<String>()) { $0.formUnion(Self.repositoryAliases($1)) })
        } else {
            infrastructureRepositories = []
            failures[.images] = "System infrastructure image configuration could not be verified."
            warnings.append("System infrastructure image configuration unavailable; image cleanup is disabled.")
        }

        let containerRecords: [ContainerRecord]
        if case .success(let json) = containersRead, let rows = Self.array(json) {
            do { containerRecords = try rows.map(Self.decodeContainer) }
            catch {
                containerRecords = []
                failures[.containers] = "Container inventory was incomplete or malformed."
                warnings.append("Container dependency inventory was incomplete; cleanup candidates that depend on it are disabled.")
            }
        } else {
            containerRecords = []
            if case .success = containersRead {
                failures[.containers] = "Container inventory was incomplete or malformed."
                warnings.append("Container dependency inventory was incomplete; cleanup candidates that depend on it are disabled.")
            }
        }

        var builderIDs = Set<String>()
        var builderImages = Set<String>()
        var builderImageDigests = Set<String>()
        var builderContainers: [ContainerRecord] = []
        let builderVerified: Bool
        if case .success(let json) = builderRead {
            do {
                let rows = Self.array(json) ?? (json as? [String: Any]).map { [$0] }
                guard let rows else { throw DecodeFailure.malformed }
                for row in rows {
                    let builder = try Self.decodeContainer(row)
                    builderIDs.insert(builder.id)
                    builderImages.insert(builder.image)
                    builderImageDigests.insert(builder.imageDigest)
                    builderContainers.append(builder)
                }
                builderVerified = true
            } catch {
                builderVerified = false
                failures[.containers] = "Builder status could not be verified."
                warnings.append("Builder status was malformed; container cleanup is disabled.")
            }
        } else {
            builderVerified = false
            failures[.containers] = "Builder status could not be verified."
            warnings.append("Builder status unavailable; container cleanup is disabled.")
        }

        let machineIDs: [String]
        if case .success(let json) = machinesRead, let rows = Self.array(json) {
            var ids: [String] = []
            var malformed = false
            for object in rows {
                guard let id = Self.string(object["id"]), !id.isEmpty else {
                    malformed = true
                    continue
                }
                ids.append(id)
            }
            machineIDs = ids
            if malformed {
                failures[.containers] = "Machine backing-container references could not be verified."
                warnings.append("Machine dependency inventory was incomplete; container cleanup is disabled.")
            }
        } else {
            machineIDs = []
            failures[.containers] = "Machine backing-container references could not be verified."
            warnings.append("Machine inventory unavailable; container cleanup is disabled.")
            if case .success = machinesRead {
                failures[.containers] = "Machine inventory was incomplete or malformed."
            }
        }

        // The 1.5 machine list omits containerId, so inspect each machine to obtain its
        // backing ID and image reference. Machine backing containers are hidden from list.
        var machineContainers: [ContainerRecord] = []
        var machineImages = Set<String>()
        var machineImageDigests = Set<String>()
        var machineDependenciesComplete = true
        for machineID in machineIDs {
            let inspectedMachine = await readJSON(["machine", "inspect", "--", machineID], label: "machine inspection")
            guard case .success(let machineJSON) = inspectedMachine,
                  let machineRows = Self.array(machineJSON), let machine = machineRows.first,
                  let imageObject = machine["image"] as? [String: Any],
                  let machineImage = Self.string(imageObject["reference"]),
                  let imageDescriptor = imageObject["descriptor"] as? [String: Any],
                  let machineImageDigest = Self.string(imageDescriptor["digest"]), Self.normalizeDigest(machineImageDigest) != nil else {
                machineDependenciesComplete = false
                continue
            }
            machineImages.insert(machineImage)
            machineImageDigests.insert(machineImageDigest)
            guard let backingID = Self.string(machine["containerId"]), !backingID.isEmpty else { continue }
            let inspectedContainer = await readJSON(["inspect", "--", backingID], label: "machine backing container")
            guard case .success(let json) = inspectedContainer, let rows = Self.array(json), let row = rows.first,
                  let record = try? Self.decodeContainer(row), record.id == backingID else {
                machineDependenciesComplete = false
                continue
            }
            machineContainers.append(record)
        }
        if !machineDependenciesComplete {
            failures[.containers] = "Machine backing-container details could not be verified."
            failures[.images] = "Machine backing-container image dependencies could not be verified."
            failures[.networks] = "Machine backing-container network dependencies could not be verified."
            failures[.volumes] = "Machine backing-container volume dependencies could not be verified."
            warnings.append("A machine backing container could not be inspected; cleanup categories that depend on container references are disabled.")
        }

        let allContainers = containerRecords + machineContainers + builderContainers
        var candidates: [CleanupCandidate] = []
        if failures[.containers] == nil {
            for record in containerRecords where record.state == "stopped" && !record.pluginManaged && !builderIDs.contains(record.id) && !machineContainers.contains(where: { $0.id == record.id }) {
                candidates.append(.init(category: .containers, resourceID: record.id, title: record.id, reason: "Stopped container", identity: .container(id: record.id, creationDate: record.creationDate, state: record.state, image: record.image, imageDigest: record.imageDigest, volumes: record.volumes.sorted(), networks: record.networks.sorted())))
            }
        }

        if failures[.images] == nil, case .success(let json) = imagesRead, let rows = Self.array(json) {
            do {
                let images = try rows.map(Self.decodeImage)
                let referencedImageNames = machineImages.union(builderImages)
                let usedDigests = Set(
                    allContainers.flatMap { [Self.normalizeDigest($0.imageDigest), Self.imageReferenceDigest($0.image)] }.compactMap { $0 }
                        + machineImageDigests.union(builderImageDigests).compactMap(Self.normalizeDigest)
                        + referencedImageNames.compactMap(Self.imageReferenceDigest)
                )
                let usedAliases = Set(allContainers.flatMap { imageAliases($0.image) } + machineImages.union(builderImages).flatMap(imageAliases))
                for image in images {
                    let isUsed = image.digests.contains(where: usedDigests.contains)
                        || image.aliases.contains(where: usedAliases.contains)
                    let isInfrastructure = !Self.repositoryAliases(image.reference).isDisjoint(with: infrastructureRepositories)
                    guard !isUsed && !isInfrastructure else { continue }
                    candidates.append(.init(category: .images, resourceID: image.reference, title: image.reference, reason: "Image is not referenced by any container", sizeBytes: image.sizeBytes, identity: .image(digest: image.digest, reference: image.reference, aliases: image.aliases.sorted(), sizeBytes: image.sizeBytes)))
                }
            } catch {
                failures[.images] = "Image inventory was incomplete or malformed."
                warnings.append("Image dependency inventory was incomplete; image cleanup is disabled.")
            }
        } else if failures[.images] == nil {
            failures[.images] = "Image inventory was incomplete or malformed."
        }

        if failures[.networks] == nil, case .success(let json) = networksRead, let rows = Self.array(json) {
            do {
                let networks = try rows.map(Self.decodeNetwork)
                let referenced = Set(allContainers.flatMap(\.networks))
                for network in networks where !network.builtin && !referenced.contains(network.name) {
                    candidates.append(.init(category: .networks, resourceID: network.name, title: network.name, reason: "Network is not referenced by any container", identity: .network(name: network.name, builtin: false, identityToken: network.identityToken)))
                }
            } catch {
                failures[.networks] = "Network inventory was incomplete or malformed."
                warnings.append("Network dependency inventory was incomplete; network cleanup is disabled.")
            }
        } else if failures[.networks] == nil {
            failures[.networks] = "Network inventory was incomplete or malformed."
            warnings.append("Network dependency inventory was incomplete; network cleanup is disabled.")
        }

        if failures[.volumes] == nil, case .success(let json) = volumesRead, let rows = Self.array(json) {
            do {
                let volumes = try rows.map(Self.decodeVolume)
                let referenced = Set(allContainers.flatMap(\.volumes))
                for volume in volumes where !referenced.contains(volume.name) {
                    candidates.append(.init(category: .volumes, resourceID: volume.name, title: volume.name, reason: "Volume is not referenced by any container", identity: .volume(name: volume.name, identityToken: volume.identityToken, sizeBytes: volume.sizeBytes)))
                }
            } catch {
                failures[.volumes] = "Volume inventory was incomplete or malformed."
                warnings.append("Volume dependency inventory was incomplete; volume cleanup is disabled.")
            }
        } else if failures[.volumes] == nil {
            failures[.volumes] = "Volume inventory was incomplete or malformed."
            warnings.append("Volume dependency inventory was incomplete; volume cleanup is disabled.")
        }

        if !builderVerified, failures[.containers] == nil {
            failures[.containers] = "Builder status could not be verified."
            warnings.append("Builder status unavailable; container cleanup is disabled.")
        }
        if failures[.containers] != nil {
            for category in [CleanupCategory.images, .networks, .volumes] where failures[category] == nil {
                failures[category] = "Container dependency inventory could not be verified."
            }
        }
        candidates.removeAll { failures[$0.category] != nil }
        let diskUsage: SystemDiskUsage?
        if case .success(let json) = diskRead { diskUsage = Self.decodeDiskUsage(json) }
        else { diskUsage = nil }

        return CleanupScan(candidates: candidates.sorted { ($0.category.rawValue, $0.title) < ($1.category.rawValue, $1.title) }, warnings: warnings, categoryFailures: failures, diskUsage: diskUsage)
    }

    public func revalidate(_ candidate: CleanupCandidate) async -> CleanupEligibility {
        let current = await scan()
        if let failure = current.categoryFailures[candidate.category] {
            return CleanupEligibility(eligible: false, reason: failure)
        }
        guard let found = current.candidates.first(where: { $0.id == candidate.id }) else {
            return CleanupEligibility(eligible: false, reason: "The resource is no longer eligible; refresh the review.")
        }
        guard found.identity == candidate.identity, found.resourceID == candidate.resourceID else {
            return CleanupEligibility(eligible: false, reason: "The resource or its dependencies changed; refresh the review.")
        }
        return CleanupEligibility(eligible: true, reason: "Resource is still eligible.")
    }

    /// Confirms an exact target disappeared after a delete request. A failed or
    /// incomplete read is never treated as success.
    public func verifyRemoval(_ candidate: CleanupCandidate) async -> CleanupRemovalVerification {
        let args: [String]
        let label: String
        switch candidate.category {
        case .containers: args = ["list", "--all", "--format", "json"]; label = "container inventory"
        case .images: args = ["image", "list", "--format", "json", "--verbose"]; label = "image inventory"
        case .networks: args = ["network", "list", "--format", "json"]; label = "network inventory"
        case .volumes: args = ["volume", "list", "--format", "json"]; label = "volume inventory"
        }
        let read = await readJSON(args, label: label)
        guard case .success(let json) = read, let rows = Self.array(json) else {
            return .unverified("Could not verify whether the reviewed resource was removed.")
        }
        do {
            let present: Bool
            switch candidate.category {
            case .containers:
                present = try rows.map(Self.decodeContainer).contains { $0.id == candidate.resourceID }
            case .images:
                present = try rows.map(Self.decodeImage).contains { $0.reference == candidate.resourceID }
            case .networks:
                present = try rows.map(Self.decodeNetwork).contains { $0.name == candidate.resourceID }
            case .volumes:
                present = try rows.map(Self.decodeVolume).contains { $0.name == candidate.resourceID }
            }
            return present
                ? .stillPresent("The reviewed resource is still present.")
                : .removed
        } catch {
            return .unverified("The resource inventory was malformed, so removal could not be confirmed.")
        }
    }

    public func command(for candidate: CleanupCandidate) throws -> CommandRequest {
        guard !candidate.resourceID.isEmpty, !candidate.resourceID.contains("\0") else {
            throw CleanupCommandError.invalidTarget
        }
        let identityMatches: Bool
        switch (candidate.category, candidate.identity) {
        case (.containers, .container(let id, _, _, _, _, _, _)): identityMatches = id == candidate.resourceID
        case (.images, .image(_, let reference, _, _)): identityMatches = reference == candidate.resourceID
        case (.networks, .network(let name, let builtin, _)): identityMatches = name == candidate.resourceID && !builtin
        case (.volumes, .volume(let name, _, _)): identityMatches = name == candidate.resourceID
        default: identityMatches = false
        }
        guard identityMatches else { throw CleanupCommandError.invalidTarget }
        let args: [String]
        switch candidate.category {
        case .containers: args = ["delete", "--", candidate.resourceID]
        case .images: args = ["image", "delete", "--", candidate.resourceID]
        case .networks: args = ["network", "delete", "--", candidate.resourceID]
        case .volumes: args = ["volume", "delete", "--", candidate.resourceID]
        }
        return CommandRequest(arguments: args, suppressOutputEvents: true)
    }

    private func readJSON(_ args: [String], label: String) async -> ReadResult {
        do {
            let result = try await client.run(CommandRequest(arguments: args, captureLimit: 1_000_000, suppressOutputEvents: true, timeout: .seconds(15)))
            guard result.succeeded, !result.timedOut, !result.outputTruncated else { return .failure("\(label.capitalized) command failed or returned incomplete output.") }
            guard let data = result.standardOutput.data(using: .utf8), !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return .failure("\(label.capitalized) returned malformed structured output.")
            }
            return .success(json)
        } catch {
            return .failure("\(label.capitalized) could not be read.")
        }
    }

    private enum ReadResult {
        case success(Any)
        case failure(String)
    }

    private struct ContainerRecord {
        let id: String
        let creationDate: String
        let state: String
        let image: String
        let imageDigest: String
        let volumes: Set<String>
        let networks: Set<String>
        let pluginManaged: Bool
    }
    private struct ImageRecord {
        let reference: String
        let digest: String
        let digests: Set<String>
        let aliases: Set<String>
        let sizeBytes: Int64?
    }
    private struct NetworkRecord { let name: String; let builtin: Bool; let identityToken: String }
    private struct VolumeRecord { let name: String; let identityToken: String; let sizeBytes: Int64? }

    private static func array(_ value: Any) -> [[String: Any]]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap { $0 as? [String: Any] }.count == values.count ? values as? [[String: Any]] : nil
    }
    private static func string(_ value: Any?) -> String? { value as? String }
    private static func resourceID(_ value: Any) -> String? {
        guard let row = value as? [String: Any] else { return nil }
        if let id = string(row["id"]) { return id }
        if let configuration = row["configuration"] as? [String: Any] { return string(configuration["id"]) }
        return nil
    }
    private static func decodeContainer(_ row: [String: Any]) throws -> ContainerRecord {
        guard let id = resourceID(row), let configuration = row["configuration"] as? [String: Any],
              let creationDate = string(configuration["creationDate"]), !creationDate.isEmpty,
              let status = row["status"] as? [String: Any], let state = string(status["state"]),
              let imageObject = configuration["image"] as? [String: Any], let image = string(imageObject["reference"]),
              let imageDescriptor = imageObject["descriptor"] as? [String: Any], let imageDigest = string(imageDescriptor["digest"]), normalizeDigest(imageDigest) != nil,
              let mountValues = configuration["mounts"] as? [Any], let networkValues = configuration["networks"] as? [Any] else { throw DecodeFailure.malformed }
        var volumes = Set<String>()
        for mountValue in mountValues {
            guard let mount = mountValue as? [String: Any], let type = mount["type"] as? [String: Any] else { throw DecodeFailure.malformed }
            if let volume = type["volume"] as? [String: Any] {
                guard let name = string(volume["name"]), !name.isEmpty else { throw DecodeFailure.malformed }
                volumes.insert(name)
            }
        }
        var networks = Set<String>()
        for networkValue in networkValues {
            guard let network = networkValue as? [String: Any], let name = string(network["network"]) else { throw DecodeFailure.malformed }
            networks.insert(name)
        }
        return ContainerRecord(id: id, creationDate: creationDate, state: state.lowercased(), image: image, imageDigest: imageDigest, volumes: volumes, networks: networks, pluginManaged: isPluginManagedOrUnknown(configuration["labels"]))
    }

    /// Plugin-owned containers require their plugin's teardown workflow. Treat
    /// malformed labels as protected, while absent or JSON-null labels remain
    /// legacy-empty as in ContainerConfiguration's decoder.
    private static func isPluginManagedOrUnknown(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        guard let labels = value as? [String: Any], labels.values.allSatisfy({ $0 is String }) else { return true }
        guard let owner = labels["com.apple.container.plugin"] as? String else { return false }
        return !owner.isEmpty
    }
    private static func decodeImage(_ row: [String: Any]) throws -> ImageRecord {
        guard let config = row["configuration"] as? [String: Any],
              let reference = string(config["name"]), let descriptor = config["descriptor"] as? [String: Any],
              let digest = string(descriptor["digest"]), normalizeDigest(digest) != nil,
              let variants = row["variants"] as? [Any] else { throw DecodeFailure.malformed }
        var digests = Set([normalizeDigest(digest)].compactMap { $0 })
        var total: Int64 = 0
        var hasSize = false
        for item in variants {
            guard let variant = item as? [String: Any], let variantDigest = string(variant["digest"]), let normalized = normalizeDigest(variantDigest), let size = number(variant["size"]) else { throw DecodeFailure.malformed }
            digests.insert(normalized)
            total = total.addingReportingOverflow(size).overflow ? total : total + size
            hasSize = true
        }
        var aliases = imageAliases(reference)
        aliases.insert(reference)
        return ImageRecord(reference: reference, digest: digest, digests: digests, aliases: aliases, sizeBytes: hasSize ? total : nil)
    }
    private static func decodeNetwork(_ row: [String: Any]) throws -> NetworkRecord {
        guard let config = row["configuration"] as? [String: Any], let name = string(config["name"]),
              let labels = config["labels"] as? [String: Any] else { throw DecodeFailure.malformed }
        let builtin = string(labels["com.apple.container.resource.role"]) == "builtin"
        guard let creationDate = string(config["creationDate"]), !creationDate.isEmpty else { throw DecodeFailure.malformed }
        let token = [creationDate, string(config["plugin"]) ?? "", string(config["mode"]) ?? ""].joined(separator: "|")
        return NetworkRecord(name: name, builtin: builtin, identityToken: token)
    }
    private static func decodeVolume(_ row: [String: Any]) throws -> VolumeRecord {
        guard let config = row["configuration"] as? [String: Any], let name = string(config["name"]) else { throw DecodeFailure.malformed }
        guard let creationDate = string(config["creationDate"]), !creationDate.isEmpty else { throw DecodeFailure.malformed }
        let token = [creationDate, string(config["driver"]) ?? "", string(config["format"]) ?? ""].joined(separator: "|")
        return VolumeRecord(name: name, identityToken: token, sizeBytes: number(config["sizeInBytes"]))
    }
    private static func decodeDiskUsage(_ value: Any) -> SystemDiskUsage? {
        guard let object = value as? [String: Any],
              let images = usage(object["images"]), let containers = usage(object["containers"]), let volumes = usage(object["volumes"]) else { return nil }
        let total = [images.sizeInBytes, containers.sizeInBytes, volumes.sizeInBytes].compactMap { $0 }.reduce(Int64(0), +)
        return SystemDiskUsage(images: images, containers: containers, volumes: volumes, total: total)
    }
    private static func usage(_ value: Any?) -> CleanupResourceUsage? {
        guard let object = value as? [String: Any], let total = number(object["total"]), let active = number(object["active"]),
              let size = number(object["sizeInBytes"]), let reclaimable = number(object["reclaimable"]) else { return nil }
        return CleanupResourceUsage(total: total, active: active, sizeInBytes: size, reclaimable: reclaimable)
    }
    private static func number(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
    private static func normalizeDigest(_ value: String) -> String? {
        let text = value.lowercased()
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let algorithm = text[..<colon]
        let hex = text[text.index(after: colon)...]
        guard !algorithm.isEmpty, hex.count >= 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "\(algorithm):\(hex)"
    }
    /// Extracts a digest from a direct digest reference or an OCI name@digest reference.
    private static func imageReferenceDigest(_ reference: String) -> String? {
        let digestText: String
        if let separator = reference.lastIndex(of: "@") {
            digestText = String(reference[reference.index(after: separator)...])
        } else {
            digestText = reference
        }
        return normalizeDigest(digestText)
    }
    private func normalizeDigest(_ value: String) -> String? { Self.normalizeDigest(value) }
    private func imageAliases(_ reference: String) -> Set<String> { Self.imageAliases(reference) }
    private static func imageAliases(_ reference: String) -> Set<String> {
        var aliases = Set([reference.lowercased()])
        let withoutDigest = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        let lastSlash = withoutDigest.lastIndex(of: "/")
        let lastColon = withoutDigest.lastIndex(of: ":")
        let hasTag = lastColon != nil && (lastSlash == nil || lastColon! > lastSlash!)
        let name = hasTag ? String(withoutDigest[..<lastColon!]) : withoutDigest
        let tag = hasTag ? String(withoutDigest[lastColon!...]) : ""
        aliases.insert((name + tag).lowercased())
        if name.hasPrefix("docker.io/library/") {
            aliases.insert(String(name.dropFirst("docker.io/library/".count)).lowercased() + tag.lowercased())
        } else if !name.contains("/") || name.split(separator: "/").count == 1 {
            aliases.insert(("docker.io/library/" + name + tag).lowercased())
        } else if name.hasPrefix("docker.io/") {
            aliases.insert(String(name.dropFirst("docker.io/".count)).lowercased() + tag.lowercased())
        }
        return aliases
    }
    private static let knownInfrastructureRepositories: Set<String> = [
        "ghcr.io/apple/container-builder-shim/builder",
        "ghcr.io/apple/containerization/vminit",
        "vminit",
        "docker.io/library/vminit",
    ]
    /// Returns normalized repository names, stripping only an OCI tag or digest
    /// at its grammar-defined delimiter rather than matching substrings.
    private static func repositoryAliases(_ reference: String) -> Set<String> {
        let withoutDigest = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        let lastSlash = withoutDigest.lastIndex(of: "/")
        let lastColon = withoutDigest.lastIndex(of: ":")
        let hasTag = lastColon != nil && (lastSlash == nil || lastColon! > lastSlash!)
        let repository = (hasTag ? String(withoutDigest[..<lastColon!]) : withoutDigest).lowercased()
        var aliases: Set<String> = [repository]
        if repository.hasPrefix("docker.io/library/") {
            aliases.insert(String(repository.dropFirst("docker.io/library/".count)))
        } else if !repository.contains("/") {
            aliases.insert("docker.io/library/\(repository)")
        } else if repository.hasPrefix("docker.io/") {
            aliases.insert(String(repository.dropFirst("docker.io/".count)))
        }
        return aliases
    }
    private enum DecodeFailure: Error { case malformed }
}

public enum CleanupCommandError: Error, LocalizedError, Sendable {
    case invalidTarget
    public var errorDescription: String? { "The cleanup target no longer matches its reviewed identity." }
}
