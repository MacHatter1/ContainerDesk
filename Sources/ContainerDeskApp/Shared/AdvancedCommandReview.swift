import ContainerDeskCore
import Foundation

struct AdvancedCommandReview {
    let section: ContainerSection
    let commandID: String
    let title: String
    let request: CommandRequest
    let runtime: AppStore.ReviewedRuntime
    let refreshSection: Bool
    private let spec: AdvancedCommandSpec
    private let flags: Set<String>
    private let positionals: [String]

    init(section: ContainerSection, spec: AdvancedCommandSpec, flags: Set<String>, values: [String: String], positionals: [String], runtime: AppStore.ReviewedRuntime) throws {
        self.section = section
        commandID = spec.id
        title = spec.title
        self.spec = spec
        self.flags = flags
        self.positionals = positionals
        self.runtime = runtime
        refreshSection = spec.refreshSection
        request = try AdvancedCommandRequestBuilder.make(section: section, spec: spec, flags: flags, values: values, positionalArguments: AdvancedCommandRequestBuilder.positionals(for: spec, input: positionals))
    }

    var confirmationTitle: String {
        if flags.contains("all") {
            switch spec.id {
            case "stop": return "Stop all running containers?"
            case "delete" where section == .images: return "Delete all local images?"
            case "delete" where section == .containers: return "Delete all containers?"
            case "delete" where section == .volumes: return "Delete all unused volumes?"
            case "delete" where section == .networks: return "Delete all user-defined networks?"
            case "kill": return "Signal every running container?"
            default: break
            }
        }
        let targets = confirmationTargets
        return targets.isEmpty ? "\(spec.title)?" : "\(spec.title): \(targets)?"
    }

    var confirmationMessage: String {
        if let message = spec.confirmationMessage { return message }
        let targets = confirmationTargets
        if !targets.isEmpty { return "This command targets: \(targets)" }
        return flags.contains("all") ? "The command will apply to the full scope named above." : "Review the selected action and scope before continuing."
    }

    private var confirmationTargets: String {
        positionals
            .flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(AdvancedCommandScopeValidation.confirmationLabel)
            .joined(separator: ", ")
    }
}
