import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct AppStoreResourceRefreshTests {
    @MainActor
    @Test func missingOrFreshNavigationAndIdenticalForcedRefreshBehaveCorrectly() async throws {
        let (store, client, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A missing snapshot must load through the public AppStore refresh seam.
        await store.refresh(.containers)
        let loadedSnapshot = try #require(store.snapshots[.containers])
        let loadedBackend = try #require(store.resourceReadBackends[.containers])
        let loadedFallbackReason = store.resourceReadFallbackReasons[.containers]
        #expect(loadedSnapshot.state == .loaded)

        // Catches navigation re-reading a recently loaded section and triggering a list refresh.
        await store.refresh(.containers)
        #expect(await client.listCallCount() == 1)

        // A forced refresh must still reach the reader, but identical data must not publish a new
        // snapshot solely to move fetchedAt and invalidate views observing the snapshot dictionary.
        await store.refresh(.containers, force: true)
        #expect(await client.listCallCount() == 2)
        #expect(store.snapshots[.containers] == loadedSnapshot)
        #expect(store.resourceReadBackends[.containers] == loadedBackend)
        #expect(store.resourceReadFallbackReasons[.containers] == loadedFallbackReason)
    }

    @MainActor
    @Test func ordinaryRefreshRetriesImmediatelyAfterForcedRefreshFails() async throws {
        let (store, client, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await store.refresh(.containers)
        #expect(store.snapshots[.containers]?.state == .loaded)
        await client.failNextList()

        await store.refresh(.containers, force: true)
        if case .failed? = store.snapshots[.containers]?.state { } else {
            Issue.record("The forced list failure was not published as a failed snapshot.")
        }
        #expect(await client.listCallCount() == 2)

        // Catches stale success timestamps suppressing recovery after a later forced read fails.
        await store.refresh(.containers)
        #expect(await client.listCallCount() == 3)
        #expect(store.snapshots[.containers]?.state == .loaded)
    }

    @MainActor
    @Test func concurrentRefreshCallersShareOneRead() async throws {
        let (store, client, defaults, suiteName) = makeStore(readDelay: .milliseconds(120), payload: #"[{"id":"web","status":{"state":"running"}}]"#)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = Task { @MainActor in await store.refresh(.containers, force: true) }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { @MainActor in await store.refresh(.containers) }
        await second.value
        #expect(store.snapshots[.containers]?.state == .loaded, "A joining Logs/navigation caller must await the first inventory.")
        #expect(store.snapshots[.containers]?.items.map(\.id) == ["web"])
        await first.value

        // Catches separate visible/navigation callers starting duplicate reads while one is pending.
        #expect(await client.listCallCount() == 1)
    }

    @MainActor
    @Test func cancellingAJoiningCallerDoesNotCancelTheOwningInventoryRead() async throws {
        let (store, client, defaults, suiteName) = makeStore(readDelay: .milliseconds(150))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = Task { await store.refresh(.containers, force: true) }
        try await Task.sleep(for: .milliseconds(20))
        let joining = Task { await store.refresh(.containers) }
        try await Task.sleep(for: .milliseconds(10))
        joining.cancel()
        await joining.value
        await first.value
        #expect(store.snapshots[.containers]?.state == .loaded)
        #expect(await client.listCallCount() == 1)
    }

    @MainActor
    @Test func changingCLIReleasesJoiningCallersAndRejectsTheOldInventory() async throws {
        let (store, _, defaults, suiteName) = makeStore(readDelay: .milliseconds(120), payload: #"[{"id":"old-runtime"}]"#)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = Task { await store.refresh(.containers, force: true) }
        try await Task.sleep(for: .milliseconds(20))
        let joining = Task { await store.refresh(.containers) }
        try await Task.sleep(for: .milliseconds(10))
        store.cliPath = "/missing/replacement-container-cli"
        await joining.value
        await first.value
        #expect(store.snapshots[.containers]?.items.isEmpty == true)
        #expect(store.snapshots[.containers]?.state == .idle)
    }

    @MainActor
    @Test func postMutationForceRequiresANewerRead() async throws {
        let (store, client, defaults, suiteName) = makeStore(holdFirstRead: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldRead = Task { await store.refresh(.containers) }
        while await client.listCallCount() == 0 { await Task.yield() }
        await client.setPayload(#"[{"id":"created-after-read-started"}]"#)
        var submitted = false
        let forced = Task { submitted = true; await store.refresh(.containers, force: true) }
        while !submitted { await Task.yield() }
        await client.releaseFirstRead()
        await forced.value
        await oldRead.value
        #expect(store.snapshots[.containers]?.items.map(\.id) == ["created-after-read-started"])
        #expect(await client.listCallCount() == 2)
        await store.refresh(.containers)
        #expect(await client.listCallCount() == 2)
    }

    @MainActor
    private func makeStore(readDelay: Duration = .zero, payload: String = "[]", holdFirstRead: Bool = false) -> (AppStore, ResourceRefreshTestClient, UserDefaults, String) {
        let suiteName = "AppStoreResourceRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("/missing/container-cli", forKey: "containerDesk.cliPath")
        let client = ResourceRefreshTestClient(readDelay: readDelay, payload: payload, holdFirstRead: holdFirstRead)
        return (AppStore(client: client, defaults: defaults), client, defaults, suiteName)
    }
}

private actor ResourceRefreshTestClient: ContainerClient {
    private let readDelay: Duration
    private var payload: String
    private var calls = 0
    private var shouldFailNextList = false
    private let holdFirstRead: Bool
    private var firstReadWaiter: CheckedContinuation<Void, Never>?

    init(readDelay: Duration, payload: String, holdFirstRead: Bool = false) {
        self.readDelay = readDelay
        self.payload = payload
        self.holdFirstRead = holdFirstRead
    }

    func listCallCount() -> Int { calls }

    func failNextList() { shouldFailNextList = true }
    func setPayload(_ value: String) { payload = value }
    func releaseFirstRead() { firstReadWaiter?.resume(); firstReadWaiter = nil }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        if request.arguments == ["list", "--all", "--format", "json"] {
            calls += 1
            let capturedPayload = payload
            if calls == 1, holdFirstRead { await withCheckedContinuation { firstReadWaiter = $0 } }
            try await Task.sleep(for: readDelay)
            if shouldFailNextList {
                shouldFailNextList = false
                return CommandResult(standardOutput: "", standardError: "failed", exitCode: 1, terminationReason: .exit, duration: .zero)
            }
            return CommandResult(standardOutput: capturedPayload, standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
        }
        return CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(.completed(try await run(request)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
