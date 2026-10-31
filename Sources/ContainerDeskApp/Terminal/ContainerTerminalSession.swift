import SwiftTerm

/// Owns a native PTY across temporary SwiftUI feature unmounts. Its contents stay in memory.
@MainActor
final class ContainerTerminalSession {
    struct Configuration: Equatable {
        let runtimeOperations: RuntimeOperationPolicy
        let arguments: [String]
        let executablePath: String?
        let environment: [String: String]
        let currentDirectory: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.runtimeOperations === rhs.runtimeOperations
                && lhs.arguments == rhs.arguments
                && lhs.executablePath == rhs.executablePath
                && lhs.environment == rhs.environment
                && lhs.currentDirectory == rhs.currentDirectory
        }
    }

    private(set) var terminalView: LocalProcessTerminalView?
    private var configuration: Configuration?
    // SwiftTerm's delegate is weak, so keep delivering exits while the wrapper is detached.
    private var coordinator: ContainerTerminalView.Coordinator?

    func reuse(configuration: Configuration, coordinator: ContainerTerminalView.Coordinator) -> LocalProcessTerminalView? {
        guard self.configuration == configuration else {
            terminate()
            return nil
        }
        self.coordinator = coordinator
        terminalView?.processDelegate = coordinator
        return terminalView
    }

    func retain(_ view: LocalProcessTerminalView, configuration: Configuration, coordinator: ContainerTerminalView.Coordinator) {
        terminalView = view
        self.configuration = configuration
        self.coordinator = coordinator
    }

    func terminate() {
        terminalView?.terminate()
        terminalView = nil
        configuration = nil
        coordinator = nil
    }

    isolated deinit {
        terminalView?.terminate()
    }
}
