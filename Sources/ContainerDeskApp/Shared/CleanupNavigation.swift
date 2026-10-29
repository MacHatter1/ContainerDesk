import ContainerDeskCore
import SwiftUI

struct CleanupNavigationAction: Sendable {
    var action: @MainActor @Sendable (CleanupCategory?) -> Void = { _ in }

    @MainActor func callAsFunction(_ category: CleanupCategory? = nil) {
        action(category)
    }
}

private struct CleanupNavigationKey: EnvironmentKey {
    static let defaultValue = CleanupNavigationAction()
}

extension EnvironmentValues {
    var openCleanup: CleanupNavigationAction {
        get { self[CleanupNavigationKey.self] }
        set { self[CleanupNavigationKey.self] = newValue }
    }
}

private struct CleanupFocusedValueKey: FocusedValueKey {
    typealias Value = CleanupNavigationAction
}

extension FocusedValues {
    var cleanupNavigation: CleanupNavigationAction? {
        get { self[CleanupFocusedValueKey.self] }
        set { self[CleanupFocusedValueKey.self] = newValue }
    }
}
