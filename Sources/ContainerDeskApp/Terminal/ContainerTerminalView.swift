import AppKit
import ContainerDeskCore
import SwiftTerm
import SwiftUI

/// Embeds a disposable SwiftTerm PTY for interactive CLI actions. Terminal contents are never persisted.
struct ContainerTerminalView: NSViewRepresentable {
    var arguments: [String]
    var executablePath: String?
    var environment: [String: String]
    var currentDirectory: String?
    var onExit: ((Int32?) -> Void)?

    init(arguments: [String], executablePath: String? = nil, environment: [String: String] = [:], currentDirectory: String? = nil, onExit: ((Int32?) -> Void)? = nil) {
        self.arguments = arguments
        self.executablePath = executablePath
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.onExit = onExit
    }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        applyTerminalAppearance(view, colorScheme: context.environment.colorScheme)
        guard let executable = ExecutableResolver(overridePath: executablePath).resolve() else {
            view.feed(text: "Container CLI was not found. Choose its path in Settings.\r\n")
            return view
        }
        var childEnvironment = ExecutableResolver.normalizedEnvironment()
        childEnvironment["TERM"] = "xterm-256color"
        childEnvironment["COLORTERM"] = "truecolor"
        childEnvironment.merge(environment) { _, new in new }
        ProcessDescriptorLock.withLock {
            view.startProcess(executable: executable.path, args: arguments, environment: childEnvironment.map { "\($0.key)=\($0.value)" }, currentDirectory: currentDirectory)
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        applyTerminalAppearance(nsView, colorScheme: context.environment.colorScheme)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    private func applyTerminalAppearance(_ view: LocalProcessTerminalView, colorScheme: ColorScheme) {
        if colorScheme == .dark {
            view.nativeBackgroundColor = NSColor(calibratedRed: 0.075, green: 0.090, blue: 0.115, alpha: 1)
            view.nativeForegroundColor = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.96, alpha: 1)
        } else {
            view.nativeBackgroundColor = NSColor(calibratedRed: 0.945, green: 0.957, blue: 0.977, alpha: 1)
            view.nativeForegroundColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.23, alpha: 1)
        }
    }

    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: ((Int32?) -> Void)?
        init(onExit: ((Int32?) -> Void)?) { self.onExit = onExit }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let status = exitCode.map { String($0) } ?? "unknown"
            source.feed(text: "\r\nSession ended (exit status \(status)).\r\n")
            onExit?(exitCode)
        }
    }
}
