import AppKit
import ContainerDeskCore
import Foundation
import Observation
import SwiftUI
import Testing
@testable import ContainerDeskApp

struct RemainingReviewAppTests {
    @MainActor @Test func logsStartAfterAFailedInventoryRecoversWithIdenticalRetainedIDs() async throws {
        _ = NativeTestApplication.shared
        let suite = "RemainingReview.logs.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/fixture/container", forKey: "containerDesk.cliPath")
        let client = RecoveringLogsClient()
        let store = AppStore(client: client, defaults: defaults)
        await store.refresh(.containers)
        await client.failLists(true)
        await store.refresh(.containers, force: true)
        #expect(store.snapshots[.containers]?.items.map(\.id) == ["web"])
        let host = NSHostingView(rootView: UnifiedLogsFeatureView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let initialDeadline = ContinuousClock.now + .seconds(5)
        while await client.listCalls < 3, ContinuousClock.now < initialDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await client.listCalls >= 3)
        #expect(await client.logIDs.isEmpty)
        await client.failLists(false)
        await store.refresh(.containers, force: true)
        let deadline = ContinuousClock.now + .seconds(5)
        while await client.logIDs.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await client.logIDs == ["web"], "Recovering load state must start sources even when retained IDs do not change.")
    }
    @Test func emptyInitialLogSourcesRecoverWithoutUndoingUserDeselection() {
        var selection = LogSourceSelection()
        selection.observeInventory([], loaded: false)
        selection.observeInventory([], loaded: true)
        // A failed read may retain stale IDs. A successful read with those same
        // IDs must still choose initial sources when only its load state changes.
        selection.observeInventory(["web"], loaded: false)
        #expect(selection.ids.isEmpty)
        selection.observeInventory(["web"], loaded: true)
        #expect(selection.ids == ["web"])
        selection.select([])
        selection.observeInventory(["web", "db"], loaded: true)
        #expect(selection.ids.isEmpty)
        var explicitEmpty = LogSourceSelection()
        explicitEmpty.select([])
        explicitEmpty.observeInventory(["later"], loaded: true)
        #expect(explicitEmpty.ids.isEmpty)
    }

    @MainActor @Test func aNewSystemTabLoadsWhileAnOlderReadIsBlockedAndRejectsItsLateResult() async throws {
        let panel = SystemPanelStore()
        var waiting: CheckedContinuation<CommandResult, Never>?
        let first = Task { await panel.load(tab: "Disk Usage") { _, _ in
            await withCheckedContinuation { waiting = $0 }
        } }
        let deadline = ContinuousClock.now + .seconds(2)
        while waiting == nil, ContinuousClock.now < deadline { await Task.yield() }
        let held = try #require(waiting)
        await panel.load(tab: "Properties") { _, _ in self.result("properties") }
        #expect(panel.output == "properties" && !panel.isLoading)
        held.resume(returning: result("invalid disk JSON"))
        await first.value
        #expect(panel.output == "properties" && panel.error == nil && !panel.isLoading)
        await panel.load(tab: "DNS Domains") { _, _ in self.result("domains") }
        #expect(panel.output == "domains")
        await panel.load(tab: "System Logs") { _, _ in self.result("") }
        #expect(panel.output == "No recent service logs.")
    }

    @MainActor @Test func identicalPollsInvalidateOnlyTheUpdatedLabel() async throws {
        let suite = "RemainingReview.poll.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/fixture/container", forKey: "containerDesk.cliPath")
        let store = AppStore(client: RemainingReviewClient(), defaults: defaults)
        await store.refresh(.containers)
        let state = ResourceFeatureState()
        let view = ResourceFeatureView(section: .containers, store: store, sceneID: "test", activation: ResourceFeatureActivation(isActive: true), state: state)
        let parentChanged = ReviewObservationFlag()
        withObservationTracking { _ = view.body } onChange: { parentChanged.set() }
        let labelChanged = ReviewObservationFlag()
        withObservationTracking { _ = ResourceUpdatedLabel(store: store, section: .containers, fallback: nil).body } onChange: { labelChanged.set() }
        await store.refresh(.containers, force: true)
        #expect(!parentChanged.value)
        #expect(labelChanged.value)
        state.query = "positive control"
        #expect(parentChanged.value, "The parent observation must actually track table/filter dependencies.")
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func quitRecoveryWaitHasADeadlineAndCanBeCancelledOrComplete() async {
        let timedOut = await LimitsQuitWaiter.wait(timeout: .milliseconds(20)) { true }
        #expect(timedOut == .timedOut)
        let ready = await LimitsQuitWaiter.wait { false }
        #expect(ready == .ready)
        let waiting = Task { await LimitsQuitWaiter.wait { true } }
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
    }

    @MainActor @Test func corruptLibraryRecoveryBacksUpBeforeResetAndOnlyChangesItsOwnCollection() throws {
        let suite = "RemainingReview.library.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set("[\"kept\"]", forKey: PluginLibraryKind.kubernetes.key)
        defaults.set(["wrong": "type"], forKey: PluginLibraryKind.compose.key)
        let library = PluginLibraryStore(defaults: defaults)
        let review = try library.recoveryReview(.compose)
        let backup = try library.recover(review, backupDirectory: root)
        let data = try Data(contentsOf: backup)
        let archive = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect((archive?["value"] as? [String: String]) == ["wrong": "type"])
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(library.projects.isEmpty && library.error(for: .compose) == nil)
        #expect(library.clusterNames == ["kept"])
        _ = library.addProject(URL(fileURLWithPath: "/tmp/new.yaml"), name: "working")
        #expect(library.projects.count == 1)
    }

    @MainActor @Test func failedOrStaleLibraryRecoveryPreservesSavedDataAndRepairedImportReopensWrites() throws {
        let suite = "RemainingReview.import.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryImport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set("broken", forKey: PluginLibraryKind.kubernetes.key)
        let library = PluginLibraryStore(defaults: defaults)
        let old = try library.recoveryReview(.kubernetes)
        defaults.set("new broken", forKey: PluginLibraryKind.kubernetes.key)
        #expect(throws: (any Error).self) { try library.recover(old, backupDirectory: root) }
        let review = try library.recoveryReview(.kubernetes)
        #expect(throws: (any Error).self) { try library.recover(review, repairedJSON: Data("bad JSON".utf8), backupDirectory: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        #expect(throws: (any Error).self) { try library.recover(review, backupDirectory: blocker) }
        #expect(defaults.string(forKey: PluginLibraryKind.kubernetes.key) == "new broken")
        _ = try library.recover(review, repairedJSON: Data("[\"restored\"]".utf8), backupDirectory: root)
        library.rememberCluster("next")
        #expect(library.clusterNames == ["restored", "next"])
        defaults.set("[\"externally repaired\"]", forKey: PluginLibraryKind.kubernetes.key)
        library.retry(.kubernetes)
        #expect(library.clusterNames == ["externally repaired"])
    }

    private func result(_ text: String) -> CommandResult {
        .init(standardOutput: text, standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }
}

private final class ReviewObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func set() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

private struct RemainingReviewClient: ContainerClient {
    func run(_ request: CommandRequest) async throws -> CommandResult { .init(standardOutput: "[]", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero) }
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> { .init { $0.finish() } }
}

private actor RecoveringLogsClient: ContainerClient {
    private var failing = false
    private(set) var listCalls = 0
    private(set) var logIDs = Set<String>()
    func failLists(_ enabled: Bool) { failing = enabled }
    func run(_ request: CommandRequest) async throws -> CommandResult {
        listCalls += 1
        return .init(standardOutput: failing ? "" : #"[{"id":"web","status":{"state":"running"}}]"#, standardError: failing ? "Unavailable" : "", exitCode: failing ? 1 : 0, terminationReason: .exit, duration: .zero)
    }
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        .init { continuation in
            Task { await self.record(request.arguments.last ?? ""); continuation.finish() }
        }
    }
    private func record(_ id: String) { logIDs.insert(id) }
}
