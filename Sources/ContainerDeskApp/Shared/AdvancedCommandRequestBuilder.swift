import ContainerDeskCore
import Foundation

enum AdvancedCommandRequestBuilder {
    static func positionals(for spec: AdvancedCommandSpec, input: [String]) throws -> [String] {
        var args: [String] = []
        for (index, descriptor) in spec.positionals.enumerated() where input.indices.contains(index) {
            let raw = input[index]
            if descriptor.tokenized { args += try SafeArgumentTokenizer.tokenize(raw); continue }
            let name = descriptor.name.lowercased()
            let literal = name == "value" || name == "source" || name == "destination" || name.contains("path") || name.contains("folder") || name.contains("command") || name.contains("arguments")
            let values = descriptor.repeats ? raw.split(whereSeparator: \.isNewline).map(String.init) : [raw]
            args += values.map { literal ? $0 : $0.trimmedFormValue }.filter { !$0.isEmpty }
        }
        return args
    }

    static func make(section: ContainerSection, spec: AdvancedCommandSpec, flags: Set<String>, values: [String: String], positionalArguments: [String], inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> CommandRequest {
        var sensitiveValues: [String] = []
        let flagArguments = spec.flags.flatMap { descriptor -> [String] in
            if ["env", "env-file"].contains(descriptor.name) { return [] }
            if descriptor.kind == .boolean { return flags.contains(descriptor.name) ? ["--\(descriptor.name)"] : [] }
            let raw = values[descriptor.name, default: ""]
            guard !raw.isEmpty else { return [] }
            let inputValues = descriptor.repeats ? raw.split(whereSeparator: \.isNewline).map(String.init) : [raw]
            let vals: [String]
            switch descriptor.valueTreatment {
            case .hostPath: vals = inputValues.map { ($0 as NSString).expandingTildeInPath }
            case .guestPath, .literal: vals = inputValues
            case .structured: vals = descriptor.sensitive ? inputValues : inputValues.map(\.trimmedFormValue).filter { !$0.isEmpty }
            }
            if descriptor.sensitive { sensitiveValues += vals.map(CommandRequest.assignmentRedaction) }
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
