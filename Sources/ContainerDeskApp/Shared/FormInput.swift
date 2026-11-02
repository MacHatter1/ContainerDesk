import ContainerDeskCore
import Foundation

extension String {
    var trimmedFormValue: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum FormInput {
    /// Trim the key and indentation, keeping the value after '=' byte-for-byte.
    static func assignments(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard !line.trimmedFormValue.isEmpty else { return nil }
            guard let equal = line.firstIndex(of: "=") else { return line.trimmedFormValue }
            return String(line[..<equal]).trimmedFormValue + String(line[equal...])
        }
    }
}

/// Snapshots basic resource forms at the same normalization boundary used by validation.
struct ResourceCreationForm {
    var name = ""
    var image = ""
    var cpuText = ""
    var memoryText = ""
    var platform = ""
    var subnet = ""
    var subnetV6 = ""
    var size = ""
    var optionsText = ""
    var username = ""
    var password = ""
    var registryScheme = "https"
    var internalNetwork = false

    func request(for section: ContainerSection) throws -> CommandRequest {
        let name = name.trimmedFormValue
        let image = image.trimmedFormValue
        if [.images, .machines].contains(section) {
            guard !image.isEmpty else { throw FeatureCommandError(message: "Enter an image reference.") }
        } else if name.isEmpty { throw FeatureCommandError(message: "Enter a resource name.") }
        var args: [String]
        switch section {
        case .images:
            args = ["image", "pull"]
            if !platform.trimmedFormValue.isEmpty { args += ["--platform", platform.trimmedFormValue] }
            args.append(image)
        case .volumes:
            args = ["volume", "create"]
            if !size.trimmedFormValue.isEmpty { args += ["-s", size.trimmedFormValue] }
            for line in FormInput.assignments(optionsText) { args += ["--opt", line] }
            args.append(name)
        case .networks:
            args = ["network", "create"]
            if internalNetwork { args.append("--internal") }
            if !subnet.trimmedFormValue.isEmpty { args += ["--subnet", subnet.trimmedFormValue] }
            if !subnetV6.trimmedFormValue.isEmpty { args += ["--subnet-v6", subnetV6.trimmedFormValue] }
            for line in FormInput.assignments(optionsText) { args += ["--option", line] }
            args.append(name)
        case .registries:
            return try RegistryLoginRequestBuilder.request(server: name, scheme: registryScheme, username: username.trimmedFormValue, password: password)
        case .machines:
            args = ["machine", "create"]
            if !name.isEmpty { args += ["--name", name] }
            if !cpuText.trimmedFormValue.isEmpty { args += ["--cpus", cpuText.trimmedFormValue] }
            if !memoryText.trimmedFormValue.isEmpty { args += ["--memory", memoryText.trimmedFormValue] }
            args.append(image)
        default: throw FeatureCommandError(message: "This resource type does not support this form.")
        }
        return CommandRequest(arguments: args)
    }
}
