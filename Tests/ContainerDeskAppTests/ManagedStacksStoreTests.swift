import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

@MainActor
struct ManagedStacksStoreTests {
    @Test func createRenameMoveRemoveAndDeletePersistWithoutMutatingContainers() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = ManagedStacksStore(repository: fixture.repository)
        let first = try store.save(name: "  App  ", containerIDs: ["api", "db"])
        let second = try store.save(name: "Workers", containerIDs: [])
        #expect(first.name == "App")
        try store.assign(containerID: "api", to: second.id)
        #expect(store.stacks.first { $0.id == first.id }?.containerIDs == ["db"])
        let current = try #require(store.stacks.first { $0.id == first.id })
        let renamed = try store.save(name: "Backend", containerIDs: current.containerIDs, replacing: current)
        #expect(renamed.id == first.id)
        try store.remove(containerID: "db", from: renamed)
        #expect(store.collection.ungroupedContainerIDs == ["db"])
        #expect(store.stacks.first { $0.id == first.id }?.containerIDs.isEmpty == true)
        let workers = try #require(store.stacks.first { $0.id == second.id })
        try store.delete(workers)
        #expect(store.collection.ungroupedContainerIDs == ["api", "db"])
        #expect(ManagedStacksStore(repository: fixture.repository).collection == store.collection)
    }

    @Test func invalidAndStaleEditsPreserveTheSavedLibrary() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = ManagedStacksStore(repository: fixture.repository)
        let original = try store.save(name: "App", containerIDs: ["api"])
        let current = try store.save(name: "Current", containerIDs: ["db"], replacing: original)
        #expect(throws: ManagedStackError.staleStack) { try store.delete(original) }
        #expect(throws: ManagedStackError.invalidName) { try store.save(name: "\n ", containerIDs: ["db"]) }
        #expect(throws: ManagedStackError.duplicateName("current")) { try store.save(name: "current", containerIDs: ["db"]) }
        #expect(store.stacks == [current])
        #expect(ManagedStacksStore(repository: fixture.repository).collection == store.collection)
    }

    @Test func runtimeSwitchesKeepMembershipSeparate() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = ManagedStacksStore(repository: fixture.repository)
        let original = try store.save(name: "Local", containerIDs: ["api"])
        store.setRuntime(cliPath: "/other/container")
        #expect(store.stacks.isEmpty)
        let other = try store.save(name: "Other runtime", containerIDs: ["api"])
        store.setRuntime(cliPath: nil)
        #expect(store.stacks == [original])
        store.setRuntime(cliPath: "/other/container")
        #expect(store.stacks == [other])
    }

    @Test func failedLoadsAndExternalChangesRequireExplicitReload() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = ManagedStacksStore(repository: fixture.repository)
        let other = ManagedStacksStore(repository: fixture.repository)
        let original = try store.save(name: "App", containerIDs: ["api"])
        #expect(throws: ManagedStackError.libraryChanged) { try other.save(name: "Other", containerIDs: []) }
        other.reload()
        #expect(other.stacks == [original])
        try Data("broken".utf8).write(to: fixture.repository.storageURL)
        #expect(throws: ManagedStackError.loadFailed) { try store.delete(original) }
        #expect(throws: ManagedStackError.loadFailed) { try store.save(name: "Overwrite", containerIDs: []) }
        #expect(try String(contentsOf: fixture.repository.storageURL, encoding: .utf8) == "broken")
    }

    @Test func successfulLaunchJoinsStackAndFailedLaunchDoesNotChangeMembership() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/missing/container", forKey: "containerDesk.cliPath")
        let client = StackLaunchClient()
        let app = AppStore(client: client, defaults: defaults, stackRepository: fixture.repository)
        let stack = try app.managedStacks.save(name: "App", containerIDs: [])
        _ = try await app.runContainer(configuration: .init(image: "alpine:3.20"), stackID: stack.id)
        let member = try #require(app.managedStacks.stacks.first?.containerIDs.first)
        #expect(member.hasPrefix("stack-"))
        let requests = await client.requests
        #expect(requests.contains { $0.arguments.starts(with: ["run", "--detach", "--name", member]) })
        #expect(!requests.contains { ["delete", "rm", "stop", "start"].contains($0.arguments.first ?? "") })
        await client.failNextLaunch()
        await #expect(throws: (any Error).self) {
            try await app.runContainer(configuration: .init(name: "failed", image: "alpine:3.20"), stackID: stack.id)
        }
        #expect(app.managedStacks.stacks.first?.containerIDs == [member])
    }

    @Test func deletedTargetsAndRuntimeChangesAfterLaunchReportPartialSuccessWithoutWrongAssignment() async throws {
        for switchRuntime in [false, true] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            let suite = UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("/missing/container", forKey: "containerDesk.cliPath")
            let client = StackLaunchClient()
            let app = AppStore(client: client, defaults: defaults, stackRepository: fixture.repository)
            let stack = try app.managedStacks.save(name: "App", containerIDs: [])
            await client.setOnLaunch {
                if switchRuntime { app.cliPath = "/another/container" }
                else { try? app.managedStacks.delete(stack) }
            }
            do {
                _ = try await app.runContainer(configuration: .init(name: "created", image: "alpine:3.20"), stackID: stack.id)
                Issue.record("A launch with a lost target should report partial success.")
            } catch {
                guard case ManagedStackError.launchedButNotAssigned(let container, _) = error else {
                    Issue.record("Unexpected launch error: \(error)")
                    continue
                }
                #expect(container == "created")
            }
            #expect(app.managedStacks.stacks.isEmpty)
            let requests = await client.requests
            #expect(requests.filter { $0.arguments.first == "run" }.count == 1)
            #expect(!requests.contains { ["delete", "rm", "stop"].contains($0.arguments.first ?? "") })
        }
    }

    @Test func missingTargetPreventsLaunch() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/missing/container", forKey: "containerDesk.cliPath")
        let client = StackLaunchClient()
        let app = AppStore(client: client, defaults: defaults, stackRepository: fixture.repository)
        await #expect(throws: ManagedStackError.staleStack) {
            try await app.runContainer(configuration: .init(image: "alpine:3.20"), stackID: UUID())
        }
        #expect(await client.requests.isEmpty)
    }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var repository: ManagedStackRepository { .init(storageURL: directory.appendingPathComponent("stacks.json")) }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}

private actor StackLaunchClient: ContainerClient {
    var requests: [CommandRequest] = []
    private var failLaunch = false
    private var onLaunch: (@MainActor @Sendable () -> Void)?
    func failNextLaunch() { failLaunch = true }
    func setOnLaunch(_ action: @escaping @MainActor @Sendable () -> Void) { onLaunch = action }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        if request.arguments.first == "run" { await onLaunch?() }
        let failure = request.arguments.first == "run" && failLaunch
        return CommandResult(standardOutput: "[]", standardError: failure ? "launch failed" : "", exitCode: failure ? 1 : 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
