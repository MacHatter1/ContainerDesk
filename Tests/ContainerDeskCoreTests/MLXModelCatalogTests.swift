import Foundation
import Testing
@testable import ContainerDeskCore

@Suite(.serialized)
struct MLXModelCatalogTests {
    @Test func scansCuratedHFCacheMetadataAndCustomCachePath() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("hf-hub", isDirectory: true)
        let snapshot = cache.appendingPathComponent("models--mlx-community--tiny-4bit/snapshots/revision-a", isDirectory: true)
        try makeModel(at: snapshot, config: #"{"model_type":"llama","quantization_config":{"bits":4},"token":"do-not-retain"}"#)
        let catalog = MLXModelCatalog(configuration: MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed")), environment: ["HF_HUB_CACHE": cache.path])

        let models = await catalog.listLocalModels()
        #expect(models.count == 1)
        #expect(models.first?.id == "hf:mlx-community/tiny-4bit@revision-a")
        #expect(models.first?.repositoryID == "mlx-community/tiny-4bit")
        #expect(models.first?.quantizationBits == 4)
        #expect(models.first?.modelType == "llama")
        #expect(models.first?.diskBytes ?? 0 > 0)
        #expect(models.first?.source == .huggingFaceCache)
    }

    @Test func ignoresIncompleteAndBrokenSymlinkSnapshots() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("hub", isDirectory: true)
        let incomplete = cache.appendingPathComponent("models--owner--incomplete/snapshots/r1", isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data(#"{"model_type":"test"}"#.utf8).write(to: incomplete.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: incomplete.appendingPathComponent("tokenizer.json"))
        try FileManager.default.createSymbolicLink(at: incomplete.appendingPathComponent("model.safetensors"), withDestinationURL: root.appendingPathComponent("missing-blob"))

        let indexOnly = cache.appendingPathComponent("models--owner--index-only/snapshots/r2", isDirectory: true)
        try FileManager.default.createDirectory(at: indexOnly, withIntermediateDirectories: true)
        try Data(#"{"model_type":"test"}"#.utf8).write(to: indexOnly.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: indexOnly.appendingPathComponent("tokenizer.json"))
        try Data(#"{"weight_map":{"layer.weight":"missing-00001-of-00001.safetensors"}}"#.utf8).write(to: indexOnly.appendingPathComponent("model.safetensors.index.json"))

        let models = await MLXModelCatalog(configuration: MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed")), environment: ["HF_HUB_CACHE": cache.path]).listLocalModels()
        #expect(models.isEmpty)
    }

    @Test func validatesExplicitImportAndManagedRepoPathsAreInjective() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = root.appendingPathComponent("imported", isDirectory: true)
        try makeModel(at: imported)
        let catalog = MLXModelCatalog(configuration: MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed")), environment: [:])
        let model = try await catalog.validateModelDirectory(imported)
        #expect(model.source == .importedDirectory)
        #expect(model.id.hasPrefix("import:"))

        let first = try MLXModelCatalog.managedPath(for: "a--b/c", root: root)
        let second = try MLXModelCatalog.managedPath(for: "a/b--c", root: root)
        #expect(first.path != second.path)
        #expect(throws: MLXError.invalidRepositoryID) { _ = try MLXModelDownloadRequest(repositoryID: "../escape") }
        #expect(throws: MLXError.invalidRepositoryID) { _ = try MLXModelDownloadRequest(repositoryID: "owner/model/extra") }
    }

    @Test func managedManifestIsRequiredBeforeDownloadAppearsAsOwned() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelsRoot = root.appendingPathComponent("managed", isDirectory: true)
        let destination = try MLXModelCatalog.managedPath(for: "owner/model", root: modelsRoot)
        try makeModel(at: destination)
        let catalog = MLXModelCatalog(configuration: MLXConfiguration(managedModelsDirectory: modelsRoot), environment: ["HF_HUB_CACHE": root.appendingPathComponent("empty-cache").path])
        #expect(await catalog.listLocalModels().isEmpty)

        try MLXModelCatalog.writeManagedManifest(repositoryID: "owner/model", complete: true, to: destination, root: modelsRoot)
        let models = await catalog.listLocalModels()
        #expect(models.count == 1)
        #expect(models.first?.id == "managed:owner/model")
        #expect(models.first?.source == .appManagedDownload)
    }

    private func makeModel(at directory: URL, config: String = #"{"model_type":"tiny"}"#) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data(repeating: 0x5A, count: 128).write(to: directory.appendingPathComponent("model.safetensors"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesk-mlx-catalog-\(UUID().uuidString)", isDirectory: true)
    }
}
