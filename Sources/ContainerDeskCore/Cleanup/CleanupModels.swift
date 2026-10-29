import Foundation

public enum CleanupCategory: String, CaseIterable, Sendable, Hashable {
    case containers
    case images
    case networks
    case volumes

    public var title: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .networks: "Networks"
        case .volumes: "Volumes"
        }
    }

    public var symbol: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "cube"
        case .networks: "point.3.connected.trianglepath.dotted"
        case .volumes: "externaldrive"
        }
    }
}

/// An allowlisted snapshot of the identity and references that made a resource eligible.
/// It intentionally contains no environment, process arguments, labels, or credentials.
public enum CleanupIdentity: Sendable, Equatable {
    case container(id: String, creationDate: String, state: String, image: String, imageDigest: String, volumes: [String], networks: [String])
    case image(digest: String, reference: String, aliases: [String], sizeBytes: Int64?)
    case network(name: String, builtin: Bool, identityToken: String)
    case volume(name: String, identityToken: String, sizeBytes: Int64?)
}

public struct CleanupCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    public let category: CleanupCategory
    /// Exact CLI operand. Never shortened, normalized, or interpreted as an option.
    public let resourceID: String
    public let title: String
    public let reason: String
    public let sizeBytes: Int64?
    public let identity: CleanupIdentity

    public init(category: CleanupCategory, resourceID: String, title: String, reason: String, sizeBytes: Int64? = nil, identity: CleanupIdentity) {
        self.id = "\(category.rawValue):\(resourceID)"
        self.category = category
        self.resourceID = resourceID
        self.title = title
        self.reason = reason
        self.sizeBytes = sizeBytes
        self.identity = identity
    }
}

public struct CleanupResourceUsage: Codable, Sendable, Equatable {
    public let total: Int64?
    public let active: Int64?
    public let sizeInBytes: Int64?
    public let reclaimable: Int64?

    public init(total: Int64? = nil, active: Int64? = nil, sizeInBytes: Int64? = nil, reclaimable: Int64? = nil) {
        self.total = total
        self.active = active
        self.sizeInBytes = sizeInBytes
        self.reclaimable = reclaimable
    }
}

public struct SystemDiskUsage: Codable, Sendable, Equatable {
    public let images: CleanupResourceUsage
    public let containers: CleanupResourceUsage
    public let volumes: CleanupResourceUsage
    public let total: Int64?

    public init(images: CleanupResourceUsage = .init(), containers: CleanupResourceUsage = .init(), volumes: CleanupResourceUsage = .init(), total: Int64? = nil) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.total = total
    }

    private enum CodingKeys: String, CodingKey { case images, containers, volumes, total }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        images = try values.decode(CleanupResourceUsage.self, forKey: .images)
        containers = try values.decode(CleanupResourceUsage.self, forKey: .containers)
        volumes = try values.decode(CleanupResourceUsage.self, forKey: .volumes)
        let decodedTotal = try values.decodeIfPresent(Int64.self, forKey: .total)
        total = decodedTotal ?? [images.sizeInBytes, containers.sizeInBytes, volumes.sizeInBytes].compactMap { $0 }.reduce(Int64(0), +)
    }
}

public struct CleanupScan: Sendable, Equatable {
    public let candidates: [CleanupCandidate]
    public let warnings: [String]
    public let categoryFailures: [CleanupCategory: String]
    public let diskUsage: SystemDiskUsage?
    public let scannedAt: Date

    public init(candidates: [CleanupCandidate], warnings: [String], categoryFailures: [CleanupCategory: String], diskUsage: SystemDiskUsage?, scannedAt: Date = Date()) {
        self.candidates = candidates
        self.warnings = warnings
        self.categoryFailures = categoryFailures
        self.diskUsage = diskUsage
        self.scannedAt = scannedAt
    }
}

public struct CleanupEligibility: Sendable, Equatable {
    public let eligible: Bool
    public let reason: String

    public init(eligible: Bool, reason: String) {
        self.eligible = eligible
        self.reason = reason
    }
}

public enum CleanupRemovalVerification: Sendable, Equatable {
    case removed
    case stillPresent(String)
    case unverified(String)
}
