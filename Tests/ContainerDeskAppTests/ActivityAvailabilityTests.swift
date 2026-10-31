import AppKit
import ApplicationServices
import ContainerDeskCore
import ObjectiveC
import SwiftUI
import Testing
@testable import ContainerDeskApp

struct ActivityAvailabilityTests {
    @MainActor @Test(arguments: [false, true])
    func failedCLIHelpKeepsActivityRecordsAndCancellationReachable(missingExecutable: Bool) async throws {
        _ = NativeTestApplication.shared
        let client = ActivityUnavailableCLI()
        let suite = "ActivityAvailability.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(client: client, defaults: defaults)
        _ = try await store.execute(.init(arguments: ["logs", "fixture"]), title: "Recorded operation")
        let active = Task { _ = try? await store.execute(.init(arguments: ["build", "/fixture"]), title: "Still running") }
        defer { active.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await client.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await client.started)
        if missingExecutable { store.cliPath = "/missing/ContainerDesk-activity-\(UUID())" }
        await store.refreshCapabilities()
        if case .available = store.capability(for: .activity) { } else {
            Issue.record("Activity is local metadata and must stay available when CLI help fails.")
        }
        let mlx = MLXStore(service: ActivityUnusedMLXService(), defaults: defaults)
        let host = NSHostingView(rootView: FeatureRootView(section: .activity, store: store, mlxStore: mlx,
            externalMLXStore: ExternalMLXStore(), sceneID: "activity-fixture",
            navigationPerformance: NavigationPerformanceTracker(enabled: false), resourceStates: ResourceFeatureStateCache(),
            selectedWorkspaceID: .constant("")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await wait(host) { tables(host).contains { $0.numberOfRows == 2 } }
        let table = try #require(tables(host).first { $0.numberOfRows == 2 })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await wait(host) { nodes(host).contains { text($0).contains("Cancel") } }
        let button = try #require(nodes(host).first { text($0) == "Cancel" })
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let method = try #require(class_getInstanceMethod(type(of: button), selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> ObjCBool
        let press = unsafeBitCast(method_getImplementation(method), to: Press.self)
        #expect(press(button, selector).boolValue)
        await active.value
        #expect(await client.cancelled)
        #expect(store.operations.first?.state == .cancelled)
        #expect(store.operations.contains { $0.title == "Recorded operation" && $0.state == .succeeded })
    }

    @MainActor private func wait(_ host: NSView, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }
    @MainActor private func tables(_ view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables($0) }
    }
    @MainActor private func nodes(_ value: Any) -> [NSObject] {
        guard let value = value as? NSObject else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        guard value.responds(to: selector), let children = value.perform(selector)?.takeUnretainedValue() as? [Any] else { return [value] }
        return [value] + children.flatMap { nodes($0) }
    }
    @MainActor private func text(_ object: NSObject) -> String {
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector), let text = object.perform(selector)?.takeUnretainedValue() as? String, !text.isEmpty { return text }
        }
        return ""
    }
}

private actor ActivityUnavailableCLI: ContainerClient {
    private(set) var started = false
    private(set) var cancelled = false
    func run(_ request: CommandRequest) async throws -> CommandResult {
        if request.arguments.first == "build" {
            started = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
        }
        return .init(standardOutput: "", standardError: "", exitCode: request.arguments == ["--help"] ? 1 : 0, terminationReason: .exit, duration: .zero)
    }
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> { AsyncThrowingStream { $0.finish() } }
}

private actor ActivityUnusedMLXService: MLXModelService {
    func configure(_ configuration: MLXConfiguration) {}
    func capability() -> MLXCapability { .init(available: false) }
    func listLocalModels() -> [MLXModelRecord] { [] }
    func validateModelDirectory(_ url: URL) throws -> MLXModelRecord { throw MLXError.operationFailed("Unused") }
    func download(_ request: MLXModelDownloadRequest) -> AsyncThrowingStream<MLXDownloadEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func startServer(modelID: String, options: MLXServerOptions) throws -> MLXServerSession { throw MLXError.operationFailed("Unused") }
    func stopServer(id: UUID) {}
    func serverEvents(id: UUID) -> AsyncStream<MLXServerEvent> { AsyncStream { $0.finish() } }
    func ownedServers() -> [MLXServerSession] { [] }
    func trashManagedModel(id: String) {}
    func forgetImportedModel(at url: URL) {}
    func chat(serverID: UUID, messages: [MLXChatMessage], options: MLXChatOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func stopAllOwnedServers() {}
    func shutdown() {}
}
