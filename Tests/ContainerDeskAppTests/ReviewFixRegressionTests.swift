import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct ReviewFixAppRegressionTests {
    @MainActor @Test func composeDownUsesSavedIdentityAndConfirmationSnapshot() {
        var project = SavedComposeProject(fileURL: URL(fileURLWithPath: "/tmp/staging/compose.yaml"), name: "staging")
        let review = ComposeDownReview(project: project, keepNetworks: true)
        project.name = "prod"
        #expect(review.request.arguments == ["compose", "down", "--file", "/tmp/staging/compose.yaml", "--project-name", "staging", "--keep-networks"])
        #expect(review.displayName == "staging")
        #expect(review.request.workingDirectory?.path == "/tmp/staging")
    }

    @MainActor @Test func corruptPluginLibrariesCannotBeOverwritten() throws {
        let suite = "ReviewFix.library.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = PluginLibraryStore(defaults: defaults)
        let project = library.addProject(URL(fileURLWithPath: "/tmp/saved.yaml"), name: "saved")
        defaults.set("invalid document", forKey: "containerdesk.composeProjects.v1")
        library.renameProject(id: project.id, name: "new")
        library.forgetProject(id: project.id)
        _ = library.addProject(URL(fileURLWithPath: "/tmp/new.yaml"), name: "new")
        #expect(defaults.string(forKey: "containerdesk.composeProjects.v1") == "invalid document")
        #expect(library.projects == [project])
        #expect(library.loadError != nil)
        defaults.set("invalid names", forKey: "containerdesk.k8sTrackedNames.v1")
        library.rememberCluster("new")
        library.forgetCluster("old")
        #expect(defaults.string(forKey: "containerdesk.k8sTrackedNames.v1") == "invalid names")
    }

    @MainActor @Test func unchangedCLIPathPreservesClientAndLoadedInventory() async throws {
        let suite = "ReviewFix.path.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/fixture/container", forKey: "containerDesk.cliPath")
        let client = ReviewFixClient()
        let store = AppStore(client: client, defaults: defaults)
        await store.refresh(.containers)
        let snapshot = store.snapshots[.containers]
        store.cliPath = "/fixture/container"
        #expect(store.client is ReviewFixClient)
        #expect(store.snapshots[.containers] == snapshot)
        await store.refresh(.containers, force: true)
        #expect(await client.calls == 2)
        #expect(store.resourceUpdatedAt[.containers] != nil)
    }
}

private actor ReviewFixClient: ContainerClient {
    private(set) var calls = 0
    func run(_ request: CommandRequest) async throws -> CommandResult {
        calls += 1
        return .init(standardOutput: "[]", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> { .init { $0.finish() } }
}
