import Foundation
import Testing
@testable import ContainerDeskCore

struct ContainerLimitsRecoveryTests {
    @Test func onlyCompletedUnreferencedSessionsCanBeRemoved() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let updated = try fixture.session(.updated)
        let rolledBack = try fixture.session(.rolledBack)
        let pending = try fixture.session(.inProgress)
        let needed = try fixture.session(.recoveryNeeded)
        let legacy = try fixture.session(nil)
        let reader = RecoveryInventoryStub()
        let service = ContainerLimitsRecoveryService(directory: fixture.root, reader: reader)
        let scan = try await service.scan()
        #expect(Set(scan.filter(\.canRemove).map { $0.directory.path }) == [updated.path, rolledBack.path])
        #expect(scan.allSatisfy { $0.allocatedBytes >= 0 })
        let result = try await service.remove(scan)
        #expect(result.filter(\.removed).count == 2, "\(result.map(\.message))")
        for kept in [pending, needed, legacy] { #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("rootfs.ext4").path)) }
    }

    @Test(arguments: ["kernel.bin", "initfs.ext4", "rootfs.ext4"])
    func everyResolvedRuntimeFileReferenceProtectsAnEntireSession(file: String) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let directory = try fixture.session(.rolledBack)
        let alias = fixture.root.appendingPathComponent("alias-\(UUID())")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let reader = RecoveryInventoryStub(references: [alias.appendingPathComponent(file)])
        let service = ContainerLimitsRecoveryService(directory: fixture.root, reader: reader)
        let scan = try await service.scan()
        #expect(scan.count == 1 && !scan[0].canRemove)
        #expect(try await service.remove(scan).allSatisfy { !$0.removed })
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func caseAliasesAndMountedParentDirectoriesProtectSessions() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let directory = try fixture.session(.updated)
        let alias = fixture.root.appendingPathComponent(directory.lastPathComponent.lowercased()).appendingPathComponent("kernel.bin")
        let reader = RecoveryInventoryStub(references: [alias])
        let service = ContainerLimitsRecoveryService(directory: fixture.root, reader: reader)
        let scan = try await service.scan()
        if FileManager.default.fileExists(atPath: alias.path) { #expect(scan.allSatisfy { !$0.canRemove }) }
        await reader.references([fixture.root])
        #expect(try await service.scan().allSatisfy { !$0.canRemove })
    }

    @Test func missingUnknownAndInterruptedOutcomesAreKeptAfterRestart() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let pending = try fixture.session(.inProgress)
        let legacy = try fixture.session(nil)
        let future = try fixture.session(.updated)
        try Data(#"{"version":2,"outcome":"updated"}"#.utf8).write(to: future.appendingPathComponent(LimitsRecoveryState.filename))
        let service = ContainerLimitsRecoveryService(directory: fixture.root, reader: RecoveryInventoryStub())
        let scan = try await service.scan()
        #expect(scan.count == 3 && scan.allSatisfy { !$0.canRemove })
        _ = try await service.remove(scan)
        for kept in [pending, legacy, future] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
    }

    @Test(arguments: [false, true])
    func incompleteOrFailedInventoryAbortsBeforeAnyRemoval(fails: Bool) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let directory = try fixture.session(.updated)
        let reader = RecoveryInventoryStub()
        let service = ContainerLimitsRecoveryService(directory: fixture.root, reader: reader)
        let review = try await service.scan()
        await reader.set(complete: false, fail: fails)
        await #expect(throws: (any Error).self) { _ = try await service.remove(review) }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rootfs.ext4").path))
    }

    @Test func newReferencesAndChangedFilesInvalidateAReviewedRemoval() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let directory = try fixture.session(.updated)
        let reader = RecoveryInventoryStub()
        let service = ContainerLimitsRecoveryService(directory: fixture.root, reader: reader)
        let review = try await service.scan()
        await reader.references([directory.appendingPathComponent("kernel.bin")])
        #expect(try await service.remove(review).allSatisfy { !$0.removed })
        await reader.references([])
        try Data("changed after review".utf8).write(to: directory.appendingPathComponent("rootfs.ext4"))
        #expect(try await service.remove(review).allSatisfy { !$0.removed })
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: [LimitsRecoveryOutcome.inProgress, .recoveryNeeded])
    func aChangedOutcomeAfterReviewCannotBeRemoved(outcome: LimitsRecoveryOutcome) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let directory = try fixture.session(.updated)
        let service = ContainerLimitsRecoveryService(directory: fixture.root, reader: RecoveryInventoryStub())
        let review = try await service.scan()
        try LimitsRecoveryState(sessionID: directory.lastPathComponent, containerID: "fixture", createdAt: .now, outcome: outcome).write(to: directory)
        #expect(try await service.remove(review).allSatisfy { !$0.removed })
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rootfs.ext4").path))
    }

    @Test func finalOutcomeMarkersArePrivateAndReadBackDurably() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        for outcome in [LimitsRecoveryOutcome.updated, .rolledBack, .recoveryNeeded] {
            let directory = try fixture.session(.inProgress)
            let result: ContainerLimitsApplyResult = switch outcome {
            case .updated: .updated(recoveryURL: directory)
            case .rolledBack: .rolledBack(recoveryURL: directory, reason: .replacementFailed)
            default: .recoveryNeeded(recoveryURL: directory, reason: .rollbackFailed)
            }
            LimitsRecoveryState.record(result)
            #expect(LimitsRecoveryState.read(at: directory)?.outcome == outcome)
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(LimitsRecoveryState.filename).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }
}

private struct RecoveryFixture {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/RecoveryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func session(_ outcome: LimitsRecoveryOutcome?) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["rootfs.ext4", "kernel.bin", "initfs.ext4", "recovery.json"] {
            try Data("fixture-\(name)".utf8).write(to: directory.appendingPathComponent(name))
        }
        if let outcome { try LimitsRecoveryState(sessionID: directory.lastPathComponent, containerID: "fixture", createdAt: .now, outcome: outcome).write(to: directory) }
        return directory
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor RecoveryInventoryStub: LimitsRecoveryInventoryReading {
    private var paths: [URL]
    private var complete = true
    private var fail = false
    init(references: [URL] = []) { paths = references }
    func references(_ paths: [URL]) { self.paths = paths }
    func set(complete: Bool, fail: Bool) { self.complete = complete; self.fail = fail }
    func inventory() throws -> LimitsRecoveryInventory {
        if fail { throw LimitsRecoveryError.incompleteInventory }
        return .init(referencedFiles: paths, complete: complete)
    }
}
