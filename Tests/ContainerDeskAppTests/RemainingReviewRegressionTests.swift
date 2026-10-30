import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct RemainingReviewRegressionTests {
    @MainActor @Test func limitsLeaseRejectsMutationsAtBothExecutionEntrypointsAndReleases() async throws {
        let client = ReviewCommandClient()
        let store = AppStore(client: client)
        let token = try #require(store.runtimeOperations.beginLimitsChange("web"))
        for args in [["system", "stop"], ["delete", "--", "web"], ["stop", "--all"], ["exec", "web", "sh"], ["image", "prune"]] {
            await #expect(throws: RuntimeOperationError.self) { try await store.execute(.init(arguments: args), title: "Conflicting mutation") }
            let stream = store.streamWithID(.init(arguments: args), title: "Advanced mutation")
            await #expect(throws: RuntimeOperationError.self) { for try await _ in stream.events {} }
            #expect(store.operations.first(where: { $0.id == stream.operationID })?.state == .failed)
        }
        #expect(await client.requests().isEmpty)
        _ = try await store.execute(.init(arguments: ["system", "status"]), title: "Read during limits")
        #expect(await client.requests() == [["system", "status"]])
        store.runtimeOperations.endLimitsChange(UUID())
        #expect(store.limitsOperationContainerID == "web")
        store.runtimeOperations.endLimitsChange(token)
        _ = try await store.execute(.init(arguments: ["system", "stop"]), title: "Stop after limits")
        #expect(store.runtimeOperations.beginLimitsChange("next") != nil)
    }

    @MainActor @Test func queuedMutationPreventsLimitsAcquisitionAndFailureReleasesIt() async throws {
        let client = ReviewCommandClient(hold: true)
        let store = AppStore(client: client)
        let stream = store.streamWithID(.init(arguments: ["stop", "web"]), title: "Queued stop")
        #expect(store.runtimeOperations.beginLimitsChange("web") == nil)
        let consuming = Task { do { for try await _ in stream.events {} } catch {} }
        while await client.requests().isEmpty { await Task.yield() }
        await client.finish(exitCode: 1)
        await consuming.value
        #expect(store.runtimeOperations.beginLimitsChange("web") != nil)
    }

    @MainActor @Test func reviewedActionsRejectChangedRuntimeBeforeAndBetweenPhases() async throws {
        let suite = "ReviewRuntime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ReviewCommandClient(hold: true)
        let store = AppStore(client: client, defaults: defaults)
        let runtime = store.captureReviewedRuntime()
        let stop = Task { try await store.execute(.init(arguments: ["stop", "--", "web"]), title: "Restart stop", reviewedRuntime: runtime) }
        while await client.requests().isEmpty { await Task.yield() }
        store.cliPath = "/missing/changed-runtime"
        await client.finish()
        _ = try await stop.value
        for args in [["start", "--", "web"], ["delete", "--", "web"], ["image", "push", "reviewed-tag"]] {
            await #expect(throws: RuntimeOperationError.self) { try await store.execute(.init(arguments: args), title: "Stale review", reviewedRuntime: runtime) }
        }
        #expect(await client.requests() == [["stop", "--", "web"]])
    }

    @MainActor @Test func staleLibraryWritersPreserveUnrelatedProjectsAndRememberedClusters() throws {
        let suite = "ReviewLibrary.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PluginLibraryStore(defaults: defaults)
        let second = PluginLibraryStore(defaults: defaults)
        let a = first.addProject(URL(fileURLWithPath: "/tmp/a.yaml"), name: "A")
        let b = second.addProject(URL(fileURLWithPath: "/tmp/b.yaml"), name: "B")
        first.renameProject(id: a.id, name: "renamed")
        #expect(Set(first.projects.map(\.id)) == [a.id, b.id])
        second.forgetProject(id: b.id)
        let reopened = PluginLibraryStore(defaults: defaults)
        #expect(reopened.projects.map(\.name) == ["renamed"])
        first.rememberCluster("one")
        second.rememberCluster("two")
        first.forgetCluster("one")
        #expect(PluginLibraryStore(defaults: defaults).clusterNames == ["two"])
        #expect(first.projects.first(where: { $0.id == a.id })?.name == "renamed", "Renaming must preserve selection identity.")
    }

    @Test func registryAndOtherUnsupportedSectionsNeverBuildAnInspectCommand() {
        for section in ContainerSection.allCases {
            let args = ResourceActionRouting.inspectionArguments(section: section, target: "--option-shaped")
            if [.containers, .images, .volumes, .networks, .machines].contains(section) {
                #expect(args?.suffix(2) == ["--", "--option-shaped"])
            } else {
                #expect(args == nil)
                #expect(!ResourceDetailTab.available(for: section).contains(.inspect))
                #expect(!ResourceActionRouting.supportsInspect(section))
            }
        }
    }

    @MainActor @Test func kubernetesFailureAndSuccessReleaseOwnershipAndPrecancelledWorkNeverStarts() async throws {
        let store = AppStore(client: ReviewCommandClient())
        let owner = UUID()
        #expect(await store.kubernetesOperations.run(.init(arguments: ["k8s", "create"]), title: "Success", store: store, owner: owner))
        #expect(!store.kubernetesOperations.isRunning && store.kubernetesOperations.owner == nil)
        let client = ReviewCommandClient(hold: true)
        let failedStore = AppStore(client: client)
        let failed = Task { await failedStore.kubernetesOperations.run(.init(arguments: ["k8s", "write-config"]), title: "Failure", store: failedStore, owner: owner) }
        while await client.requests().isEmpty { await Task.yield() }
        await client.finish(exitCode: 1)
        #expect(await failed.value == false)
        #expect(!failedStore.kubernetesOperations.isRunning && failedStore.kubernetesOperations.operationID == nil)
        #expect(failedStore.kubernetesOperations.error != nil)
        let cancelled = Task { await store.kubernetesOperations.run(.init(arguments: ["k8s", "delete"]), title: "Cancelled before launch", store: store, owner: owner) }
        cancelled.cancel()
        #expect(await cancelled.value == false)
        #expect(store.operations.count == 1)
    }

    @MainActor @Test(arguments: ["create", "delete", "load-image", "write-config"])
    func kubernetesSerializesEveryMutationAndOnlyItsOwnerCanCancel(_ command: String) async throws {
        let client = ReviewCommandClient(hold: true)
        let store = AppStore(client: client)
        let operation = store.kubernetesOperations
        let owner = UUID()
        let first = Task { await operation.run(.init(arguments: ["k8s", command]), title: command, store: store, owner: owner) }
        while await client.requests().isEmpty { await Task.yield() }
        let id = try #require(operation.operationID)
        #expect(await operation.run(.init(arguments: ["k8s", "write-config"]), title: "Overlap", store: store, owner: UUID()) == false)
        operation.cancel(owner: UUID())
        #expect(operation.isRunning && operation.operationID == id)
        operation.cancel(owner: owner)
        #expect(await first.value == false)
        #expect(!operation.isRunning && operation.operationID == nil)
        #expect(await client.requests().count == 1)
        #expect(store.operations.first(where: { $0.id == id })?.state == .cancelled)
        await client.finish()
    }
}

private actor ReviewCommandClient: ContainerClient {
    let hold: Bool
    private var recorded: [[String]] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var streamContinuations: [UUID: AsyncThrowingStream<CommandEvent, Error>.Continuation] = [:]
    private var code: Int32 = 0
    init(hold: Bool = false) { self.hold = hold }
    func requests() -> [[String]] { recorded }
    func run(_ request: CommandRequest) async throws -> CommandResult {
        recorded.append(request.arguments)
        if hold { await withCheckedContinuation { waiter = $0 } }
        return result
    }
    private var result: CommandResult { .init(standardOutput: "", standardError: "", exitCode: code, terminationReason: .exit, duration: .zero) }
    func finish(exitCode: Int32 = 0) {
        code = exitCode
        waiter?.resume(); waiter = nil
        for continuation in streamContinuations.values { continuation.yield(.completed(result)); continuation.finish() }
        streamContinuations.removeAll()
    }
    private func install(_ continuation: AsyncThrowingStream<CommandEvent, Error>.Continuation, id: UUID, request: CommandRequest) {
        recorded.append(request.arguments)
        if hold { streamContinuations[id] = continuation }
        else { continuation.yield(.completed(result)); continuation.finish() }
    }
    private func remove(_ id: UUID) { streamContinuations[id] = nil }
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in Task { await self.remove(id) } }
            Task { await install(continuation, id: id, request: request) }
        }
    }
}
