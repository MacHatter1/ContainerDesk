import ContainerDeskCore
import Foundation
import Observation

/// Scene-local detail state survives while its resource screen is not mounted.
@MainActor @Observable
final class ResourceDetailState {
    var isLoading = false
    var followLogs = false
    var operationID: UUID?
    var error: String?
    var inspectBackend: ResourceReadBackend?
    var inspectFallbackReason: String?
    var logQuery = ""
    var hostPath = ""
    var hostDestinationPath = ""
    var containerSourcePath = "/tmp/"
    var containerDestinationPath = "/tmp/"
    var fileOutput = ""
    var fileImporter = false
    var fileOperationRunning = false
}
