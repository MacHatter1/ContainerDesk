import Foundation
import Darwin
import SwiftTerm

/// Owns a native PTY across temporary SwiftUI feature unmounts. Its contents stay in memory.
@MainActor
final class ContainerTerminalSession {
    private final class WeakSession { weak var value: ContainerTerminalSession?; init(_ value: ContainerTerminalSession) { self.value = value } }
    private static var sessions: [WeakSession] = []
    private static let views = NSHashTable<LocalProcessTerminalView>.weakObjects()
    static func track(_ view: LocalProcessTerminalView) { views.add(view) }
    init() {
        Self.sessions.removeAll { $0.value == nil }
        Self.sessions.append(WeakSession(self))
    }
    static func terminateAll() {
        for session in sessions { session.value?.terminate() }
        for view in views.allObjects { view.terminate() }
    }
    static func shutdownAll() async {
        await stopProcesses(views.allObjects.compactMap(\.process))
        terminateAll()
    }

    func shutdown() async {
        if let process = terminalView?.process { await Self.stopProcesses([process]) }
        terminate()
    }

    private static func stopProcesses(_ processes: [LocalProcess]) async {
        for process in processes { process.drainTimeout = 0.5; process.terminate() }
        let graceDeadline = ContinuousClock.now + .milliseconds(500)
        while processes.contains(where: \.running), ContinuousClock.now < graceDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for process in processes where process.running {
            // SwiftTerm exposes zero after teardown; never signal pid/group zero.
            let pid = process.shellPid
            if pid > 0 { _ = kill(pid, SIGKILL) }
        }
        let drainDeadline = ContinuousClock.now + .seconds(2)
        while processes.contains(where: \.running), ContinuousClock.now < drainDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
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
    private var exited = false

    func didExit() { exited = true }

    func reuse(configuration: Configuration, coordinator: ContainerTerminalView.Coordinator) -> LocalProcessTerminalView? {
        guard self.configuration == configuration, !exited, terminalView?.process?.running == true else {
            terminate()
            return nil
        }
        self.coordinator = coordinator
        exited = false
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
        exited = false
    }

    isolated deinit {
        terminalView?.terminate()
    }
}
