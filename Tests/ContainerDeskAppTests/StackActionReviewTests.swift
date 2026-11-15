import ContainerDeskCore
import Testing
@testable import ContainerDeskApp

struct StackActionReviewTests {
    @MainActor @Test(arguments: [StackWorkspaceAction.stop, .restart])
    func changedStatesInvalidateReviewEvenWhenMembershipAndRunningCountMatch(_ action: StackWorkspaceAction) {
        let store = AppStore(client: StackReviewClient())
        let original = workspace(running: ["api"], stopped: ["worker"])
        let review = StackWorkspaceFeatureView.PendingStackAction(action: action, workspace: original, runtimeScope: store.managedStacks.runtimeScope, runtime: store.captureReviewedRuntime())
        let changed = workspace(running: ["worker"], stopped: ["api"])

        #expect(review.matchesPlan(in: original))
        #expect(Set(changed.containers.map(\.id)) == review.containerIDs)
        #expect(changed.runningCount == review.runningCount)
        #expect(!review.matchesPlan(in: changed))
        #expect(review.commands.first?.arguments == ["stop", "--", "api"])
        if action == .restart {
            #expect(review.commands.last?.arguments == ["start", "--", "api"])
        }
    }

    @MainActor @Test func reviewKeepsOriginalTitleCountAndCommandsWhenAnotherMemberStarts() {
        let store = AppStore(client: StackReviewClient())
        let original = workspace(running: ["api"], stopped: ["worker"])
        let review = StackWorkspaceFeatureView.PendingStackAction(action: .stop, workspace: original, runtimeScope: store.managedStacks.runtimeScope, runtime: store.captureReviewedRuntime())
        let changed = workspace(running: ["api", "worker"], stopped: [], title: "Renamed")

        #expect(!review.matchesPlan(in: changed))
        #expect(review.confirmationTitle == "Stop Reviewed?")
        #expect(review.confirmationMessage == "The running container in this stack will stop gracefully.")
        #expect(review.commands == [.init(phase: .stop, arguments: ["stop", "--", "api"])])
    }

    private func workspace(running: [String], stopped: [String], title: String = "Reviewed") -> StackWorkspace {
        StackWorkspace(
            id: "stack",
            title: title,
            grouping: .explicitLabel(key: "containerdesk.stack", value: "reviewed"),
            containers: running.map { .init(id: $0, title: $0, state: "running") }
                + stopped.map { .init(id: $0, title: $0, state: "stopped") },
            runningCount: running.count,
            stoppedCount: stopped.count,
            otherCount: 0
        )
    }
}

private struct StackReviewClient: ContainerClient {
    func run(_ request: CommandRequest) async throws -> CommandResult { throw CancellationError() }
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}
