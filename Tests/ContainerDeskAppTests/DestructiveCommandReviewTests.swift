import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct DestructiveCommandReviewTests {
    @MainActor @Test func advancedConfirmationExecutesReviewedTargetsAndFlags() async throws {
        let client = DestructiveReviewClient()
        let store = AppStore(client: client)
        let spec = try #require(AdvancedCommandCatalog.specs(for: .containers).first { $0.id == "delete" })
        var targets = ["reviewed-container"]
        var flags: Set<String> = ["force"]
        let review = try AdvancedCommandReview(section: .containers, spec: spec, flags: flags, values: [:], positionals: targets, runtime: store.captureReviewedRuntime())
        targets = ["other-container"]
        flags = ["all"]

        let operation = try store.streamWithID(review.request, title: review.title, reviewedRuntime: review.runtime)
        for try await _ in operation.events {}
        #expect(review.confirmationTitle.contains("reviewed-container"))
        #expect(!review.confirmationTitle.contains("all containers"))
        #expect(review.confirmationMessage.contains("reviewed-container"))
        #expect(await client.requests().map(\.arguments) == [["delete", "--force", "--", "reviewed-container"]])
        #expect(targets == ["other-container"] && flags == ["all"])
    }

    @MainActor @Test func advancedAllScopeReviewStaysAllScope() async throws {
        let client = DestructiveReviewClient()
        let store = AppStore(client: client)
        let spec = try #require(AdvancedCommandCatalog.specs(for: .images).first { $0.id == "delete" })
        let review = try AdvancedCommandReview(section: .images, spec: spec, flags: ["all"], values: [:], positionals: [], runtime: store.captureReviewedRuntime())
        let operation = try store.streamWithID(review.request, title: review.title, reviewedRuntime: review.runtime)
        for try await _ in operation.events {}
        #expect(review.confirmationTitle == "Delete all local images?")
        #expect(await client.requests().map(\.arguments) == [["image", "delete", "--all"]])
    }

    @MainActor @Test func composeConfirmationExecutesReviewedFileNameAndNetworkChoice() async throws {
        let client = DestructiveReviewClient()
        let store = AppStore(client: client)
        var project = SavedComposeProject(fileURL: URL(fileURLWithPath: "/tmp/reviewed/compose.yaml"), name: "reviewed")
        var keepNetworks = true
        let review = ComposeDownReview(project: project, keepNetworks: keepNetworks, runtime: store.captureReviewedRuntime())
        project.fileURL = URL(fileURLWithPath: "/tmp/other/compose.yaml")
        project.name = "other"
        keepNetworks = false

        let operation = try store.streamWithID(review.request, title: "Compose Down", reviewedRuntime: review.runtime)
        for try await _ in operation.events {}
        let request = try #require(await client.requests().first)
        #expect(request.arguments == ["compose", "down", "--file", "/tmp/reviewed/compose.yaml", "--project-name", "reviewed", "--keep-networks"])
        #expect(request.workingDirectory?.path == "/tmp/reviewed")
        #expect(review.displayName == "reviewed" && review.keepNetworks)
        #expect(project.name == "other" && !keepNetworks)
    }

    @MainActor @Test(arguments: [false, true])
    func staleStreamReviewsRejectChangedCLIWithoutLaunchingOrRecording(_ restoreOriginalPath: Bool) async throws {
        let suite = "DestructiveCommandReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DestructiveReviewClient()
        let store = AppStore(client: client, defaults: defaults)
        let runtime = store.captureReviewedRuntime()
        let spec = try #require(AdvancedCommandCatalog.specs(for: .containers).first { $0.id == "delete" })
        let advanced = try AdvancedCommandReview(section: .containers, spec: spec, flags: ["all"], values: [:], positionals: [], runtime: runtime)
        let compose = ComposeDownReview(project: .init(fileURL: URL(fileURLWithPath: "/tmp/compose.yaml"), name: "reviewed"), keepNetworks: false, runtime: runtime)
        let kubernetes = KubernetesDeleteReview(name: "reviewed", runtime: runtime)
        store.cliPath = "/missing/unreviewed-container-\(UUID())"
        if restoreOriginalPath { store.cliPath = nil }

        for request in [advanced.request, compose.request] {
            #expect(throws: RuntimeOperationError.self) {
                try store.streamWithID(request, title: "Stale review", reviewedRuntime: runtime)
            }
        }
        #expect(await store.kubernetesOperations.run(kubernetes.request, title: "Stale Kubernetes review", store: store, owner: UUID(), reviewedRuntime: kubernetes.runtime) == false)
        #expect(store.kubernetesOperations.error != nil)
        #expect(!store.kubernetesOperations.isRunning && store.kubernetesOperations.owner == nil)
        #expect(await client.requests().isEmpty)
        #expect(store.operations.isEmpty)
        let lease = try #require(store.runtimeOperations.beginLimitsChange("available"))
        store.runtimeOperations.endLimitsChange(lease)
    }

    @MainActor @Test func queuedReviewedStreamUsesCapturedClientAndKubernetesName() async throws {
        let suite = "DestructiveCommandReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DestructiveReviewClient()
        let store = AppStore(client: client, defaults: defaults)
        var name = "reviewed-cluster"
        let review = KubernetesDeleteReview(name: name, runtime: store.captureReviewedRuntime())
        name = "other-cluster"
        let operation = try store.streamWithID(review.request, title: "Delete Kubernetes Cluster", reviewedRuntime: review.runtime)
        store.cliPath = "/missing/unreviewed-container-\(UUID())"
        for try await _ in operation.events {}
        #expect(await client.requests().map(\.arguments) == [["k8s", "delete", "--name", "reviewed-cluster"]])
        #expect(store.operations.first(where: { $0.id == operation.operationID })?.state == .succeeded)
        #expect(name == "other-cluster")
    }

    @MainActor @Test func kubernetesDeleteExecutesWithItsReviewedRuntime() async {
        let client = DestructiveReviewClient()
        let store = AppStore(client: client)
        let review = KubernetesDeleteReview(name: "reviewed-cluster", runtime: store.captureReviewedRuntime())
        #expect(await store.kubernetesOperations.run(review.request, title: "Delete Kubernetes Cluster", store: store, owner: UUID(), reviewedRuntime: review.runtime))
        #expect(await client.requests().map(\.arguments) == [["k8s", "delete", "--name", "reviewed-cluster"]])
        #expect(!store.kubernetesOperations.isRunning && store.kubernetesOperations.owner == nil)
    }
}

private actor DestructiveReviewClient: ContainerClient {
    private var recorded: [CommandRequest] = []
    func requests() -> [CommandRequest] { recorded }
    func run(_ request: CommandRequest) async -> CommandResult {
        recorded.append(request)
        return Self.result
    }
    private static var result: CommandResult { .init(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero) }
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let result = await run(request)
                continuation.yield(.completed(result))
                continuation.finish()
            }
        }
    }
}
