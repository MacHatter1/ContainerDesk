import Foundation
import Testing
@testable import ContainerDeskCore

@Suite(.serialized)
struct MLXCapabilityRefreshTests {
    @Test func explicitRecheckDetectsInstallationAndVersionChangesAtTheSamePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MLX-recheck-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mlx_lm")
        let configuration = MLXConfiguration(executableOverride: executable, managedModelsDirectory: root.appendingPathComponent("models"))
        let service = DefaultMLXModelService(configuration: configuration, environment: [:])
        #expect(await service.capability().available == false)
        try install(version: "0.32.2", at: executable)
        // This is the service boundary used by Settings' Check Again action.
        await service.configure(configuration)
        #expect(await service.capability().available)
        try install(version: "0.99.0", at: executable)
        await service.configure(configuration)
        let updated = await service.capability()
        #expect(!updated.available && updated.mlxLMVersion == "0.99.0")
        await service.shutdown()
    }

    @Test func obsoleteProbeCannotPoisonTheCacheAfterAConfigurationRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MLX-roundtrip-\(UUID())")
        let a = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("a"))
        let b = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("b"))
        let probe = RefreshHeldProbe()
        let service = DefaultMLXModelService(configuration: a, environment: [:], capabilityProbe: probe)
        let old = Task { await service.capability() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await probe.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.started)
        await service.configure(b)
        await service.configure(a)
        await probe.release()
        let staleCaller = await old.value
        let current = await service.capability()
        #expect(current.available)
        #expect(staleCaller.available, "A superseded caller should join the current probe, not return its cancelled result.")
        await service.shutdown()
    }

    private func install(version: String, at executable: URL) throws {
        try "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo mlx_lm \(version); else echo '--model --host --port --max-tokens --temp --allowed-origins'; fi\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
}

private actor RefreshHeldProbe: MLXCapabilityProbing {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func detect(configuration: MLXConfiguration, environment: [String: String]) async -> MLXCapability {
        if !started {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .init(available: !Task.isCancelled, reason: Task.isCancelled ? "Obsolete probe" : nil)
    }
    func release() { continuation?.resume(); continuation = nil }
}
