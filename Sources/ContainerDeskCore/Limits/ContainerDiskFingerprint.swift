import CryptoKit
import Darwin
import Foundation

/// A versioned backup-equality fingerprint. It includes logical size, data extents and their bytes.
/// Hole layout is intentionally significant: a layout mismatch fails closed rather than scanning zeros.
enum ContainerDiskFingerprint {
    static func digest(of url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ContainerLimitsIssue.backupFailed }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_size >= 0,
              initial.st_mode & S_IFMT == S_IFREG else { throw ContainerLimitsIssue.backupFailed }

        // Do not populate the machine's file cache with multi-gigabyte disk images.
        _ = fcntl(descriptor, F_NOCACHE, 1)
        _ = fcntl(descriptor, F_RDAHEAD, 0)
        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 64)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        let domain = Array("ContainerDesk sparse disk fingerprint v1\0".utf8)
        domain.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        append(UInt64(initial.st_size), to: &hasher)
        var cursor: off_t = 0

        while cursor < initial.st_size {
            try Task.checkCancellation()
            let data = lseek(descriptor, cursor, SEEK_DATA)
            if data == -1, errno == ENXIO { break }
            guard data >= cursor, data < initial.st_size else { throw ContainerLimitsIssue.backupFailed }
            let hole = lseek(descriptor, data, SEEK_HOLE)
            guard hole > data, hole <= initial.st_size else { throw ContainerLimitsIssue.backupFailed }
            append(UInt64(data), to: &hasher)
            append(UInt64(hole - data), to: &hasher)

            var position = data
            while position < hole {
                try Task.checkCancellation()
                let count = min(capacity, Int(hole - position))
                let received = pread(descriptor, buffer, count, position)
                if received == -1, errno == EINTR { continue }
                guard received > 0 else { throw ContainerLimitsIssue.backupFailed }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: received))
                position += off_t(received)
            }
            cursor = hole
        }

        var final = stat()
        var named = stat()
        guard fstat(descriptor, &final) == 0, lstat(url.path, &named) == 0,
              unchanged(initial, final), unchanged(initial, named) else {
            throw ContainerLimitsIssue.backupFailed
        }
        return "sparse-sha256-v1:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: UInt64, to hasher: inout SHA256) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { hasher.update(bufferPointer: $0) }
    }

    private static func unchanged(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_size == second.st_size && first.st_blocks == second.st_blocks
            && first.st_mode == second.st_mode
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}
