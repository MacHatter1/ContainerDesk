import AppKit
import ContainerDeskCore
import Darwin
import SwiftTerm
import SwiftUI
import Testing
@testable import ContainerDeskApp

@Suite(.serialized)
struct ReviewFollowupAppTests {
    @Test func resourceFormsTrimStructuredValuesWithoutChangingPasswordsOrAssignments() throws {
        let machine = ResourceCreationForm(name: "  web \n", image: " alpine:latest \n", cpuText: " 2 ", memoryText: " 1G ")
        #expect(try machine.request(for: .machines).arguments == ["machine", "create", "--name", "web", "--cpus", "2", "--memory", "1G", "alpine:latest"])
        let image = ResourceCreationForm(image: " alpine:latest ", platform: " linux/arm64 ")
        #expect(try image.request(for: .images).arguments == ["image", "pull", "--platform", "linux/arm64", "alpine:latest"])
        let volume = ResourceCreationForm(name: " data ", size: " 10G ", optionsText: "  setting= keep both spaces \n\n")
        #expect(try volume.request(for: .volumes).arguments == ["volume", "create", "-s", "10G", "--opt", "setting= keep both spaces ", "data"])
        let login = try ResourceCreationForm(name: " registry.example ", username: " alice ", password: " secret ").request(for: .registries)
        #expect(String(decoding: login.stdin ?? Data(), as: UTF8.self).contains(" secret "))
        #expect(login.arguments.contains("alice") && !login.arguments.contains(" alice "))
        #expect(throws: FeatureCommandError.self) { try ResourceCreationForm(name: " \n ").request(for: .volumes) }
    }

    @Test func advancedStructuredFlagsAreTrimmedAndLiteralAssignmentValuesArePreserved() throws {
        let spec = try #require(AdvancedCommandCatalog.specs(for: .builds).first { $0.id == "build" })
        let request = try AdvancedCommandRequestBuilder.make(section: .builds, spec: spec, flags: [], values: ["cpus": " 2 ", "memory": " 1G ", "build-arg": "TEXT= keep spaces "], positionalArguments: ["/tmp/context"])
        #expect(request.arguments.contains("2") && request.arguments.contains("1G"))
        #expect(request.arguments.contains("TEXT= keep spaces "))
        #expect(!request.arguments.contains(" 2 "))
    }

    @Test func advancedPositionalsTrimIDsAndPreserveQuotedCommandsAndPaths() throws {
        let exec = try #require(AdvancedCommandCatalog.specs(for: .containers).first { $0.id == "exec" })
        #expect(try AdvancedCommandRequestBuilder.positionals(for: exec, input: [" web ", #"grep "\d+" " keep spaces ""#]) == ["web", "grep", #"\d+"#, " keep spaces "])
        let copy = try #require(AdvancedCommandCatalog.specs(for: .containers).first { $0.id == "copy" })
        #expect(try AdvancedCommandRequestBuilder.positionals(for: copy, input: ["/tmp/file ", "web:/tmp/"]) == ["/tmp/file ", "web:/tmp/"])
    }

    @MainActor @Test func failedTerminalLaunchReportsFailureAndCannotBeReused() throws {
        _ = NativeTestApplication.shared
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let session = ContainerTerminalSession()
        var notified = false
        let coordinator = ContainerTerminalView.Coordinator(onExit: { exitCode in notified = true; #expect(exitCode == nil) })
        coordinator.session = session
        let configuration = ContainerTerminalSession.Configuration(runtimeOperations: RuntimeOperationPolicy(), arguments: [], executablePath: "/missing", environment: [:], currentDirectory: nil)
        session.retain(terminal, configuration: configuration, coordinator: coordinator)
        coordinator.processFailedToStart(source: terminal, error: .forkFailed(EAGAIN))
        #expect(notified)
        let output = String(decoding: terminal.getBufferAsData(encoding: .utf8), as: UTF8.self)
        #expect(output.contains("Session could not start"))
        #expect(session.reuse(configuration: configuration, coordinator: coordinator) == nil)
    }

    @MainActor @Test func kubernetesRememberedNamesUseSingleSelection() async throws {
        _ = NativeTestApplication.shared
        let suite = "KubernetesSelection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(client: FollowupListClient(), defaults: defaults)
        store.pluginLibrary.rememberCluster("one")
        store.pluginLibrary.rememberCluster("two")
        let host = NSHostingView(rootView: KubernetesFeatureView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        while findTable(host) == nil, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let table = try #require(findTable(host))
        #expect(!table.allowsMultipleSelection)
    }

    @MainActor @Test func recoveryRemovalAndLimitsOrRuntimeMutationsCannotOverlap() throws {
        let policy = RuntimeOperationPolicy()
        let limits = try #require(policy.beginLimitsChange("web"))
        #expect(policy.beginRecoveryCleanup() == nil)
        policy.endLimitsChange(limits)
        let cleanup = try #require(policy.beginRecoveryCleanup())
        #expect(policy.beginLimitsChange("web") == nil)
        #expect(throws: RuntimeOperationError.self) { try policy.beginCommand(.init(arguments: ["delete", "web"])) }
        #expect(try policy.beginCommand(.init(arguments: ["list", "--all"])) == nil)
        policy.endRecoveryCleanup(UUID())
        #expect(policy.isRecoveryCleanupInProgress)
        policy.endRecoveryCleanup(cleanup)
        #expect(policy.beginLimitsChange("web") != nil)
    }

    @MainActor private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
    }
}

private struct FollowupListClient: ContainerClient {
    func run(_ request: CommandRequest) async throws -> CommandResult { .init(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero) }
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        .init { continuation in
            continuation.yield(.completed(.init(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)))
            continuation.finish()
        }
    }
}
