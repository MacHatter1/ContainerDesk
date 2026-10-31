import ContainerDeskCore
import SwiftUI

@MainActor
final class ResourceFeatureActivation: ObservableObject {
    @Published private(set) var isActive: Bool
    init(isActive: Bool) {
        self.isActive = isActive
    }

    func update(isActive: Bool) {
        if self.isActive != isActive { self.isActive = isActive }
    }
}

/// Each window retains values and operations, rather than inactive hosting trees.
@MainActor
final class ResourceFeatureStateCache {
    private let states: [ContainerSection: ResourceFeatureState] = Dictionary(
        uniqueKeysWithValues: [ContainerSection.containers, .images, .volumes, .networks, .registries, .machines]
            .map { ($0, ResourceFeatureState()) }
    )

    func state(for section: ContainerSection) -> ResourceFeatureState {
        guard let state = states[section] else { preconditionFailure("Not a resource section: \(section)") }
        return state
    }

    func terminateTerminalSessions() {
        for state in states.values { state.terminalSession.terminate() }
    }
}
