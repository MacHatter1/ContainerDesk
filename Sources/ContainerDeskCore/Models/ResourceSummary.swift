import Foundation

public struct ResourceSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let state: String?
    public let details: ResourceDetails

    public init(id: String, title: String, subtitle: String? = nil, state: String? = nil, details: ResourceDetails = .init()) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.details = details
    }
}

/// Allowlisted, non-secret fields suitable for tables and detail panes. Raw CLI JSON is never retained.
public struct ResourceDetails: Sendable, Equatable {
    public let imageReference: String?
    public let imageRepository: String?
    public let imageTag: String?
    public let platform: String?
    public let sizeBytes: Int64?
    public let digest: String?
    public let publishedPorts: [PublishedPort]
    public let driver: String?
    public let ipv4Subnet: String?
    public let isInternal: Bool?
    public let labels: [String: String]
    public let cpuCount: Int?
    public let cpuAllocation: Int?
    public let memoryLimitBytes: Int64?
    public let memoryBytes: Int64?
    public let isDefault: Bool?
    public let registryUsername: String?

    public init(
        imageReference: String? = nil,
        imageRepository: String? = nil,
        imageTag: String? = nil,
        platform: String? = nil,
        sizeBytes: Int64? = nil,
        digest: String? = nil,
        publishedPorts: [PublishedPort] = [],
        driver: String? = nil,
        ipv4Subnet: String? = nil,
        isInternal: Bool? = nil,
        labels: [String: String] = [:],
        cpuCount: Int? = nil,
        cpuAllocation: Int? = nil,
        memoryLimitBytes: Int64? = nil,
        memoryBytes: Int64? = nil,
        isDefault: Bool? = nil,
        registryUsername: String? = nil
    ) {
        self.imageReference = imageReference
        self.imageRepository = imageRepository
        self.imageTag = imageTag
        self.platform = platform
        self.sizeBytes = sizeBytes
        self.digest = digest
        self.publishedPorts = publishedPorts
        self.driver = driver
        self.ipv4Subnet = ipv4Subnet
        self.isInternal = isInternal
        self.labels = labels
        self.cpuCount = cpuCount
        self.cpuAllocation = cpuAllocation
        self.memoryLimitBytes = memoryLimitBytes
        self.memoryBytes = memoryBytes
        self.isDefault = isDefault
        self.registryUsername = registryUsername
    }
}

public struct PublishedPort: Identifiable, Sendable, Equatable {
    public let hostAddress: String?
    public let hostPort: Int?
    public let containerPort: Int
    public let proto: String?
    public let count: Int?

    public var id: String { "\(hostAddress ?? ""):\(hostPort.map(String.init) ?? "")-\(containerPort)-\(proto ?? "")-\(count ?? 1)" }

    public init(hostAddress: String? = nil, hostPort: Int? = nil, containerPort: Int, proto: String? = nil, count: Int? = nil) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.count = count
    }
}

public struct ContainerMetric: Sendable, Equatable {
    public let cpuPercent: Double?
    public let memoryUsageBytes: Int64?

    public init(cpuPercent: Double? = nil, memoryUsageBytes: Int64? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryUsageBytes = memoryUsageBytes
    }
}

public enum ResourceLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

public enum CLIFeatureAvailability: Sendable, Equatable {
    case unknown
    case available
    case unavailable(String)
}

public struct ResourceSnapshot: Sendable, Equatable {
    public var items: [ResourceSummary]
    public var fetchedAt: Date?
    public var state: ResourceLoadState

    public init(items: [ResourceSummary] = [], fetchedAt: Date? = nil, state: ResourceLoadState = .idle) {
        self.items = items
        self.fetchedAt = fetchedAt
        self.state = state
    }
}

public enum OperationState: String, Sendable, Equatable {
    case running
    case succeeded
    case failed
    case cancelled
}

public struct OperationRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let commandPreview: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: OperationState
    public var exitCode: Int32?
    public var error: String?
    public var canRetry: Bool
    public var canCancel: Bool

    public init(id: UUID = UUID(), title: String, commandPreview: String, startedAt: Date = .now, finishedAt: Date? = nil, state: OperationState = .running, exitCode: Int32? = nil, error: String? = nil, canRetry: Bool = false, canCancel: Bool = true) {
        self.id = id
        self.title = title
        self.commandPreview = commandPreview
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.exitCode = exitCode
        self.error = error
        self.canRetry = canRetry
        self.canCancel = canCancel
    }
}
