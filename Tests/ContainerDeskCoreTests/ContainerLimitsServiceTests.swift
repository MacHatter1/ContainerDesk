import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationOCI
import Foundation
import Testing
@testable import ContainerDeskCore

@Suite("Container limits recreation")
struct ContainerLimitsServiceTests {
    @Test func runningReplacementKeepsConfigurationMountsAndVerifiedRecoveryCopies() async throws {
        let fixture = try LimitsFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalRootfs = try Data(contentsOf: fixture.bundle.appendingPathComponent("rootfs.ext4"))
        let plan = try await fixture.service.prepare(id: fixture.id)
        let requested = ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)

        let result = await fixture.service.apply(plan, limits: requested)

        guard case .updated(let recoveryURL) = result else {
            Issue.record("Expected the running container replacement to succeed; received \(result).")
            return
        }
        let final = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(final.snapshot.status == .running)
        #expect(final.snapshot.configuration.resources.cpus == requested.cpus)
        #expect(final.snapshot.configuration.resources.memoryInBytes == requested.memoryBytes)
        #expect(final.snapshot.configuration.labels["test.label"] == "preserved")
        #expect(final.snapshot.configuration.initProcess.environment == ["APP_SECRET=fixture-secret", "MODE=review"])
        #expect(final.snapshot.configuration.mounts.count == fixture.originalState.snapshot.configuration.mounts.count)
        #expect(final.snapshot.configuration.mounts.first?.volumeName == "user-data")
        #expect(final.snapshot.configuration.mounts.first?.source == fixture.volumeFile.path)
        #expect(try Data(contentsOf: fixture.bundle.appendingPathComponent("rootfs.ext4")) == originalRootfs)
        #expect(try Data(contentsOf: recoveryURL.appendingPathComponent("rootfs.ext4")) == originalRootfs)
        #expect(try Data(contentsOf: recoveryURL.appendingPathComponent("initfs.ext4")) == fixture.initfsBytes)
        #expect(try Data(contentsOf: recoveryURL.appendingPathComponent("kernel.bin")) == fixture.kernelBytes)
        let recoveryPermissions = try FileManager.default.attributesOfItem(atPath: recoveryURL.appendingPathComponent("recovery.json").path)[.posixPermissions] as? NSNumber
        #expect(recoveryPermissions?.intValue == 0o600)
        #expect(final.initialFilesystem.source == recoveryURL.appendingPathComponent("initfs.ext4").path)
        #expect(final.kernel.path == recoveryURL.appendingPathComponent("kernel.bin"))
        #expect(FileManager.default.fileExists(atPath: fixture.volumeFile.path))
        let activity = await fixture.runtime.activity()
        #expect(activity.firstIndex(of: "preflight")! < activity.firstIndex(of: "delete")!)
        #expect(activity.filter { $0 == "delete" }.count == 1)
    }

    @Test func runningTTYReplacementPreservesTerminalConfigurationMountsAndDiskData() async throws {
        let fixture = try LimitsFixture.make(terminalEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalRootfs = try Data(contentsOf: fixture.bundle.appendingPathComponent("rootfs.ext4"))
        let originalVolume = try Data(contentsOf: fixture.volumeFile)
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .updated = result else {
            Issue.record("Expected the running TTY container replacement to succeed; received \(result).")
            return
        }
        let final = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(final.snapshot.status == .running)
        #expect(final.snapshot.configuration.resources.memoryInBytes == 200 * mebibyte)
        #expect(final.snapshot.configuration.initProcess.terminal)
        let runtimeConfiguration = try #require(final.runtimeConfiguration.containerConfiguration)
        #expect(runtimeConfiguration.initProcess.terminal)
        #expect(final.snapshot.configuration.initProcess.environment == fixture.originalState.snapshot.configuration.initProcess.environment)
        #expect(final.snapshot.configuration.labels["test.label"] == "preserved")
        #expect(final.snapshot.configuration.mounts.first?.volumeName == "user-data")
        #expect(final.snapshot.configuration.mounts.first?.source == fixture.volumeFile.path)
        #expect(try Data(contentsOf: fixture.bundle.appendingPathComponent("rootfs.ext4")) == originalRootfs)
        #expect(try Data(contentsOf: fixture.volumeFile) == originalVolume)
        #expect((await fixture.runtime.activity()).filter { $0 == "start" }.count == 1)
    }

    @Test func stoppedTTYReplacementStaysStoppedAndPreservesTerminalAndVolumeData() async throws {
        let fixture = try LimitsFixture.make(status: .stopped, terminalEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalVolume = try Data(contentsOf: fixture.volumeFile)
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .updated = result else {
            Issue.record("Expected the stopped TTY container replacement to succeed; received \(result).")
            return
        }
        let final = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(final.snapshot.status == .stopped)
        #expect(final.snapshot.configuration.initProcess.terminal)
        let runtimeConfiguration = try #require(final.runtimeConfiguration.containerConfiguration)
        #expect(runtimeConfiguration.initProcess.terminal)
        #expect(final.snapshot.configuration.mounts.first?.volumeName == "user-data")
        #expect(try Data(contentsOf: fixture.volumeFile) == originalVolume)
        let activity = await fixture.runtime.activity()
        #expect(!activity.contains("start"))
        #expect(!activity.contains("stop"))
    }

    @Test func neverStartedTTYReplacementStaysColdAndPreservesTerminalAndVolumeData() async throws {
        let fixture = try LimitsFixture.make(status: .stopped, neverStarted: true, terminalEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalVolume = try Data(contentsOf: fixture.volumeFile)
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .updated = result else {
            Issue.record("Expected the never-started TTY container replacement to succeed; received \(result).")
            return
        }
        let final = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(final.snapshot.status == .stopped)
        #expect(final.snapshot.configuration.initProcess.terminal)
        let runtimeConfiguration = try #require(final.runtimeConfiguration.containerConfiguration)
        #expect(runtimeConfiguration.initProcess.terminal)
        #expect(final.snapshot.configuration.mounts.first?.volumeName == "user-data")
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("rootfs.ext4").path))
        #expect(FileManager.default.fileExists(atPath: fixture.imageRootfs.path))
        #expect(try Data(contentsOf: fixture.volumeFile) == originalVolume)
        let activity = await fixture.runtime.activity()
        #expect(!activity.contains("start"))
        #expect(!activity.contains("stop"))
    }

    @Test func runningTTYCreateFailureRollsBackAndPreservesTerminalAndDiskData() async throws {
        let fixture = try LimitsFixture.make(terminalEnabled: true, createFailures: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalRootfs = try Data(contentsOf: fixture.bundle.appendingPathComponent("rootfs.ext4"))
        let originalVolume = try Data(contentsOf: fixture.volumeFile)
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .rolledBack = result else {
            Issue.record("Expected the running TTY container to roll back after create failure; received \(result).")
            return
        }
        let restored = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(restored.snapshot.status == .running)
        #expect(restored.snapshot.configuration.initProcess.terminal)
        let runtimeConfiguration = try #require(restored.runtimeConfiguration.containerConfiguration)
        #expect(runtimeConfiguration.initProcess.terminal)
        #expect(restored.snapshot.configuration.mounts.first?.volumeName == "user-data")
        #expect(try Data(contentsOf: fixture.bundle.appendingPathComponent("rootfs.ext4")) == originalRootfs)
        #expect(try Data(contentsOf: fixture.volumeFile) == originalVolume)
    }

    @Test func stoppedReplacementRemainsStoppedAndDoesNotStartOrStop() async throws {
        let fixture = try LimitsFixture.make(status: .stopped)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .updated = result else {
            Issue.record("Expected the stopped container replacement to succeed; received \(result).")
            return
        }
        let final = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(final.snapshot.status == .stopped)
        let activity = await fixture.runtime.activity()
        #expect(!activity.contains("stop"))
        #expect(!activity.contains("start"))
    }

    @Test func neverStartedContainerCanEditLimitsWithoutBootingOrDiscardingWritableData() async throws {
        let fixture = try LimitsFixture.make(status: .stopped, neverStarted: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .updated = result else {
            Issue.record("Expected the never-started container replacement to succeed; received \(result).")
            return
        }
        let final = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(final.snapshot.status == .stopped)
        #expect(final.snapshot.configuration.resources.memoryInBytes == 200 * mebibyte)
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("rootfs.ext4").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("rootfs.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.imageRootfs.path))
        #expect(try Data(contentsOf: fixture.volumeFile) == Data("persistent volume contents".utf8))
        let activity = await fixture.runtime.activity()
        #expect(!activity.contains("start"))
        #expect(!activity.contains("stop"))
        #expect(activity.filter { $0 == "delete" }.count == 1)
    }

    @Test func neverStartedCreateFailureRestoresOriginalLimitsAndRemainsStopped() async throws {
        let fixture = try LimitsFixture.make(status: .stopped, neverStarted: true, createFailures: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .rolledBack = result else {
            Issue.record("Expected a verified cold rollback; received \(result).")
            return
        }
        let restored = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(restored.snapshot.status == .stopped)
        #expect(restored.snapshot.configuration.resources.cpus == fixture.originalState.snapshot.configuration.resources.cpus)
        #expect(restored.snapshot.configuration.resources.memoryInBytes == fixture.originalState.snapshot.configuration.resources.memoryInBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("rootfs.ext4").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("rootfs.json").path))
        #expect(!(await fixture.runtime.activity()).contains("start"))
    }

    @Test func missingRootfsFromBootstrappedContainerIsNotTreatedAsNeverStarted() async throws {
        let fixture = try LimitsFixture.make(status: .stopped)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent("rootfs.ext4"))
        try Data("bootstrapped metadata".utf8).write(to: fixture.bundle.appendingPathComponent("rootfs.json"))

        await #expect(throws: ContainerLimitsIssue.unsupportedContainer) {
            try await fixture.service.prepare(id: fixture.id)
        }
        #expect(!(await fixture.runtime.activity()).contains("delete"))
    }

    @Test func missingBootArtifactsWithPriorStartTimestampAreRejected() async throws {
        let fixture = try LimitsFixture.make(status: .stopped, everStarted: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent("rootfs.ext4"))

        await #expect(throws: ContainerLimitsIssue.unsupportedContainer) {
            try await fixture.service.prepare(id: fixture.id)
        }
        #expect(!(await fixture.runtime.activity()).contains("delete"))
    }

    @Test func aSecondEditAcceptsTheRuntimeOwnedRootFilesystemOverride() async throws {
        let fixture = try LimitsFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstPlan = try await fixture.service.prepare(id: fixture.id)
        let firstResult = await fixture.service.apply(
            firstPlan,
            limits: ContainerResourceLimits(cpus: validCPUCount(firstPlan), memoryBytes: 200 * mebibyte)
        )
        guard case .updated = firstResult else {
            Issue.record("Expected the first replacement to succeed; received \(firstResult).")
            return
        }
        let firstReplacement = try #require(await fixture.runtime.inspect(id: fixture.id))
        guard let override = firstReplacement.options?.rootFsOverride,
              case .block(let format, _, _) = override.type else {
            Issue.record("Expected a runtime-owned block root filesystem override after replacement.")
            return
        }
        #expect(format == "ext4")
        #expect(URL(fileURLWithPath: override.source).standardizedFileURL == fixture.bundle.appendingPathComponent("rootfs.ext4").standardizedFileURL)
        #expect(override.destination == "/")

        let secondPlan = try await fixture.service.prepare(id: fixture.id)
        let secondResult = await fixture.service.apply(
            secondPlan,
            limits: ContainerResourceLimits(cpus: validCPUCount(secondPlan), memoryBytes: 256 * mebibyte)
        )
        guard case .updated = secondResult else {
            Issue.record("Expected the second replacement to succeed; received \(secondResult).")
            return
        }
        let secondReplacement = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(secondReplacement.snapshot.status == .running)
        #expect(secondReplacement.snapshot.configuration.resources.memoryInBytes == 256 * mebibyte)
        #expect((await fixture.runtime.activity()).filter { $0 == "delete" }.count == 2)
    }

    @Test func staleConfigurationAndInvalidLimitsNeverDeleteTheContainer() async throws {
        let staleFixture = try LimitsFixture.make()
        defer { try? FileManager.default.removeItem(at: staleFixture.root) }
        let stalePlan = try await staleFixture.service.prepare(id: staleFixture.id)
        await staleFixture.runtime.changeLabel()
        let staleResult = await staleFixture.service.apply(
            stalePlan,
            limits: ContainerResourceLimits(cpus: validCPUCount(stalePlan), memoryBytes: 200 * mebibyte)
        )
        #expect(staleResult == .unchanged(reason: .staleReview))
        #expect(!(await staleFixture.runtime.activity()).contains("delete"))

        let invalidFixture = try LimitsFixture.make()
        defer { try? FileManager.default.removeItem(at: invalidFixture.root) }
        let invalidPlan = try await invalidFixture.service.prepare(id: invalidFixture.id)
        let invalidResult = await invalidFixture.service.apply(
            invalidPlan,
            limits: ContainerResourceLimits(cpus: 0, memoryBytes: 200 * mebibyte)
        )
        #expect(invalidResult == .unchanged(reason: .invalidLimits))
        #expect(!(await invalidFixture.runtime.activity()).contains("delete"))

        let invalidMemoryFixture = try LimitsFixture.make()
        defer { try? FileManager.default.removeItem(at: invalidMemoryFixture.root) }
        let invalidMemoryPlan = try await invalidMemoryFixture.service.prepare(id: invalidMemoryFixture.id)
        let invalidMemoryResult = await invalidMemoryFixture.service.apply(
            invalidMemoryPlan,
            limits: ContainerResourceLimits(cpus: validCPUCount(invalidMemoryPlan), memoryBytes: 199 * mebibyte)
        )
        #expect(invalidMemoryResult == .unchanged(reason: .invalidLimits))
        #expect(!(await invalidMemoryFixture.runtime.activity()).contains("delete"))
    }

    @Test func staleStatusAndAmbiguousDeleteKeepRecoverySafe() async throws {
        let staleFixture = try LimitsFixture.make()
        defer { try? FileManager.default.removeItem(at: staleFixture.root) }
        let stalePlan = try await staleFixture.service.prepare(id: staleFixture.id)
        await staleFixture.runtime.changeStatus(.stopped)
        let staleResult = await staleFixture.service.apply(
            stalePlan,
            limits: ContainerResourceLimits(cpus: validCPUCount(stalePlan), memoryBytes: 200 * mebibyte)
        )
        #expect(staleResult == .unchanged(reason: .staleReview))
        #expect(!(await staleFixture.runtime.activity()).contains("delete"))
        #expect(!(await staleFixture.runtime.activity()).contains("stop"))

        let ambiguousFixture = try LimitsFixture.make(deleteRemovesThenThrows: true)
        defer { try? FileManager.default.removeItem(at: ambiguousFixture.root) }
        let ambiguousPlan = try await ambiguousFixture.service.prepare(id: ambiguousFixture.id)
        let ambiguousResult = await ambiguousFixture.service.apply(
            ambiguousPlan,
            limits: ContainerResourceLimits(cpus: validCPUCount(ambiguousPlan), memoryBytes: 200 * mebibyte)
        )
        guard case .rolledBack = ambiguousResult else {
            Issue.record("Expected recovery after an ambiguous delete outcome; received \(ambiguousResult).")
            return
        }
        let restored = try #require(await ambiguousFixture.runtime.inspect(id: ambiguousFixture.id))
        #expect(restored.snapshot.status == .running)
        #expect((await ambiguousFixture.runtime.activity()).filter { $0 == "delete" }.count == 1)
    }

    @Test(arguments: [UnsupportedFixture.autoRemove, .tmpfs])
    func unsafeFilesystemSettingsAreRejectedBeforeAnyMutation(_ kind: UnsupportedFixture) async throws {
        let fixture = try LimitsFixture.make(unsupported: kind)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: ContainerLimitsIssue.unsupportedContainer) {
            try await fixture.service.prepare(id: fixture.id)
        }
        let activity = await fixture.runtime.activity()
        #expect(!activity.contains("stop"))
        #expect(!activity.contains("delete"))
        #expect(!activity.contains("create"))
    }

    @Test func failedBackupRestartsOriginalAndDoesNotDeleteIt() async throws {
        let fixture = try LimitsFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.service.prepare(id: fixture.id)
        let recoveryRoot = fixture.recoveryRoot

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte),
            onProgress: { phase in
                if phase == .backingUp,
                   let session = try? FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil).first {
                    // A destination collision fails copying while leaving every original boot file intact.
                    try? Data("copy collision".utf8).write(to: session.appendingPathComponent("rootfs.ext4"))
                }
            }
        )

        #expect(result == .unchanged(reason: .backupFailed))
        let restored = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(restored.snapshot.status == .running)
        #expect(!(await fixture.runtime.activity()).contains("delete"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path).isEmpty)
    }

    @Test func createFailureRollsBackWithoutExposingSecretErrorText() async throws {
        let fixture = try LimitsFixture.make(createFailures: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .rolledBack(_, let reason) = result else {
            Issue.record("Expected the original container to be restored; received \(result).")
            return
        }
        let restored = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(restored.snapshot.status == .running)
        #expect(restored.snapshot.configuration.resources.cpus == fixture.originalState.snapshot.configuration.resources.cpus)
        #expect(restored.snapshot.configuration.resources.memoryInBytes == fixture.originalState.snapshot.configuration.resources.memoryInBytes)
        #expect(restored.snapshot.configuration.initProcess.environment == fixture.originalState.snapshot.configuration.initProcess.environment)
        #expect(!reason.localizedDescription.contains("fixture-secret"))
        #expect(!reason.localizedDescription.contains("raw injected failure"))
        #expect((await fixture.runtime.activity()).filter { $0 == "delete" }.count == 1)
    }

    @Test func failedReplacementStartRollsBackAndRestoresRunningState() async throws {
        let fixture = try LimitsFixture.make(startFailures: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .rolledBack = result else {
            Issue.record("Expected a verified rollback after the replacement failed to start; received \(result).")
            return
        }
        let restored = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(restored.snapshot.status == .running)
        #expect(restored.snapshot.configuration.resources.cpus == fixture.originalState.snapshot.configuration.resources.cpus)
        #expect(restored.snapshot.configuration.resources.memoryInBytes == fixture.originalState.snapshot.configuration.resources.memoryInBytes)
        #expect((await fixture.runtime.activity()).filter { $0 == "start" }.count == 2)
    }

    @Test func mismatchedReplacementIsNeverDeletedDuringRollback() async throws {
        let fixture = try LimitsFixture.make(corruptCreatedConfiguration: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try await fixture.service.prepare(id: fixture.id)

        let result = await fixture.service.apply(
            plan,
            limits: ContainerResourceLimits(cpus: validCPUCount(plan), memoryBytes: 200 * mebibyte)
        )

        guard case .recoveryNeeded = result else {
            Issue.record("Expected manual recovery when the replacement no longer matches the reviewed configuration; received \(result).")
            return
        }
        #expect((await fixture.runtime.activity()).filter { $0 == "delete" }.count == 1)
        let current = try #require(await fixture.runtime.inspect(id: fixture.id))
        #expect(current.snapshot.configuration.resources.cpus == validCPUCount(plan) + 1)
    }
}

enum UnsupportedFixture: CaseIterable, Sendable {
    case autoRemove
    case tmpfs
}

private struct LimitsFixture {
    let root: URL
    let appRoot: URL
    let bundle: URL
    let recoveryRoot: URL
    let id: String
    let initfsBytes: Data
    let kernelBytes: Data
    let volumeFile: URL
    let imageRootfs: URL
    let originalState: ContainerLimitsRuntimeState
    let runtime: ScriptedLimitsRuntime
    let service: ContainerLimitsService

    static func make(
        status: RuntimeStatus = .running,
        neverStarted: Bool = false,
        everStarted: Bool = false,
        unsupported: UnsupportedFixture? = nil,
        terminalEnabled: Bool = false,
        createFailures: Int = 0,
        startFailures: Int = 0,
        corruptCreatedConfiguration: Bool = false,
        deleteRemovesThenThrows: Bool = false
    ) throws -> LimitsFixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ContainerLimitsServiceTests-\(UUID().uuidString)", isDirectory: true)
        let appRoot = root.appendingPathComponent("container-app", isDirectory: true)
        let id = "limits-fixture"
        let bundle = appRoot.appendingPathComponent("containers", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        let recoveryRoot = root.appendingPathComponent("recovery", isDirectory: true)
        let volumeFile = root.appendingPathComponent("persistent-volume.ext4")
        let imageRootfs = appRoot.appendingPathComponent("images", isDirectory: true).appendingPathComponent("fixture-rootfs.ext4")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageRootfs.deletingLastPathComponent(), withIntermediateDirectories: true)
        let initfsBytes = Data("fixture init filesystem".utf8)
        let kernelBytes = Data("fixture kernel".utf8)
        if !neverStarted {
            try Data("fixture writable filesystem".utf8).write(to: bundle.appendingPathComponent("rootfs.ext4"))
        }
        try Data("fixture image filesystem".utf8).write(to: imageRootfs)
        try initfsBytes.write(to: appRoot.appendingPathComponent("initfs.ext4"))
        try kernelBytes.write(to: appRoot.appendingPathComponent("kernel.bin"))
        try Data("persistent volume contents".utf8).write(to: volumeFile)

        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "sleep infinity"],
            environment: ["APP_SECRET=fixture-secret", "MODE=review"],
            terminal: terminalEnabled
        )
        let image = ImageDescription(
            reference: "example.test/app:fixture",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "a", count: 64), size: 12)
        )
        var configuration = ContainerConfiguration(id: id, image: image, process: process)
        configuration.platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux")
        configuration.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        configuration.labels = ["test.label": "preserved"]
        configuration.resources.cpus = 2
        configuration.resources.memoryInBytes = 512 * mebibyte
        configuration.resources.cpuOverhead = 0
        configuration.mounts = [
            .volume(name: "user-data", format: "ext4", source: volumeFile.path, destination: "/data", options: [])
        ]
        if case .some(.tmpfs) = unsupported {
            configuration.mounts.append(.tmpfs(destination: "/scratch", options: []))
        }

        let initialFilesystem = Filesystem.block(format: "ext4", source: appRoot.appendingPathComponent("initfs.ext4").path, destination: "initfs", options: [])
        let rootFilesystem = Filesystem.block(format: "ext4", source: bundle.appendingPathComponent("rootfs.ext4").path, destination: "/", options: [])
        let imageFilesystem = Filesystem.block(format: "ext4", source: imageRootfs.path, destination: "/", options: [])
        let kernel = Kernel(path: appRoot.appendingPathComponent("kernel.bin"), platform: .linuxArm)
        let autoRemove: Bool
        if case .some(.autoRemove) = unsupported { autoRemove = true } else { autoRemove = false }
        let options = ContainerCreateOptions(autoRemove: autoRemove)
        let runtimeConfiguration = RuntimeConfiguration(
            path: bundle,
            initialFilesystem: initialFilesystem,
            kernel: kernel,
            containerConfiguration: configuration,
            containerRootFilesystem: neverStarted ? imageFilesystem : nil,
            options: options
        )
        let state = ContainerLimitsRuntimeState(
            snapshot: ContainerSnapshot(
                configuration: configuration,
                status: status,
                networks: [],
                startedDate: everStarted ? Date(timeIntervalSince1970: 1_700_000_100) : nil
            ),
            runtimeConfiguration: runtimeConfiguration,
            appRoot: appRoot,
            bundlePath: bundle,
            kernel: kernel,
            initialFilesystem: initialFilesystem,
            rootFilesystem: neverStarted ? imageFilesystem : rootFilesystem,
            options: options
        )
        let runtime = ScriptedLimitsRuntime(
            initialState: state,
            createFailures: createFailures,
            startFailures: startFailures,
            corruptCreatedConfiguration: corruptCreatedConfiguration,
            deleteRemovesThenThrows: deleteRemovesThenThrows
        )
        return LimitsFixture(
            root: root,
            appRoot: appRoot,
            bundle: bundle,
            recoveryRoot: recoveryRoot,
            id: id,
            initfsBytes: initfsBytes,
            kernelBytes: kernelBytes,
            volumeFile: volumeFile,
            imageRootfs: imageRootfs,
            originalState: state,
            runtime: runtime,
            service: ContainerLimitsService(runtime: runtime, recoveryDirectory: recoveryRoot)
        )
    }
}

private actor ScriptedLimitsRuntime: ContainerLimitsRuntime {
    private var current: ContainerLimitsRuntimeState?
    private let template: ContainerLimitsRuntimeState
    private var createFailures: Int
    private var startFailures: Int
    private let corruptCreatedConfiguration: Bool
    private var deleteRemovesThenThrows: Bool
    private var calls: [String] = []

    init(
        initialState: ContainerLimitsRuntimeState,
        createFailures: Int,
        startFailures: Int,
        corruptCreatedConfiguration: Bool,
        deleteRemovesThenThrows: Bool
    ) {
        self.current = initialState
        self.template = initialState
        self.createFailures = createFailures
        self.startFailures = startFailures
        self.corruptCreatedConfiguration = corruptCreatedConfiguration
        self.deleteRemovesThenThrows = deleteRemovesThenThrows
    }

    func inspect(id: String) async throws -> ContainerLimitsRuntimeState? {
        guard current?.snapshot.id == id else { return nil }
        return current
    }

    func stop(id: String) async throws {
        calls.append("stop")
        guard let current, current.snapshot.id == id else { throw TestRuntimeFailure.injected }
        self.current = replacing(current, status: .stopped)
    }

    func delete(id: String) async throws {
        calls.append("delete")
        guard let current, current.snapshot.id == id else { throw TestRuntimeFailure.injected }
        try FileManager.default.removeItem(at: current.bundlePath)
        self.current = nil
        if deleteRemovesThenThrows {
            deleteRemovesThenThrows = false
            throw TestRuntimeFailure.injected
        }
    }

    func preflightCreate(platform: ContainerizationOCI.Platform) async throws -> String {
        calls.append("preflight")
        return "fixture/init:local"
    }

    func create(configuration: ContainerConfiguration, options: ContainerCreateOptions, kernel: Kernel, initImage: String) async throws {
        calls.append("create")
        if createFailures > 0 {
            createFailures -= 1
            throw TestRuntimeFailure.injected
        }
        guard current == nil else { throw TestRuntimeFailure.injected }
        try FileManager.default.createDirectory(at: template.bundlePath, withIntermediateDirectories: true)
        let createdConfiguration: ContainerConfiguration
        if corruptCreatedConfiguration {
            var corrupted = configuration
            corrupted.resources.cpus += 1
            createdConfiguration = corrupted
        } else {
            createdConfiguration = configuration
        }
        let runtimeConfiguration = RuntimeConfiguration(
            path: template.bundlePath,
            initialFilesystem: template.initialFilesystem,
            kernel: kernel,
            containerConfiguration: createdConfiguration,
            containerRootFilesystem: template.runtimeConfiguration.containerRootFilesystem,
            options: options
        )
        current = makeState(
            template: template,
            configuration: createdConfiguration,
            status: .stopped,
            runtimeConfiguration: runtimeConfiguration,
            options: options,
            kernel: kernel,
            initialFilesystem: template.initialFilesystem
        )
    }

    func replaceColdRuntimeConfiguration(_ configuration: RuntimeConfiguration) async throws {
        guard let current else { throw TestRuntimeFailure.injected }
        self.current = makeState(
            template: template,
            configuration: current.snapshot.configuration,
            status: current.snapshot.status,
            runtimeConfiguration: configuration,
            options: configuration.options,
            kernel: configuration.kernel,
            initialFilesystem: configuration.initialFilesystem
        )
    }

    func start(id: String) async throws {
        calls.append("start")
        if startFailures > 0 {
            startFailures -= 1
            throw TestRuntimeFailure.injected
        }
        guard let current, current.snapshot.id == id else { throw TestRuntimeFailure.injected }
        self.current = replacing(current, status: .running)
    }

    func changeLabel() {
        guard let current else { return }
        var configuration = current.snapshot.configuration
        configuration.labels["test.label"] = "changed after review"
        let runtimeConfiguration = RuntimeConfiguration(
            path: current.bundlePath,
            initialFilesystem: current.initialFilesystem,
            kernel: current.kernel,
            containerConfiguration: configuration,
            options: current.options
        )
        self.current = makeState(
            template: template,
            configuration: configuration,
            status: current.snapshot.status,
            runtimeConfiguration: runtimeConfiguration,
            options: current.options,
            kernel: current.kernel,
            initialFilesystem: current.initialFilesystem
        )
    }

    func changeStatus(_ status: RuntimeStatus) {
        guard let current else { return }
        self.current = replacing(current, status: status)
    }

    func activity() -> [String] { calls }
}

private enum TestRuntimeFailure: Error, LocalizedError {
    case injected
    var errorDescription: String? { "raw injected failure contains fixture-secret" }
}

private func replacing(_ state: ContainerLimitsRuntimeState, status: RuntimeStatus) -> ContainerLimitsRuntimeState {
    ContainerLimitsRuntimeState(
        snapshot: ContainerSnapshot(configuration: state.snapshot.configuration, status: status, networks: state.snapshot.networks, startedDate: state.snapshot.startedDate),
        runtimeConfiguration: state.runtimeConfiguration,
        appRoot: state.appRoot,
        bundlePath: state.bundlePath,
        kernel: state.kernel,
        initialFilesystem: state.initialFilesystem,
        rootFilesystem: state.rootFilesystem,
        options: state.options
    )
}

private func makeState(
    template: ContainerLimitsRuntimeState,
    configuration: ContainerConfiguration,
    status: RuntimeStatus,
    runtimeConfiguration: RuntimeConfiguration,
    options: ContainerCreateOptions?,
    kernel: Kernel,
    initialFilesystem: Filesystem
) -> ContainerLimitsRuntimeState {
    let rootFilesystem = options?.rootFsOverride
        ?? runtimeConfiguration.containerRootFilesystem
        ?? Filesystem.block(
            format: "ext4",
            source: template.bundlePath.appendingPathComponent("rootfs.ext4").path,
            destination: "/",
            options: []
        )
    return ContainerLimitsRuntimeState(
        snapshot: ContainerSnapshot(configuration: configuration, status: status, networks: template.snapshot.networks),
        runtimeConfiguration: runtimeConfiguration,
        appRoot: template.appRoot,
        bundlePath: template.bundlePath,
        kernel: kernel,
        initialFilesystem: initialFilesystem,
        rootFilesystem: rootFilesystem,
        options: options
    )
}

private let mebibyte: UInt64 = 1_048_576

private func validCPUCount(_ plan: ContainerLimitsPlan) -> Int {
    min(max(1, plan.currentLimits.cpus), plan.maximumCPUs)
}
