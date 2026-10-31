import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct ResourceActionOperationTests {
    @MainActor @Test func selectedActionsPreserveExactOptionLookingIDsAndRefresh() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let operation = ResourceActionOperation()
        let target = ResourceSummary(id: "--all", title: "Reviewed Web")
        for kind in [ResourceActionKind.start, .stop] {
            await fixture.client.reset()
            await operation.perform(review(kind, store: fixture.store, resources: [target]), using: fixture.store)
            #expect(await fixture.client.requests() == [[kind.rawValue, "--", "--all"], ["list", "--all", "--format", "json"]])
            #expect(operation.failure == nil)
            #expect(operation.notice?.message.contains("Reviewed Web") == true)
            #expect(operation.notice?.message.contains("--all") == true)
            #expect(operation.activeReview == nil)
        }
        #expect(fixture.store.snapshots[.containers]?.state == .loaded)
        operation.clearResult()
        #expect(operation.notice == nil)
        #expect(operation.failure == nil)
    }

    @MainActor @Test func stopAllUsesOnlyCapturedRunningIDsAndReportsPartialFailure() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let operation = ResourceActionOperation()
        let targets = [ResourceSummary(id: "first", title: "First", state: "running"), ResourceSummary(id: "--all", title: "Second", state: "running")]
        let plan = review(.stopAll, store: fixture.store, resources: targets)
        #expect(plan.requiresConfirmation)
        #expect(plan.confirmationMessage.contains("first"))
        #expect(plan.confirmationMessage.contains("--all"))
        #expect(plan.progressMessage.contains("2"))
        await operation.perform(plan, using: fixture.store)
        #expect(await fixture.client.requests() == [["stop", "--", "first", "--all"], ["list", "--all", "--format", "json"]])
        #expect(operation.notice?.message.contains("2") == true)

        await fixture.client.reset(failing: "stop")
        await operation.perform(plan, using: fixture.store)
        #expect(await fixture.client.requests() == [["stop", "--", "first", "--all"], ["list", "--all", "--format", "json"]])
        #expect(operation.notice == nil)
        #expect(operation.failure?.contains("may already have stopped") == true)
        #expect(operation.failure?.contains("Command refused") == true)
    }

    @MainActor @Test func restartOrdersStopBeforeStartAndRefreshesOnEitherFailure() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let operation = ResourceActionOperation()
        let plan = review(.restart, store: fixture.store)
        await operation.perform(plan, using: fixture.store)
        #expect(await fixture.client.requests() == [["stop", "--", "web"], ["start", "--", "web"], ["list", "--all", "--format", "json"]])
        #expect(operation.notice?.title == "Container Restarted")
        for failure in ["stop", "start"] {
            await fixture.client.reset(failing: failure)
            await operation.perform(plan, using: fixture.store)
            let mutations = await fixture.client.requests().filter { ["stop", "start"].contains($0.first ?? "") }
            #expect(mutations == (failure == "stop" ? [["stop", "--", "web"]] : [["stop", "--", "web"], ["start", "--", "web"]]))
            #expect(await fixture.client.requests().last == ["list", "--all", "--format", "json"])
            #expect(operation.notice == nil)
            #expect(operation.failure?.contains("Command refused") == true)
            if failure == "start" { #expect(operation.failure?.contains("was stopped") == true) }
        }
    }

    @MainActor @Test func staleRuntimeBetweenRestartPhasesPreventsStart() async throws {
        let fixture = try makeStore(holdFirst: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let operation = ResourceActionOperation()
        let plan = review(.restart, store: fixture.store)
        let task = Task { await operation.perform(plan, using: fixture.store) }
        defer { Task { await fixture.client.release() } }
        await fixture.client.waitUntilStarted()
        fixture.store.cliPath = "/missing/changed-container-cli"
        await fixture.client.release()
        await task.value
        #expect(await fixture.client.requests() == [["stop", "--", "web"]])
        #expect(operation.failure?.contains(RuntimeOperationError.runtimeChanged.localizedDescription) == true)
        #expect(operation.failure?.contains("was stopped") == true)
        #expect(operation.notice == nil)
        #expect(!operation.isRunning)
    }

    @MainActor @Test func deletionUsesSupportedPrefixesAndTypeSpecificConsequences() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let operation = ResourceActionOperation()
        let cases: [(ContainerSection, [String], String)] = [
            (.containers, ["delete"], "writable layer"), (.images, ["image", "delete"], "local image"),
            (.volumes, ["volume", "delete"], "permanently deleted"), (.networks, ["network", "delete"], "network configuration"),
            (.machines, ["machine", "delete"], "cannot be undone"),
        ]
        for (section, prefix, consequence) in cases {
            await fixture.client.reset()
            let plan = review(.delete, section: section, store: fixture.store, resources: [ResourceSummary(id: " --force ", title: "Reviewed")])
            #expect(plan.requiresConfirmation)
            #expect(plan.confirmationMessage.contains(consequence))
            #expect(plan.confirmationMessage.contains("Reviewed"))
            await operation.perform(plan, using: fixture.store)
            #expect(await fixture.client.requests().first == prefix + ["--", " --force "])
            #expect(operation.failure == nil)
            #expect(operation.notice != nil)
        }
    }

    @MainActor @Test func archiveActionsPreservePathsWithSpacesAndProtectedImageIDs() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let operation = ResourceActionOperation()
        let archive = URL(fileURLWithPath: "/tmp/archive directory/--all.tar")
        let load = review(.load, section: .images, store: fixture.store, resources: [], archiveURL: archive)
        #expect(!load.requiresConfirmation)
        #expect(load.progressMessage.contains("--all.tar"))
        await operation.perform(load, using: fixture.store)
        #expect(await fixture.client.requests().first == ["image", "load", "--input", archive.path])
        #expect(operation.notice?.title == "Image Archive Loaded")
        await fixture.client.reset()
        let save = review(.save, section: .images, store: fixture.store, resources: [ResourceSummary(id: "--all", title: "Reviewed Image")], archiveURL: archive)
        #expect(!save.requiresConfirmation)
        #expect(save.progressMessage.contains("Reviewed Image"))
        await operation.perform(save, using: fixture.store)
        #expect(await fixture.client.requests().first == ["image", "save", "--output", archive.path, "--", "--all"])
        #expect(operation.failure == nil)
        #expect(operation.notice?.title == "Image Archive Saved")
        await fixture.client.reset()
        let platformSave = review(.save, section: .images, store: fixture.store, resources: [
            ResourceSummary(id: "redis:7.2.4-alpine", title: "Redis", details: .init(platform: "linux/arm64/v8"))
        ], archiveURL: archive)
        await operation.perform(platformSave, using: fixture.store)
        #expect(await fixture.client.requests().first == ["image", "save", "--platform", "linux/arm64/v8", "--output", archive.path, "--", "redis:7.2.4-alpine"])
        #expect(operation.failure == nil)
    }

    @MainActor @Test func invalidScopesRuntimeAndLimitsRejectBeforeAnyCLI() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let operation = ResourceActionOperation()
        let target = ResourceSummary(id: "web", title: "Web", state: "running")
        let invalidPlans = [
            review(.stop, store: fixture.store, resources: []),
            review(.start, store: fixture.store, resources: [target, target]),
            review(.restart, section: .machines, store: fixture.store),
            review(.delete, section: .registries, store: fixture.store),
            review(.prune, section: .images, store: fixture.store),
            review(.stopAll, store: fixture.store, resources: []),
            review(.stopAll, store: fixture.store, resources: [target, target]),
            review(.stopAll, store: fixture.store, resources: [.init(id: "web", title: "Web", state: "stopped")]),
            review(.stop, store: fixture.store, resources: [.init(id: " \n", title: "Empty")]),
            review(.load, section: .images, store: fixture.store, resources: []),
            review(.save, section: .images, store: fixture.store),
            review(.load, section: .images, store: fixture.store, resources: [], archiveURL: URL(string: "https://example.com/image.tar")),
        ]
        for plan in invalidPlans {
            await operation.perform(plan, using: fixture.store)
            #expect(operation.failure != nil)
            #expect(operation.notice == nil)
        }
        let token = try #require(fixture.store.runtimeOperations.beginLimitsChange("other"))
        await operation.perform(review(.stop, store: fixture.store), using: fixture.store)
        #expect(operation.failure == RuntimeOperationError.limitsInProgress.localizedDescription)
        fixture.store.runtimeOperations.endLimitsChange(token)
        let stalePlan = review(.stop, store: fixture.store)
        fixture.store.cliPath = "/missing/changed-container-cli"
        await operation.perform(stalePlan, using: fixture.store)
        #expect(operation.failure == RuntimeOperationError.runtimeChanged.localizedDescription)
        #expect(await fixture.client.requests().isEmpty)
        #expect(fixture.store.operations.isEmpty)
    }

    @MainActor @Test func duplicateSubmissionRetainsFirstReviewAndOneCommand() async throws {
        let fixture = try makeStore(holdFirst: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let operation = ResourceActionOperation()
        let first = review(.stop, store: fixture.store)
        let task = Task { await operation.perform(first, using: fixture.store) }
        defer { Task { await fixture.client.release() } }
        await fixture.client.waitUntilStarted()
        #expect(operation.isRunning)
        #expect(operation.activeReview?.id == first.id)
        await operation.perform(review(.start, store: fixture.store), using: fixture.store)
        #expect(operation.activeReview?.id == first.id)
        #expect(await fixture.client.requests() == [["stop", "--", "web"]])
        await fixture.client.release()
        await task.value
        #expect(!operation.isRunning)
        #expect(operation.notice?.title == "Container Stopped")
    }

    @MainActor private func review(_ kind: ResourceActionKind, section: ContainerSection = .containers, store: AppStore, resources: [ResourceSummary] = [.init(id: "web", title: "Web")], archiveURL: URL? = nil) -> ResourceActionOperation.Review {
        .init(kind: kind, section: section, resources: resources, runtime: store.captureReviewedRuntime(), archiveURL: archiveURL)
    }

    @MainActor private func makeStore(holdFirst: Bool = false) throws -> (store: AppStore, client: ResourceActionTestClient, defaults: UserDefaults, suite: String) {
        let suite = "ResourceActionOperationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        // Disable native reads; every resource refresh stays on this injected mock.
        defaults.set("/missing/container-cli", forKey: "containerDesk.cliPath")
        let client = ResourceActionTestClient(holdFirst: holdFirst)
        return (AppStore(client: client, defaults: defaults), client, defaults, suite)
    }
}

private actor ResourceActionTestClient: ContainerClient {
    private let holdFirst: Bool
    private var recorded: [[String]] = []
    private var failing: String?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(holdFirst: Bool) { self.holdFirst = holdFirst }
    func requests() -> [[String]] { recorded }
    func reset(failing: String? = nil) { recorded = []; self.failing = failing }
    func waitUntilStarted() async {
        if !recorded.isEmpty { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        recorded.append(request.arguments)
        if recorded.count == 1 {
            startedWaiter?.resume()
            startedWaiter = nil
            if holdFirst { await withCheckedContinuation { releaseWaiter = $0 } }
        }
        let failed = request.arguments.first == failing
        return CommandResult(standardOutput: "[]", standardError: failed ? "Command refused" : "", exitCode: failed ? 1 : 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
