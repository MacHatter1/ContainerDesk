import AppKit
import SwiftUI
import Testing
@testable import ContainerDeskApp

@Suite(.serialized)
struct TerminalSessionRetentionTests {
    @MainActor @Test func detachedWrapperKeepsTheSamePTYUntilExplicitTermination() async throws {
        _ = NativeTestApplication.shared
        let fixture = try TerminalProcessFixture()
        defer { fixture.remove() }
        let policy = RuntimeOperationPolicy()
        let session = ContainerTerminalSession()
        defer { session.terminate() }
        let host = NSHostingView(rootView: TerminalRetentionHost(visible: true, policy: policy, executable: fixture.executable.path, session: session))
        let window = makeWindow(host)
        defer { window.contentView = nil; window.close() }
        try await wait(host) { fixture.launchCount == 1 }
        let terminal = try #require(session.terminalView)
        let process = try #require(terminal.process)
        let pid = process.shellPid
        #expect(pid > 0 && process.running)

        host.rootView = TerminalRetentionHost(visible: false, policy: policy, executable: fixture.executable.path, session: session)
        try await wait(host) { terminal.superview == nil }
        #expect(process.running, "Removing the SwiftUI wrapper must leave its owned PTY alive.")

        host.rootView = TerminalRetentionHost(visible: true, policy: policy, executable: fixture.executable.path, session: session)
        try await wait(host) { terminal.superview != nil }
        #expect(session.terminalView === terminal)
        #expect(process.shellPid == pid && process.running)
        #expect(fixture.launchCount == 1, "Remounting must reuse the process and terminal buffer.")

        session.terminate()
        try await wait(host) { !process.running }
        #expect(session.terminalView == nil)
    }

    @MainActor @Test func aDifferentRuntimeCannotReuseTheRetainedPTY() async throws {
        _ = NativeTestApplication.shared
        let fixture = try TerminalProcessFixture()
        defer { fixture.remove() }
        let session = ContainerTerminalSession()
        defer { session.terminate() }
        let policy = RuntimeOperationPolicy()
        let host = NSHostingView(rootView: TerminalRetentionHost(visible: true, policy: policy, executable: fixture.executable.path, session: session))
        let window = makeWindow(host)
        defer { window.contentView = nil; window.close() }
        try await wait(host) { fixture.launchCount == 1 }
        let original = try #require(session.terminalView)
        let originalProcess = try #require(original.process)
        host.rootView = TerminalRetentionHost(visible: false, policy: policy, executable: fixture.executable.path, session: session)
        try await wait(host) { original.superview == nil }

        host.rootView = TerminalRetentionHost(visible: true, policy: RuntimeOperationPolicy(), executable: fixture.executable.path, session: session)
        try await wait(host) { fixture.launchCount == 2 && !originalProcess.running }
        #expect(session.terminalView !== original)
    }

    @MainActor @Test func releasingTheDetachedOwnerTerminatesItsPTY() async throws {
        _ = NativeTestApplication.shared
        let fixture = try TerminalProcessFixture()
        defer { fixture.remove() }
        let policy = RuntimeOperationPolicy()
        var session: ContainerTerminalSession? = ContainerTerminalSession()
        weak var releasedSession = session
        let host = NSHostingView(rootView: TerminalRetentionHost(visible: true, policy: policy, executable: fixture.executable.path, session: session))
        let window = makeWindow(host)
        defer { window.contentView = nil; window.close() }
        try await wait(host) { fixture.launchCount == 1 }
        let terminal = try #require(session?.terminalView)
        let process = try #require(terminal.process)
        host.rootView = TerminalRetentionHost(visible: false, policy: policy, executable: fixture.executable.path, session: nil)
        try await wait(host) { terminal.superview == nil }
        session = nil
        try await wait(host) { releasedSession == nil && !process.running }
    }

    @MainActor private func makeWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    @MainActor private func wait(_ host: NSView, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }
}

private struct TerminalRetentionHost: View {
    let visible: Bool
    let policy: RuntimeOperationPolicy
    let executable: String
    let session: ContainerTerminalSession?

    var body: some View {
        if visible {
            ContainerTerminalView(arguments: ["exec", "fixture", "sh"], runtimeOperations: policy, executablePath: executable, session: session)
        }
    }
}

private struct TerminalProcessFixture {
    let folder: URL
    let executable: URL
    let marker: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        executable = folder.appendingPathComponent("container")
        marker = folder.appendingPathComponent("launches")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf x >> '\(marker.path)'\nexec /bin/cat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var launchCount: Int { (try? Data(contentsOf: marker).count) ?? 0 }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
