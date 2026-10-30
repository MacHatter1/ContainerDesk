import ContainerDeskCore

enum ResourceActionRouting {
    static func supportsDelete(_ section: ContainerSection) -> Bool { deletePrefix(section) != nil }
    static func supportsInspect(_ section: ContainerSection) -> Bool { inspectPrefix(section) != nil }

    static func deletionArguments(section: ContainerSection, target: String) throws -> [String] {
        guard let prefix = deletePrefix(section), !ResourceActionTargetValue.normalized(target).isEmpty else {
            throw FeatureCommandError(message: "This resource does not support deletion. Registries use Log Out.")
        }
        return prefix + ResourceActionTargetValue.positionalArguments(target)
    }

    static func inspectionArguments(section: ContainerSection, target: String) -> [String]? {
        guard let prefix = inspectPrefix(section) else { return nil }
        return prefix + ResourceActionTargetValue.positionalArguments(target)
    }

    private static func inspectPrefix(_ section: ContainerSection) -> [String]? {
        switch section {
        case .containers: ["inspect"]
        case .images: ["image", "inspect"]
        case .volumes: ["volume", "inspect"]
        case .networks: ["network", "inspect"]
        case .machines: ["machine", "inspect"]
        default: nil
        }
    }

    private static func deletePrefix(_ section: ContainerSection) -> [String]? {
        switch section {
        case .containers: ["delete"]
        case .images: ["image", "delete"]
        case .volumes: ["volume", "delete"]
        case .networks: ["network", "delete"]
        case .machines: ["machine", "delete"]
        default: nil
        }
    }
}
