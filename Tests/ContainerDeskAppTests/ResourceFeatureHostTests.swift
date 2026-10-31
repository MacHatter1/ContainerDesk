import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

@MainActor
struct ResourceFeatureHostTests {
    private let sections: [ContainerSection] = [.containers, .images, .volumes, .networks, .registries, .machines]

    @Test func resourceStateSurvivesVisitsToEveryOtherDestination() {
        let cache = ResourceFeatureStateCache()
        var states: [ContainerSection: ResourceFeatureState] = [:]

        for section in sections {
            let state = cache.state(for: section)
            state.query = "filter-\(section.rawValue)"
            state.selection = ["selected-\(section.rawValue)"]
            state.focusedID = "selected-\(section.rawValue)"
            state.sortOrder = [KeyPathComparator(\ResourceSummary.title, order: .reverse)]
            state.detailTab = section == .containers ? .stats : .inspect
            state.transientText = "output-\(section.rawValue)"
            states[section] = state
        }

        #expect(Set(states.values.map(ObjectIdentifier.init)).count == sections.count)
        #expect(Set(states.values.map { ObjectIdentifier($0.operation) }).count == sections.count)

        for _ in 0..<3 {
            for section in sections.reversed() {
                let state = cache.state(for: section)
                #expect(state === states[section])
                #expect(state.query == "filter-\(section.rawValue)")
                #expect(state.selection == ["selected-\(section.rawValue)"])
                #expect(state.focusedID == "selected-\(section.rawValue)")
                #expect(state.sortOrder.count == 1)
                #expect(state.sortOrder.first?.order == .reverse)
                #expect(state.detailTab == (section == .containers ? .stats : .inspect))
                #expect(state.transientText == "output-\(section.rawValue)")
                #expect(state.operation === states[section]?.operation)
            }
        }
    }

    @Test func sceneCachesKeepSelectionAndPresentationStateIndependent() {
        let firstWindow = ResourceFeatureStateCache()
        let secondWindow = ResourceFeatureStateCache()

        for section in sections {
            let first = firstWindow.state(for: section)
            let second = secondWindow.state(for: section)
            #expect(first !== second)
            #expect(first.operation !== second.operation)
            first.query = "first-window"
            first.selection = ["first-selection"]
            first.focusedID = "first-selection"
            first.sortOrder = [KeyPathComparator(\ResourceSummary.title, order: .reverse)]
            first.detailTab = .inspect
            first.transientText = "first-output"

            #expect(second.query.isEmpty)
            #expect(second.selection.isEmpty)
            #expect(second.focusedID == nil)
            #expect(second.sortOrder.first?.order == .forward)
            #expect(second.detailTab == .overview)
            #expect(second.transientText.isEmpty)
            second.query = "second-window"
            second.selection = ["second-selection"]

            #expect(firstWindow.state(for: section).query == "first-window")
            #expect(firstWindow.state(for: section).selection == ["first-selection"])
            #expect(secondWindow.state(for: section).query == "second-window")
            #expect(secondWindow.state(for: section).selection == ["second-selection"])
        }
    }

    @Test func operationFeedbackStaysWithItsResourceAcrossDestinationChanges() async throws {
        let suiteName = "ResourceFeatureHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("/missing/resource-feature-host-cli", forKey: "containerDesk.cliPath")
        let store = AppStore(client: ResourceFeatureHostClient(), defaults: defaults)
        defer { store.stopPolling() }
        let cache = ResourceFeatureStateCache()
        let images = cache.state(for: .images)
        let operation = images.operation
        // Starting an image is invalid: this exercises retained feedback without
        // running a command or touching an external runtime.
        await operation.perform(.init(
            kind: .start,
            section: .images,
            resources: [.init(id: "image-fixture", title: "Fixture image")],
            runtime: store.captureReviewedRuntime()
        ), using: store)
        let failure = try #require(operation.failure)
        #expect(!failure.isEmpty)

        for section in sections where section != .images {
            #expect(cache.state(for: section).operation.failure == nil)
        }
        let revisited = cache.state(for: .images)
        #expect(revisited === images)
        #expect(revisited.operation === operation)
        #expect(revisited.operation.failure == failure)
        #expect(!revisited.operation.isRunning)
        #expect(ResourceFeatureStateCache().state(for: .images).operation.failure == nil)
    }
}

private actor ResourceFeatureHostClient: ContainerClient {
    func run(_ request: CommandRequest) async throws -> CommandResult {
        Issue.record("Resource state retention checks must not execute CLI commands.")
        return CommandResult(standardOutput: "[]", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
