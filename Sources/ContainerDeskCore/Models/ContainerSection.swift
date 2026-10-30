import Foundation

public enum ContainerSection: String, CaseIterable, Identifiable, Sendable {
    case containers
    case stacks
    case images
    case builds
    case volumes
    case networks
    case registries
    case machines
    case compose
    case kubernetes
    case system
    case cleanup
    case activity
    case mlxModels

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .containers: "Containers"
        case .stacks: "Stacks"
        case .images: "Images"
        case .builds: "Builds"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .registries: "Registries"
        case .machines: "Machines"
        case .compose: "Compose"
        case .kubernetes: "Kubernetes"
        case .system: "System"
        case .cleanup: "Cleanup"
        case .activity: "Activity"
        case .mlxModels: "MLX Models"
        }
    }
}
