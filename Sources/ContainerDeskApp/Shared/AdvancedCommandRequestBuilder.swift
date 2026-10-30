import ContainerDeskCore
import Foundation

enum AdvancedCommandRequestBuilder {
    static func make(section: ContainerSection, spec: AdvancedCommandSpec, flags: Set<String>, values: [String: String], positionalArguments: [String], inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> CommandRequest {
        var sensitiveValues: [String] = []
        let flagArguments = spec.flags.flatMap { descriptor -> [String] in
            if ["env", "env-file"].contains(descriptor.name) { return [] }
            if descriptor.kind == .boolean { return flags.contains(descriptor.name) ? ["--\(descriptor.name)"] : [] }
            let raw = values[descriptor.name, default: ""]
            guard !raw.isEmpty else { return [] }
            let vals = descriptor.repeats ? raw.split(whereSeparator: \.isNewline).map(String.init) : [raw]
            if descriptor.sensitive { sensitiveValues += vals.map { entry in entry.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? entry } }
            let name = descriptor.shortName ?? "--\(descriptor.name)"
            return vals.flatMap { [name, $0] }
        }
        let positionalTerminator = AdvancedCommandScopeValidation.positionalTerminator(
            section: section,
            commandID: spec.id,
            positionals: positionalArguments
        )
        let names = Set(spec.flags.map(\.name))
        let environment = try ContainerLaunchRequestBuilder.snapshotEnvironment(
            files: names.contains("env-file") ? values["env-file", default: ""].split(whereSeparator: \.isNewline).map(String.init) : [],
            values: names.contains("env") ? values["env", default: ""].split(whereSeparator: \.isNewline).map(String.init) : [], inherited: inherited
        )
        sensitiveValues += environment.redactions
        let args = spec.arguments + flagArguments + environment.arguments + positionalTerminator + positionalArguments
        let commandOutput = AdvancedCommandOutput(section: section, commandID: spec.id, arguments: args)
        return CommandRequest(arguments: commandOutput.arguments, redactions: sensitiveValues)
    }
}
