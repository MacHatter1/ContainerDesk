import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct StackWorkspaceVisibilityTests {
    @MainActor
    @Test func stacksRefreshSharedResourceSnapshotsWithoutDuplicateListTasks() async throws {
        let suiteName = "StackWorkspaceVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("/missing/container-cli", forKey: "containerDesk.cliPath")

        let client = StackVisibilityTestClient()
        let store = AppStore(client: client, defaults: defaults)
        let sceneID = "stack-visibility"
        store.setWindowActive(sceneID, active: true)
        store.setVisibleSection(.stacks, for: sceneID)
        defer {
            store.setVisibleSection(nil, for: sceneID)
            store.setWindowActive(sceneID, active: false)
            store.stopPolling()
        }

        try await waitUntil {
            let calls = await client.listCalls()
            return calls.contains(["list", "--all", "--format", "json"])
                && calls.contains(["image", "list", "--format", "json", "--verbose"])
                && calls.contains(["volume", "list", "--format", "json"])
                && calls.contains(["network", "list", "--format", "json"])
        }

        let calls = await client.listCalls()
        #expect(calls.filter { $0 == ["list", "--all", "--format", "json"] }.count == 1)
        #expect(calls.filter { $0 == ["image", "list", "--format", "json", "--verbose"] }.count == 1)
        #expect(calls.filter { $0 == ["volume", "list", "--format", "json"] }.count == 1)
        #expect(calls.filter { $0 == ["network", "list", "--format", "json"] }.count == 1)
    }

    @MainActor
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Bool(false), "The Stacks destination did not refresh all shared resource snapshots.")
    }
}

private actor StackVisibilityTestClient: ContainerClient {
    private var recorded: [[String]] = []

    func listCalls() -> [[String]] {
        recorded.filter { arguments in
            arguments.first == "list" || arguments.starts(with: ["image", "list"])
                || arguments.starts(with: ["volume", "list"]) || arguments.starts(with: ["network", "list"])
        }
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        recorded.append(request.arguments)
        let output = request.arguments == ["--help"] ? "Usage: container" : "[]"
        return CommandResult(standardOutput: output, standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await run(request)
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
