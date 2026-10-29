import Foundation
import Testing
@testable import ContainerDeskCore

struct ExecutableResolverTests {
    @Test func missingExplicitOverrideDoesNotFallBackToPathCandidate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathCandidate = try makePathCandidate(in: root)
        let missingOverride = root.appendingPathComponent("missing/container")

        let resolved = ExecutableResolver(overridePath: missingOverride.path)
            .resolve(environment: ["PATH": pathCandidate.deletingLastPathComponent().path])

        #expect(resolved == nil)
    }

    @Test func nonExecutableExplicitOverrideDoesNotFallBackToPathCandidate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathCandidate = try makePathCandidate(in: root)
        let override = root.appendingPathComponent("selected/container")
        try FileManager.default.createDirectory(at: override.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not executable".utf8).write(to: override)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: override.path)

        let resolved = ExecutableResolver(overridePath: override.path)
            .resolve(environment: ["PATH": pathCandidate.deletingLastPathComponent().path])

        #expect(resolved == nil)
    }

    @Test func validExplicitOverrideWithSpacesIsHonored() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathCandidate = try makePathCandidate(in: root)
        let override = root.appendingPathComponent("chosen tool/container executable")
        try FileManager.default.createDirectory(at: override.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(override)

        let resolved = ExecutableResolver(overridePath: override.path)
            .resolve(environment: ["PATH": pathCandidate.deletingLastPathComponent().path])

        #expect(resolved?.standardizedFileURL.path == override.standardizedFileURL.path)
    }

    @Test func directoryExplicitOverrideIsRejectedWithoutPathFallback() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathCandidate = try makePathCandidate(in: root)
        let directoryOverride = root.appendingPathComponent("selected/container", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryOverride, withIntermediateDirectories: true)

        let resolved = ExecutableResolver(overridePath: directoryOverride.path)
            .resolve(environment: ["PATH": pathCandidate.deletingLastPathComponent().path])

        #expect(resolved == nil)
    }

    @Test func executableSymlinkOverrideIsAccepted() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathCandidate = try makePathCandidate(in: root)
        let target = root.appendingPathComponent("real/container")
        let symlink = root.appendingPathComponent("selected/container")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let resolved = ExecutableResolver(overridePath: symlink.path)
            .resolve(environment: ["PATH": pathCandidate.deletingLastPathComponent().path])

        #expect(resolved?.standardizedFileURL.path == symlink.standardizedFileURL.path)
    }

    @Test(arguments: [nil, ""] as [String?])
    func nilOrEmptyOverrideRetainsPathDiscovery(override: String?) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathCandidate = try makePathCandidate(in: root)

        let resolved = ExecutableResolver(overridePath: override)
            .resolve(environment: ["PATH": pathCandidate.deletingLastPathComponent().path])

        // The resolver also checks fixed Homebrew locations, so assert discovery succeeds
        // without assuming which candidate is present on the host.
        #expect(resolved != nil)
    }

    private func makePathCandidate(in root: URL) throws -> URL {
        let candidate = root.appendingPathComponent("path fixture/container")
        try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(candidate)
        return candidate
    }

    private func writeExecutable(_ url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerDesk-executable-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
