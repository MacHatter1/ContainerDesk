import ContainerDeskCore
import Foundation
import Observation

enum RuntimeOperationError: LocalizedError {
    case limitsInProgress, runtimeChanged
    var errorDescription: String? {
        switch self {
        case .limitsInProgress: "Wait for the container limits change to finish before changing runtime resources."
        case .runtimeChanged: "The selected runtime changed. Review this action again before running it."
        }
    }
}

/// Shared across windows and sheets. An acquired command lease also protects queued work.
@MainActor @Observable
final class RuntimeOperationPolicy {
    private(set) var limitsContainerID: String?
    private var limitsToken: UUID?
    private var mutations = Set<UUID>()

    func beginLimitsChange(_ id: String) -> UUID? {
        guard limitsToken == nil, mutations.isEmpty else { return nil }
        let token = UUID()
        limitsToken = token
        limitsContainerID = id
        return token
    }

    func endLimitsChange(_ token: UUID) {
        guard limitsToken == token else { return }
        limitsToken = nil
        limitsContainerID = nil
    }

    func canStart(_ request: CommandRequest) -> Bool { limitsToken == nil || Self.isReadOnly(request.arguments) }

    func beginCommand(_ request: CommandRequest) throws -> UUID? {
        guard canStart(request) else { throw RuntimeOperationError.limitsInProgress }
        guard !Self.isReadOnly(request.arguments) else { return nil }
        let token = UUID()
        mutations.insert(token)
        return token
    }

    func endCommand(_ token: UUID?) { if let token { mutations.remove(token) } }

    private static func isReadOnly(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if ["list", "inspect", "logs", "stats", "--help", "--version", "version"].contains(first) { return true }
        guard args.count > 1 else { return false }
        switch first {
        case "image", "volume", "network": return ["list", "inspect"].contains(args[1])
        case "registry", "k8s": return args[1] == "list"
        case "machine": return ["list", "inspect", "logs"].contains(args[1])
        case "builder": return args[1] == "status"
        case "system":
            if ["status", "version", "df", "logs"].contains(args[1]) { return true }
            return args.count > 2 && ["dns", "property"].contains(args[1]) && ["list", "get"].contains(args[2])
        default: return false
        }
    }
}
