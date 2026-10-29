import Foundation
import CoreFoundation

/// Extracts a deliberately small, non-sensitive summary from CLI JSON. Never returns or stores raw payloads.
public enum ResourceJSONDecoder {
    public enum DecodeError: Error, LocalizedError {
        case unexpectedShape
        public var errorDescription: String? { "The container CLI returned an unexpected JSON shape." }
    }

    public static func summaries(from data: Data, section: ContainerSection? = nil) throws -> [ResourceSummary] {
        let root = try JSONSerialization.jsonObject(with: data)
        let candidates: [[String: Any]]
        if let array = root as? [[String: Any]] { candidates = array }
        else if let dict = root as? [String: Any], let array = ["items", "containers", "images", "networks", "volumes", "machines", "results"].lazy.compactMap({ dict[$0] as? [[String: Any]] }).first { candidates = array }
        else { throw DecodeError.unexpectedShape }
        var summaries: [ResourceSummary] = []
        for object in candidates {
            guard let id = firstString(in: object, keys: ["id", "ID", "name", "Name", "cluster", "clusterName"]) ?? nestedString(in: object, paths: [["configuration", "id"], ["configuration", "name"], ["configuration", "reference"], ["configuration", "clusterName"]]) else { throw DecodeError.unexpectedShape }
            let config = object["configuration"] as? [String: Any] ?? [:]
            let displayName = firstString(in: object, keys: ["name", "Name", "reference", "clusterName"]) ?? nestedString(in: object, paths: [["configuration", "name"], ["configuration", "reference"], ["configuration", "clusterName"], ["configuration", "id"]])
            let image = nestedString(in: object, paths: [["configuration", "image", "reference"]]) ?? firstString(in: object, keys: ["image", "imageName"])
            let title: String
            let subtitle: String?
            let details: ResourceDetails
            var summaryID = id
            switch section {
            case .containers:
                title = displayName ?? id
                subtitle = displayName == nil ? nil : shortID(id, excluding: displayName)
                let resources = config["resources"] as? [String: Any] ?? [:]
                details = ResourceDetails(
                    imageReference: image,
                    publishedPorts: try ports(config["publishedPorts"]),
                    labels: safeLabels(config["labels"]),
                    cpuAllocation: int(resources["cpus"]),
                    memoryLimitBytes: int64(resources["memoryInBytes"])
                )
            case .images:
                let reference = nestedString(in: object, paths: [["configuration", "name"]]) ?? displayName ?? id
                let (repository, tag, referenceDigest) = splitImageReference(reference)
                summaryID = reference
                title = repository
                subtitle = nestedString(in: object, paths: [["configuration", "creationDate"]])
                let variants = try imageVariants(config: config, object: object)
                details = ResourceDetails(
                    imageReference: reference,
                    imageRepository: repository,
                    imageTag: tag,
                    platform: variants.platform,
                    sizeBytes: variants.sizeBytes,
                    digest: variants.digest ?? referenceDigest
                )
            case .volumes:
                title = displayName ?? id
                subtitle = displayName == nil ? nil : shortID(id, excluding: displayName)
                details = ResourceDetails(
                    sizeBytes: nestedInt64(in: object, paths: [["configuration", "sizeInBytes"]]),
                    driver: nestedString(in: object, paths: [["configuration", "driver"]]),
                    labels: safeLabels(config["labels"])
                )
            case .networks:
                title = displayName ?? id
                subtitle = displayName == nil ? nil : shortID(id, excluding: displayName)
                let options = config["options"] as? [String: Any] ?? [:]
                details = ResourceDetails(
                    driver: nestedString(in: object, paths: [["configuration", "plugin"]]),
                    ipv4Subnet: nestedString(in: object, paths: [["status", "ipv4Subnet"]]),
                    isInternal: bool(options["internal"]) ?? bool(config["internal"]),
                    labels: safeLabels(config["labels"])
                )
            case .machines:
                title = displayName ?? id
                subtitle = displayName == nil ? nil : shortID(id, excluding: displayName)
                let resources = config["resources"] as? [String: Any] ?? [:]
                details = ResourceDetails(
                    cpuCount: int(resources["cpus"]) ?? int(config["cpus"]),
                    memoryBytes: int64(resources["memoryInBytes"]) ?? int64(config["memoryInBytes"]),
                    isDefault: bool(object["isDefault"]) ?? bool(object["default"]) ?? bool(config["isDefault"])
                )
            case .registries:
                title = displayName ?? id
                subtitle = nil
                details = ResourceDetails(registryUsername: firstString(in: object, keys: ["username", "user"]) ?? nestedString(in: object, paths: [["configuration", "username"], ["configuration", "user"]]))
            default:
                title = displayName ?? image ?? id
                subtitle = nil
                details = .init()
            }
            let state = firstString(in: object, keys: ["state", "State", "status", "Status"]) ?? nestedString(in: object, paths: [["status", "state"], ["status", "status"], ["state", "status"]])
            summaries.append(ResourceSummary(id: summaryID, title: title, subtitle: subtitle, state: state, details: details))
        }
        return summaries
    }

    private static func shortID(_ id: String, excluding displayName: String?) -> String? {
        guard id != displayName, id.count > 12 else { return nil }
        return String(id.prefix(12))
    }

    private static func splitImageReference(_ reference: String) -> (repository: String, tag: String?, digest: String?) {
        if let separator = reference.lastIndex(of: "@") {
            return (String(reference[..<separator]), nil, String(reference[reference.index(after: separator)...]))
        }
        guard let colon = reference.lastIndex(of: ":"),
              !reference[colon...].contains("/") else { return (reference, nil, nil) }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]), nil)
    }

    private static func imageVariants(config: [String: Any], object: [String: Any]) throws -> (platform: String?, sizeBytes: Int64?, digest: String?) {
        let variantValues = (object["variants"] as? [Any]) ?? (config["variants"] as? [Any]) ?? []
        guard !variantValues.isEmpty else {
            return (nestedString(in: object, paths: [["configuration", "descriptor", "platform"]]), nil, nil)
        }
        let variants = try variantValues.map { value -> [String: Any] in
            guard let variant = value as? [String: Any] else { throw DecodeError.unexpectedShape }
            return variant
        }
        let concrete = variants.filter { parsedPlatform($0["platform"]).name != nil }
        let selected = concrete.first { parsedPlatform($0["platform"]).architecture == "arm64" }
            ?? (concrete.count == 1 ? concrete.first : nil)
        return (
            selected.flatMap { parsedPlatform($0["platform"]).name },
            selected.flatMap { int64($0["size"]) },
            selected.flatMap { firstString(in: $0, keys: ["digest"]) }
        )
    }

    private static func parsedPlatform(_ value: Any?) -> (name: String?, architecture: String?) {
        if let text = value as? String {
            let parts = text.split(separator: "/").map(String.init)
            guard parts.count >= 2, !parts.contains(where: { $0.localizedCaseInsensitiveCompare("unknown") == .orderedSame }) else { return (nil, nil) }
            return (text, parts[1])
        }
        guard let value = value as? [String: Any],
              let os = firstString(in: value, keys: ["os"]),
              let architecture = firstString(in: value, keys: ["architecture", "arch"]),
              os.localizedCaseInsensitiveCompare("unknown") != .orderedSame,
              architecture.localizedCaseInsensitiveCompare("unknown") != .orderedSame else { return (nil, nil) }
        let variant = firstString(in: value, keys: ["variant"])
        return ([os, architecture, variant].compactMap { $0 }.joined(separator: "/"), architecture)
    }

    private static func ports(_ value: Any?) throws -> [PublishedPort] {
        guard let value else { return [] }
        guard let array = value as? [Any] else { throw DecodeError.unexpectedShape }
        return try array.map { item in
            guard let entry = item as? [String: Any], let containerPort = int(entry["containerPort"]) else { throw DecodeError.unexpectedShape }
            return PublishedPort(
                hostAddress: firstString(in: entry, keys: ["hostAddress"]),
                hostPort: int(entry["hostPort"]),
                containerPort: containerPort,
                proto: firstString(in: entry, keys: ["proto"]),
                count: int(entry["count"])
            )
        }
    }

    private static func safeLabels(_ value: Any?) -> [String: String] {
        guard let labels = value as? [String: Any] else { return [:] }
        let sensitive = ["password", "passwd", "token", "secret", "authorization", "credential", "api_key", "access_key", "private_key"]
        return labels.reduce(into: [:]) { result, pair in
            let lower = pair.key.lowercased()
            guard !sensitive.contains(where: lower.contains), let labelValue = pair.value as? String else { return }
            let sanitized = CommandRequest(arguments: []).sanitizeOutput(labelValue)
            if !sanitized.isEmpty { result[pair.key] = sanitized }
        }
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = object[key] as? String, !string.isEmpty { return string }
            if let number = object[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func nestedString(in object: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var value: Any? = object
            for key in path { value = (value as? [String: Any])?[key] }
            if let string = value as? String, !string.isEmpty { return string }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func nestedInt64(in object: [String: Any], paths: [[String]]) -> Int64? {
        for path in paths {
            var value: Any? = object
            for key in path { value = (value as? [String: Any])?[key] }
            if let parsed = int64(value) { return parsed }
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
