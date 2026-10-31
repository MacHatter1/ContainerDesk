import AppKit
import ContainerDeskCore
import SwiftUI
import Testing
@testable import ContainerDeskApp

@Suite(.serialized)
struct TerminalAdmissionTests {
    @MainActor @Test(arguments: [ContainerSection.containers, .machines])
    func retainedTerminalDestinationCannotLaunchDuringLimitsChange(_ section: ContainerSection) async throws {
        _ = NativeTestApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("launched")
        let executable = folder.appendingPathComponent("container")
        try "#!/bin/sh\nprintf launched >> '\(marker.path)'\nexec /bin/cat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "TerminalAdmission.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        store.cliPath = executable.path
        let token = try #require(store.runtimeOperations.beginLimitsChange("other-container"))
        defer { store.runtimeOperations.endLimitsChange(token) }
        let activation = ResourceFeatureActivation(isActive: false)
        let host = NSHostingView(rootView: ResourceDetailPane(
            resource: .init(id: "fixture", title: "Fixture", state: "running"), section: section,
            tab: .constant(.terminal), transientText: .constant(""), store: store,
            limitsOperationInProgress: false, activation: activation,
            onNotice: { _ in }, action: { _ in }, onRun: { _ in }, onEditLimits: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "The actual terminal must not start a PTY while another window holds the limits lease.")
        store.runtimeOperations.endLimitsChange(token)
        activation.update(isActive: true)
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path), "Admission resumes after the limits transaction finishes.")
        let next = try #require(store.runtimeOperations.beginLimitsChange("next"))
        store.runtimeOperations.endLimitsChange(next)
    }

    @MainActor @Test func runActivityUsesTheSameCredentialMaskingAsInspect() async throws {
        let client = ActivityCredentialClient()
        let store = AppStore(client: client)
        let request = try ContainerLaunchRequestBuilder.makeRequest(configuration: .init(image: "alpine:latest", command: "server --api-key=activity-secret --auth inspect-secret"))
        _ = try await store.execute(request, title: "Run")
        let preview = try #require(store.operations.first?.commandPreview)
        #expect(!preview.contains("activity-secret") && !preview.contains("inspect-secret"))
        #expect(await client.arguments == request.arguments)
    }

    @MainActor @Test func processBoundaryRejectsBlockedLaunchAndFailedResolutionReleasesAdmission() async throws {
        _ = NativeTestApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("launched")
        let executable = folder.appendingPathComponent("container")
        try "#!/bin/sh\nprintf launched >> '\(marker.path)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let policy = RuntimeOperationPolicy()
        let token = try #require(policy.beginLimitsChange("web"))
        // Embed the terminal directly, bypassing ResourceDetailPane's UI guard.
        for arguments in [["exec", "web", "sh"], ["machine", "run", "--name", "fixture"]] {
            let host = NSHostingView(rootView: ContainerTerminalView(arguments: arguments, runtimeOperations: policy, executablePath: executable.path))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            window.contentView = nil
            window.close()
        }
        policy.endLimitsChange(token)
        let missing = NSHostingView(rootView: ContainerTerminalView(arguments: ["exec", "web", "sh"], runtimeOperations: policy, executablePath: folder.appendingPathComponent("missing").path))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = missing
        defer { window.contentView = nil; window.close() }
        missing.layoutSubtreeIfNeeded()
        let next = try #require(policy.beginLimitsChange("next"))
        policy.endLimitsChange(next)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

private actor ActivityCredentialClient: ContainerClient {
    private(set) var arguments: [String] = []
    func run(_ request: CommandRequest) async throws -> CommandResult {
        arguments = request.arguments
        return .init(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> { AsyncThrowingStream { $0.finish() } }
}
