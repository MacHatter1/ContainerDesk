import ContainerDeskCore
import Foundation
import Observation

/// Scene-local resource UI state survives while its screen is not mounted.
@MainActor @Observable
final class ResourceFeatureState {
    var query = ""
    var selection = Set<String>()
    var focusedID: String?
    var sortOrder = [KeyPathComparator(\ResourceSummary.title)]
    var showingCreate = false
    var showingProfiles = false
    var initialImage = ""
    var showingAdvanced = false
    var pendingAction: ResourcePendingAction?
    var actionReview: ResourceActionOperation.Review?
    var operation = ResourceActionOperation()
    var choosingArchive = false
    var limitsTarget: ResourceSummary?
    var notice: FeatureNotice?
    var detailTab = ResourceDetailTab.overview
    var requestedDetailTab: ResourceDetailTab?
    var transientText = ""
    var scrolledResourceID: String?
    let terminalSession = ContainerTerminalSession()
    var detailState = ResourceDetailState()

    func dismissPresentations() {
        showingCreate = false
        showingProfiles = false
        showingAdvanced = false
        initialImage = ""
        pendingAction = nil
        actionReview = nil
        limitsTarget = nil
    }
}
