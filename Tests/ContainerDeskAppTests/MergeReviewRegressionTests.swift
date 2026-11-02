import ContainerDeskCore
import Foundation
import Observation
import SwiftUI
import Testing
@testable import ContainerDeskApp

struct MergeReviewAppRegressionTests {
    @MainActor @Test(arguments: [false, true])
    func administrativeActionsKeepOwnershipThroughRefresh(fails: Bool) async throws {
        let actions = SystemActionStore()
        var refresh: CheckedContinuation<Void, Never>?
        var submissions = 0
        let first = Task {
            await actions.perform {
                submissions += 1
                await withCheckedContinuation { refresh = $0 }
                if fails { throw CocoaError(.fileReadUnknown) }
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while refresh == nil, ContinuousClock.now < deadline { await Task.yield() }
        let heldRefresh = try #require(refresh)
        #expect(actions.isRunning)
        #expect(await actions.perform { submissions += 1 } == false)
        #expect(submissions == 1, "A second DNS/kernel action must not start during the first action's refresh.")
        heldRefresh.resume()
        #expect(await first.value == !fails)
        #expect(!actions.isRunning)
        #expect((actions.error != nil) == fails)
        #expect(await actions.perform { submissions += 1 })
        #expect(submissions == 2 && actions.error == nil)
    }

    @MainActor @Test func shutdownWaitsForBuildCallbacksAndRejectsTheirRefreshes() async throws {
        let client = ShutdownReviewClient()
        let store = AppStore(client: client)
        var callbackFinished = false
        let build = store.buildOperations
        build.start(.init(arguments: ["builder", "start"]), title: "Start builder", store: store) { _ in
            _ = try? await store.execute(.init(arguments: ["builder", "status"]), title: "Completion refresh")
            callbackFinished = true
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await client.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await client.started)
        await store.shutdown()
        #expect(!build.isRunning && callbackFinished, "Shutdown must join the operation owner, including its completion callback.")
        while !callbackFinished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await client.statusCalls == 0)
        await #expect(throws: (any Error).self) { try await store.execute(.init(arguments: ["list"]), title: "Late read") }
        let late = store.streamWithID(.init(arguments: ["build", "/fixture"]), title: "Late stream")
        await #expect(throws: (any Error).self) { for try await _ in late.events {} }
        await store.refresh(.containers, force: true)
        await store.refreshSystemVersion()
        await store.refreshCapabilities()
        #expect(await client.readCalls == 0)
        #expect(store.runtimeOperations.beginLimitsChange("web") == nil)
        #expect(store.runtimeOperations.beginRecoveryCleanup() == nil)
    }

    @Test(arguments: [
        (ContainerSection.containers, "run", "kernel"), (.containers, "run", "cidfile"),
        (.containers, "run", "workdir"), (.containers, "run", "masked-path"),
        (.containers, "run", "read-only-path"), (.containers, "exec", "workdir"),
        (.machines, "create", "kernel"), (.machines, "run", "workdir"),
        (.system, "kernel-set", "tar"), (.system, "start", "app-root"),
        (.system, "start", "install-root"), (.system, "start", "log-root")
    ])
    func advancedPathValuesKeepMeaningfulWhitespace(section: ContainerSection, command: String, flag: String) throws {
        let spec = try #require(AdvancedCommandCatalog.specs(for: section).first { $0.id == command })
        #expect(spec.flags.contains { $0.name == flag })
        let path = "/tmp/a path with trailing space "
        let request = try AdvancedCommandRequestBuilder.make(section: section, spec: spec, flags: [], values: [flag: path], positionalArguments: [])
        let index = try #require(request.arguments.firstIndex(of: "--" + flag))
        #expect(request.arguments[index + 1] == path)
    }

    @Test func localPathsExpandTildeWhileGuestPathsAndLiteralValuesRemainLiteral() throws {
        let spec = try #require(AdvancedCommandCatalog.specs(for: .containers).first { $0.id == "run" })
        let request = try AdvancedCommandRequestBuilder.make(section: .containers, spec: spec, flags: [], values: ["kernel": "~/kernel ", "workdir": "~/guest ", "kernel-arg": "literal argument ", "cpus": " 2 "], positionalArguments: [])
        #expect(request.arguments.contains(("~/kernel " as NSString).expandingTildeInPath))
        #expect(request.arguments.contains("~/guest "))
        #expect(request.arguments.contains("literal argument "))
        #expect(request.arguments.contains("2") && !request.arguments.contains(" 2 "))
    }

    @MainActor @Test func identicalContainerPollDoesNotInvalidateTheStacksParent() async throws {
        let suite = "MergeReview.Stacks.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/fixture/container", forKey: "containerDesk.cliPath")
        let client = StackPollClient()
        let store = AppStore(client: client, defaults: defaults)
        await store.refresh(.containers)
        let view = StackWorkspaceFeatureView(store: store, selectedWorkspaceID: .constant(""))
        let parentChanged = MergeObservationFlag()
        withObservationTracking { _ = view.body } onChange: { parentChanged.set() }
        let labelChanged = MergeObservationFlag()
        withObservationTracking { _ = ResourceUpdatedLabel(store: store, section: .containers, fallback: nil).body } onChange: { labelChanged.set() }
        await store.refresh(.containers, force: true)
        #expect(!parentChanged.value)
        #expect(labelChanged.value)
        await client.addContainer()
        await store.refresh(.containers, force: true)
        #expect(parentChanged.value, "A genuine inventory change must still invalidate Stacks.")
    }
}

private final class MergeObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func set() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

private actor StackPollClient: ContainerClient {
    private var payload = "[]"
    func addContainer() { payload = #"[{"id":"web","status":{"state":"stopped"}}]"# }
    func run(_ request: CommandRequest) async throws -> CommandResult { .init(standardOutput: payload, standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero) }
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> { .init { $0.finish() } }
}

private actor ShutdownReviewClient: ContainerClient {
    private(set) var started = false
    private(set) var statusCalls = 0
    private(set) var readCalls = 0
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        .init { continuation in
            let worker = Task {
                await self.didStart()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { }
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
    func run(_ request: CommandRequest) async throws -> CommandResult {
        readCalls += 1
        if request.arguments.starts(with: ["builder", "status"]) { statusCalls += 1 }
        return .init(standardOutput: "[]", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }
    private func didStart() { started = true }
}
