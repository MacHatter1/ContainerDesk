import ContainerDeskCore
import Foundation

extension AppStore {
    /// Resolves the name before launch so membership never depends on parsing
    /// human-readable CLI output. A failed launch never changes the library.
    @discardableResult
    func runContainer(configuration: ContainerLaunchConfiguration, environment: [String] = [], stackID: UUID? = nil) async throws -> CommandResult {
        var configuration = configuration
        let runtime = managedStacks.runtimeScope
        if let stackID {
            try managedStacks.validateTarget(stackID)
            if configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configuration.name = "stack-\(UUID().uuidString.lowercased().prefix(12))"
            }
        }
        let request = try ContainerLaunchRequestBuilder.makeRequest(configuration: configuration, environment: environment)
        let result = try await execute(request, title: "Run Container", using: client)
        if let stackID {
            let name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                guard managedStacks.runtimeScope == runtime else { throw ManagedStackError.runtimeChanged }
                try managedStacks.assign(containerID: name, to: stackID)
            } catch {
                if managedStacks.runtimeScope == runtime { await refresh(.containers, force: true) }
                throw ManagedStackError.launchedButNotAssigned(container: name, reason: error.localizedDescription)
            }
        }
        if managedStacks.runtimeScope == runtime { await refresh(.containers, force: true) }
        return result
    }
}
