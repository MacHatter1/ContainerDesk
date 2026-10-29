import Foundation

/// Whether the MLX command-line runtime can be used by this app instance.
public struct MLXCapability: Sendable, Equatable {
    public let available: Bool
    public let mlxLMVersion: String?
    public let executableURL: URL?
    public let pythonURL: URL?
    public let reason: String?

    public init(available: Bool, mlxLMVersion: String? = nil, executableURL: URL? = nil, pythonURL: URL? = nil, reason: String? = nil) {
        self.available = available
        self.mlxLMVersion = mlxLMVersion
        self.executableURL = executableURL
        self.pythonURL = pythonURL
        self.reason = reason
    }
}

/// User-configurable tool and local model locations. The UI persists this value; Core does not.
public struct MLXConfiguration: Sendable, Equatable {
    public var executableOverride: URL?
    public var managedModelsDirectory: URL
    public var importedModelDirectories: [URL]

    public init(executableOverride: URL? = nil, managedModelsDirectory: URL = MLXConfiguration.defaultManagedModelsDirectory, importedModelDirectories: [URL] = []) {
        self.executableOverride = executableOverride
        self.managedModelsDirectory = managedModelsDirectory.standardizedFileURL
        self.importedModelDirectories = importedModelDirectories.map(\.standardizedFileURL)
    }

    public static var defaultManagedModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ContainerDesk/Models", isDirectory: true)
    }
}

public enum MLXModelSource: String, Sendable, Equatable {
    case huggingFaceCache
    case importedDirectory
    case appManagedDownload
}

/// Curated local model metadata. `path` is used for explicit local launches and is never logged.
public struct MLXModelRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let path: URL
    public let source: MLXModelSource
    public let repositoryID: String?
    public let revision: String?
    public let modelType: String?
    public let quantizationBits: Int?
    public let parameterCount: Int64?
    public let diskBytes: Int64
    public let fileCount: Int
    public let isReady: Bool

    public init(id: String, displayName: String, path: URL, source: MLXModelSource, repositoryID: String? = nil, revision: String? = nil, modelType: String? = nil, quantizationBits: Int? = nil, parameterCount: Int64? = nil, diskBytes: Int64, fileCount: Int, isReady: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.source = source
        self.repositoryID = repositoryID
        self.revision = revision
        self.modelType = modelType
        self.quantizationBits = quantizationBits
        self.parameterCount = parameterCount
        self.diskBytes = max(0, diskBytes)
        self.fileCount = max(0, fileCount)
        self.isReady = isReady
    }
}

public struct MLXModelDownloadRequest: Sendable, Equatable {
    public let repositoryID: String

    public init(repositoryID: String) throws {
        let parts = repositoryID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              repositoryID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw MLXError.invalidRepositoryID
        }
        self.repositoryID = repositoryID
    }
}

public struct MLXServerOptions: Sendable, Equatable {
    public let port: UInt16
    public let maxTokens: Int
    public let temperature: Double

    public init(port: UInt16 = 8080, maxTokens: Int = 512, temperature: Double = 0) throws {
        guard (1024...65535).contains(Int(port)), (1...32_768).contains(maxTokens), temperature.isFinite, (0...2).contains(temperature) else {
            throw MLXError.invalidServerOptions
        }
        self.port = port
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public enum MLXServerState: String, Sendable, Equatable {
    case starting
    case running
    case stopping
    case stopped
    case failed
}

public struct MLXServerSession: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let modelID: String
    public let port: UInt16
    public let state: MLXServerState
    public let detail: String?

    public init(id: UUID, modelID: String, port: UInt16, state: MLXServerState, detail: String? = nil) {
        self.id = id
        self.modelID = modelID
        self.port = port
        self.state = state
        self.detail = detail
    }
}

public enum MLXServerEvent: Sendable, Equatable {
    case output(String)
    case state(MLXServerSession)
}

public enum MLXDownloadEvent: Sendable, Equatable {
    /// Sanitized CLI output; progress can be indeterminate and is not interpreted as a percentage.
    case output(String)
    case completed(MLXModelRecord)
}

public enum MLXChatRole: String, Sendable, Equatable, Codable {
    case system
    case user
    case assistant
}

public struct MLXChatMessage: Sendable, Equatable, Codable {
    public let role: MLXChatRole
    public let content: String

    public init(role: MLXChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct MLXChatOptions: Sendable, Equatable {
    public let maxTokens: Int
    public let temperature: Double

    public init(maxTokens: Int = 512, temperature: Double = 0) throws {
        guard (1...8_192).contains(maxTokens), temperature.isFinite, (0...2).contains(temperature) else {
            throw MLXError.invalidChatOptions
        }
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public enum MLXError: Error, LocalizedError, Sendable, Equatable {
    case invalidRepositoryID
    case invalidServerOptions
    case invalidModelDirectory
    case modelNotFound
    case toolchainUnavailable(String)
    case serverAlreadyOwnsPort(UInt16)
    case serverNotReady
    case invalidChatOptions
    case invalidChatRequest
    case chatResponseTooLarge
    case unknownServer
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryID: "Enter a Hugging Face repository ID in owner/model form."
        case .invalidServerOptions: "The local server options are outside the supported range."
        case .invalidModelDirectory: "The selected folder does not contain a complete MLX model."
        case .modelNotFound: "The selected local model is no longer available."
        case .toolchainUnavailable(let reason): reason
        case .serverAlreadyOwnsPort(let port): "A ContainerDesk MLX server already uses port \(port)."
        case .serverNotReady: "The selected ContainerDesk MLX server is not ready."
        case .invalidChatOptions: "Chat generation options are outside the supported range."
        case .invalidChatRequest: "The chat request is empty or exceeds the local request limit."
        case .chatResponseTooLarge: "The local model response exceeded the safe output limit."
        case .unknownServer: "This server is not owned by ContainerDesk."
        case .operationFailed(let message): message
        }
    }
}

public protocol MLXModelService: Sendable {
    func configure(_ configuration: MLXConfiguration) async
    func capability() async -> MLXCapability
    func listLocalModels() async throws -> [MLXModelRecord]
    func validateModelDirectory(_ url: URL) async throws -> MLXModelRecord
    func download(_ request: MLXModelDownloadRequest) async -> AsyncThrowingStream<MLXDownloadEvent, Error>
    func startServer(modelID: String, options: MLXServerOptions) async throws -> MLXServerSession
    func stopServer(id: UUID) async throws
    func serverEvents(id: UUID) async -> AsyncStream<MLXServerEvent>
    func ownedServers() async -> [MLXServerSession]
    func trashManagedModel(id: String) async throws
    func forgetImportedModel(at url: URL) async
    func chat(serverID: UUID, messages: [MLXChatMessage], options: MLXChatOptions) async -> AsyncThrowingStream<String, Error>
    func stopAllOwnedServers() async
    func shutdown() async
}
