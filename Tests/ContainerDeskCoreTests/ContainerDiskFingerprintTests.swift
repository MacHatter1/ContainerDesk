import Darwin
import Foundation
import Testing
@testable import ContainerDeskCore

@Suite("Sparse disk fingerprint")
struct ContainerDiskFingerprintTests {
    @Test func sparseDiskVerificationHasBoundedMemoryAndWork() throws {
        let parent = ProcessInfo.processInfo.environment["CONTAINERDESK_SPARSE_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let directory = parent.appendingPathComponent("DiskFingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sparse.ext4")
        let descriptor = Darwin.open(file.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let logicalSize: off_t = 512 * 1024 * 1024 * 1024
        #expect(ftruncate(descriptor, logicalSize) == 0)
        let marker = Array("disposable disk marker".utf8)
        for offset in [off_t(0), logicalSize / 2, logicalSize - 4096] {
            #expect(marker.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, offset) } == marker.count)
        }
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        let started = ContinuousClock.now
        _ = try ContainerLimitsService.fileDigest(file)
        let elapsed = started.duration(to: .now)
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)
        let peakGrowth = after.ru_maxrss - before.ru_maxrss
        #expect(peakGrowth < 64 * 1024 * 1024, "Fingerprinting sparse data must not retain read buffers: peak growth \(peakGrowth) bytes")
        #expect(elapsed < .seconds(3), "Fingerprinting must skip unallocated disk space: elapsed \(elapsed)")
    }

    @Test func clonedDisksMatchAndContentSizeAndHoleChangesAreDetected() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("DiskFingerprintIntegrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.ext4")
        let copied = directory.appendingPathComponent("copy.ext4")
        let descriptor = Darwin.open(original.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ContainerLimitsIssue.backupFailed }
        defer { Darwin.close(descriptor) }
        #expect(ftruncate(descriptor, 1024 * 1024 * 1024) == 0)
        let bytes = Array("preserved bytes".utf8)
        #expect(bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 4096) } == bytes.count)
        #expect(clonefile(original.path, copied.path, UInt32(CLONE_NOFOLLOW)) == 0)
        let expected = try ContainerLimitsService.fileDigest(original)
        #expect(try ContainerLimitsService.fileDigest(copied) == expected)
        let changed = Darwin.open(copied.path, O_WRONLY)
        guard changed >= 0 else { throw ContainerLimitsIssue.backupFailed }
        defer { Darwin.close(changed) }
        var other: UInt8 = 0x41
        #expect(pwrite(changed, &other, 1, 4096) == 1)
        #expect(try ContainerLimitsService.fileDigest(copied) != expected)
        #expect(ftruncate(descriptor, 2 * 1024 * 1024 * 1024) == 0)
        #expect(try ContainerLimitsService.fileDigest(original) != expected)
        let symlink = directory.appendingPathComponent("link.ext4")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        #expect(throws: ContainerLimitsIssue.backupFailed) { try ContainerLimitsService.fileDigest(symlink) }
    }
}
