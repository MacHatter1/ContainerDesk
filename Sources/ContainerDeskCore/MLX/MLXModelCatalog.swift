import Foundation

/// Injectable boundary around a local catalog traversal. Kept internal so the
/// service can be exercised with a deterministic scanner in Core tests.
protocol MLXModelCatalogScanning: Sendable {
    func scan(
        configuration: MLXConfiguration,
        environment: [String: String],
        cancellation: MLXCatalogScanCancellation
    ) throws -> [MLXModelRecord]
}

/// Cancellation is explicit because catalog work runs in a detached task and
/// therefore does not inherit cancellation from the task waiting for it.
final class MLXCatalogScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func throwIfCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}

struct MLXManagedModelManifest: Codable {
    let repositoryID: String
    let formatVersion: Int
    let complete: Bool
}

/// Read-only catalog for Hugging Face Hub snapshots, explicit user imports, and app-managed models.
public struct MLXModelCatalog: Sendable {
    public let configuration: MLXConfiguration
    private let environment: [String: String]

    public init(configuration: MLXConfiguration = MLXConfiguration(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.configuration = configuration
        self.environment = environment
    }

    public func listLocalModels() async -> [MLXModelRecord] {
        let cancellation = MLXCatalogScanCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                (try? scanSynchronously(cancellation: cancellation)) ?? []
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    fileprivate func scanSynchronouslyForService(cancellation: MLXCatalogScanCancellation) throws -> [MLXModelRecord] {
        try scanSynchronously(cancellation: cancellation)
    }

    public func validateModelDirectory(_ url: URL, source: MLXModelSource = .importedDirectory, repositoryID: String? = nil, revision: String? = nil) async throws -> MLXModelRecord {
        let cancellation = MLXCatalogScanCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let root = url.standardizedFileURL
                let id: String
                switch source {
                case .appManagedDownload: id = "managed:\(repositoryID ?? root.lastPathComponent)"
                case .huggingFaceCache: id = "hf:\(repositoryID ?? root.lastPathComponent)@\(revision ?? "local")"
                case .importedDirectory: id = "import:\(root.path)"
                }
                try cancellation.throwIfCancelled()
                guard let model = try Self.record(at: root, source: source, repositoryID: repositoryID, revision: revision, id: id, cancellation: cancellation) else {
                    throw MLXError.invalidModelDirectory
                }
                return model
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func scanSynchronously(cancellation: MLXCatalogScanCancellation?) throws -> [MLXModelRecord] {
        var modelsByPath: [String: MLXModelRecord] = [:]
        let cacheRoot = Self.huggingFaceCacheRoot(environment: environment)
        for repositoryDirectory in try Self.childDirectories(of: cacheRoot, cancellation: cancellation).filter({ $0.lastPathComponent.hasPrefix("models--") }) {
            try cancellation?.throwIfCancelled()
            let repositoryID = String(repositoryDirectory.lastPathComponent.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
            let snapshots = repositoryDirectory.appendingPathComponent("snapshots", isDirectory: true)
            for snapshot in try Self.childDirectories(of: snapshots, cancellation: cancellation) {
                try cancellation?.throwIfCancelled()
                let revision = snapshot.lastPathComponent
                let id = "hf:\(repositoryID)@\(revision)"
                if let model = try Self.record(at: snapshot, source: .huggingFaceCache, repositoryID: repositoryID, revision: revision, id: id, cancellation: cancellation) {
                    modelsByPath[snapshot.standardizedFileURL.path] = model
                }
            }
        }

        for directory in try Self.childDirectories(of: configuration.managedModelsDirectory, cancellation: cancellation) {
            try cancellation?.throwIfCancelled()
            guard Self.isDirectChild(directory, of: configuration.managedModelsDirectory),
                  let manifest = Self.managedManifest(at: directory),
                  manifest.complete,
                  let expectedPath = try? Self.managedPath(for: manifest.repositoryID, root: configuration.managedModelsDirectory),
                  expectedPath.standardizedFileURL.path == directory.standardizedFileURL.path else { continue }
            let repositoryID = manifest.repositoryID
            let id = "managed:\(repositoryID)"
            if let model = try Self.record(at: directory, source: .appManagedDownload, repositoryID: repositoryID, revision: nil, id: id, cancellation: cancellation) {
                modelsByPath[directory.standardizedFileURL.path] = model
            }
        }

        for directory in configuration.importedModelDirectories {
            try cancellation?.throwIfCancelled()
            let path = directory.standardizedFileURL.path
            if modelsByPath[path] == nil,
               let model = try Self.record(at: directory, source: .importedDirectory, repositoryID: nil, revision: nil, id: "import:\(path)", cancellation: cancellation) {
                modelsByPath[path] = model
            }
        }
        try cancellation?.throwIfCancelled()
        return modelsByPath.values.sorted {
            if $0.displayName.localizedStandardCompare($1.displayName) == .orderedSame { return $0.id < $1.id }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func huggingFaceCacheRoot(environment: [String: String]) -> URL {
        if let path = environment["HF_HUB_CACHE"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        if let path = environment["HUGGINGFACE_HUB_CACHE"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        if let path = environment["HF_HOME"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("hub", isDirectory: true).standardizedFileURL }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            .standardizedFileURL
    }

    private static func childDirectories(of directory: URL, cancellation: MLXCatalogScanCancellation?) throws -> [URL] {
        try cancellation?.throwIfCancelled()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var directories: [URL] = []
        for url in urls {
            try cancellation?.throwIfCancelled()
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { directories.append(url) }
        }
        return directories
    }

    private static func record(at directory: URL, source: MLXModelSource, repositoryID: String?, revision: String?, id: String, cancellation: MLXCatalogScanCancellation?) throws -> MLXModelRecord? {
        try cancellation?.throwIfCancelled()
        let root = directory.standardizedFileURL
        guard let configData = try? Data(contentsOf: root.appendingPathComponent("config.json"), options: [.mappedIfSafe]),
              configData.count <= 512 * 1024,
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else { return nil }

        var validRelativeFiles = Set<String>()
        var bytes: Int64 = 0
        var fileCount = 0
        var visited = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let file as URL in enumerator {
            try cancellation?.throwIfCancelled()
            fileCount += 1
            // Protect the UI from corrupted or unexpectedly huge cache trees.
            guard fileCount <= 100_000 else { return nil }
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            let path = resolved.path
            guard visited.insert(path).inserted,
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let relativePath = String(file.standardizedFileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            validRelativeFiles.insert(relativePath)
            bytes += Int64(values.fileSize ?? 0)
        }
        let hasTokenizer = validRelativeFiles.contains { path in
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            return name == "tokenizer.json" || name == "tokenizer.model" || name == "tokenizer_config.json"
        }
        let indexURL = root.appendingPathComponent("model.safetensors.index.json")
        try cancellation?.throwIfCancelled()
        let hasWeights: Bool
        if FileManager.default.fileExists(atPath: indexURL.path) {
            if let indexData = try? Data(contentsOf: indexURL, options: [.mappedIfSafe]), indexData.count <= 4 * 1024 * 1024,
               let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
               let weightMap = index["weight_map"] as? [String: String], !weightMap.isEmpty {
                let shards = Set(weightMap.values)
                var allShardsPresent = true
                for shard in shards {
                    try cancellation?.throwIfCancelled()
                    guard validRelativeFiles.contains(shard), shard.lowercased().hasSuffix(".safetensors") else {
                        allShardsPresent = false
                        break
                    }
                }
                hasWeights = allShardsPresent
            } else {
                hasWeights = false
            }
        } else {
            hasWeights = validRelativeFiles.contains { URL(fileURLWithPath: $0).lastPathComponent.lowercased().hasSuffix(".safetensors") }
        }
        try cancellation?.throwIfCancelled()
        guard hasWeights, hasTokenizer else { return nil }
        let modelType = config["model_type"] as? String
        let quantizationConfiguration = config["quantization_config"] as? [String: Any]
        let quantization = config["quantization"] as? [String: Any]
        let quantizationBits = (quantizationConfiguration?["bits"] as? NSNumber)?.intValue ?? (quantization?["bits"] as? NSNumber)?.intValue
        let displayName = repositoryID ?? root.lastPathComponent
        return MLXModelRecord(
            id: id,
            displayName: displayName,
            path: root,
            source: source,
            repositoryID: repositoryID,
            revision: revision,
            modelType: modelType,
            quantizationBits: quantizationBits,
            diskBytes: bytes,
            fileCount: fileCount
        )
    }

    static func managedPath(for repositoryID: String, root: URL) throws -> URL {
        _ = try MLXModelDownloadRequest(repositoryID: repositoryID)
        let safeName = Data(repositoryID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return root.standardizedFileURL.appendingPathComponent(safeName, isDirectory: true)
    }

    static func isDirectChild(_ url: URL, of root: URL) -> Bool {
        let standardizedRoot = root.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.deletingLastPathComponent().path == standardizedRoot.path,
              standardizedURL.path != standardizedRoot.path,
              let values = try? standardizedURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return false }
        return true
    }

    static func managedManifest(at directory: URL) -> MLXManagedModelManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".containerdesk-mlx-model.json")),
              data.count <= 4_096,
              let manifest = try? JSONDecoder().decode(MLXManagedModelManifest.self, from: data),
              manifest.formatVersion == 1,
              (try? MLXModelDownloadRequest(repositoryID: manifest.repositoryID)) != nil else { return nil }
        return manifest
    }

    static func writeManagedManifest(repositoryID: String, complete: Bool, to directory: URL, root: URL) throws {
        let expected = try managedPath(for: repositoryID, root: root)
        guard expected.standardizedFileURL.path == directory.standardizedFileURL.path,
              isDirectChild(directory, of: root) else { throw MLXError.invalidModelDirectory }
        if let existing = managedManifest(at: directory), existing.repositoryID != repositoryID {
            throw MLXError.invalidModelDirectory
        }
        let manifest = MLXManagedModelManifest(repositoryID: repositoryID, formatVersion: 1, complete: complete)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent(".containerdesk-mlx-model.json"), options: .atomic)
    }
}

struct DefaultMLXModelCatalogScanner: MLXModelCatalogScanning {
    func scan(
        configuration: MLXConfiguration,
        environment: [String: String],
        cancellation: MLXCatalogScanCancellation
    ) throws -> [MLXModelRecord] {
        try cancellation.throwIfCancelled()
        return try MLXModelCatalog(configuration: configuration, environment: environment).scanSynchronouslyForService(cancellation: cancellation)
    }
}
