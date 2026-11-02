import ContainerDeskCore
import Foundation
import Observation

@MainActor @Observable
final class SystemPanelStore {
    var output = ""
    var error: String?
    var diskUsage: SystemDiskUsage?
    private(set) var isLoading = false
    @ObservationIgnored private var generation = UUID()

    func showActionOutput(_ text: String) {
        generation = UUID()
        isLoading = false
        output = text
        error = nil
    }

    func load(tab: String, execute: (CommandRequest, String) async throws -> CommandResult) async {
        let token = UUID()
        generation = token
        output = ""; error = nil; isLoading = false
        let arguments: [String]
        switch tab {
        case "Disk Usage": arguments = ["system", "df", "--format", "json"]
        case "System Logs": arguments = ["system", "logs", "--last", "5m"]
        case "DNS Domains": arguments = ["system", "dns", "list", "--format", "json"]
        case "Properties": arguments = ["system", "property", "list", "--format", "json"]
        default: return
        }
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            let request = CommandRequest(arguments: arguments, captureLimit: 500_000, suppressOutputEvents: true, timeout: .seconds(20))
            let result = try await execute(request, "Read \(tab)")
            guard generation == token, !Task.isCancelled else { return }
            guard result.succeeded else { throw FeatureCommandError(result: result) }
            guard !result.outputTruncated else { throw SystemPanelError.responseTooLarge }
            if tab == "Disk Usage" { diskUsage = try JSONDecoder().decode(SystemDiskUsage.self, from: Data(result.standardOutput.utf8)) }
            else {
                output = request.sanitizeOutput(result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError))
                if output.isEmpty { output = tab == "System Logs" ? "No recent service logs." : "No output returned for \(tab.lowercased())." }
            }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            if tab == "Disk Usage" { diskUsage = nil }
            self.error = error.localizedDescription
        }
    }
}

private enum SystemPanelError: LocalizedError {
    case responseTooLarge
    var errorDescription: String? { "The system response exceeded the safe decode limit." }
}
