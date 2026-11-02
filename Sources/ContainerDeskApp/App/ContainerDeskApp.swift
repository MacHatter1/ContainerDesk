import AppKit
import ContainerDeskCore
import Darwin
import SwiftUI

@main
struct ContainerDeskApp: App {
    @State private var store = AppStore()
    @State private var mlxStore = MLXStore(service: DefaultMLXModelService(configuration: MLXConfiguration()))
    @State private var externalMLXStore = ExternalMLXStore()
    @AppStorage(AppAppearance.defaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @NSApplicationDelegateAdaptor(ContainerDeskAppDelegate.self) private var appDelegate

    private var preferredColorScheme: ColorScheme? {
        AppAppearance.storedValue(appearanceRawValue).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup("ContainerDesk") {
            ContentView(store: store, mlxStore: mlxStore, externalMLXStore: externalMLXStore)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    appDelegate.mlxStore = mlxStore
                    appDelegate.store = store
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            ContainerDeskCommands(store: store, mlxStore: mlxStore, externalMLXStore: externalMLXStore)
        }

        Settings {
            SettingsView(store: store, mlxStore: mlxStore)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}

@MainActor
private final class ContainerDeskAppDelegate: NSObject, NSApplicationDelegate {
    var mlxStore: MLXStore?
    var store: AppStore?
    private var terminationInProgress = false
    private var terminationTask: Task<Void, Never>?
    private var terminationSignalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Darwin.signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
        signalSource.resume()
        terminationSignalSource = signalSource

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        terminationTask = Task { @MainActor in
            // Allow a disk replacement to finish its recovery transaction before
            // shutting down its helpers. If it stalls, decline Quit instead of
            // interrupting recovery or holding system logout indefinitely.
            let progress = store?.limitsOperationContainerID == nil ? nil : recoveryQuitProgress()
            let result = await LimitsQuitWaiter.wait { store?.limitsOperationContainerID != nil }
            progress?.close()
            guard result == .ready else {
                terminationInProgress = false
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: false)
                if result == .timedOut {
                    let alert = NSAlert()
                    alert.messageText = "Container recovery is still running"
                    alert.informativeText = "ContainerDesk stayed open after waiting 30 seconds so the container disk can finish recovering. You can keep using the app and quit again when recovery finishes."
                    alert.addButton(withTitle: "Keep App Open")
                    if let window = sender.windows.first(where: { $0.canBecomeMain }) { alert.beginSheetModal(for: window, completionHandler: { _ in }) }
                    else { alert.runModal() }
                }
                return
            }
            ProcessExecutableClient.beginApplicationShutdown()
            await store?.shutdown()
            await ContainerTerminalSession.shutdownAll()
            await mlxStore?.shutdown()
            await ProcessExecutableClient.shutdownAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func recoveryQuitProgress() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 190), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Finishing container recovery"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            ProgressView("Waiting for container recovery…")
            Text("The app will wait up to 30 seconds before staying open to protect the container disk. Recovery continues if you keep the app open.").font(.callout)
            HStack { Spacer(); Button("Keep App Open") { self.terminationTask?.cancel() } }
        }.padding(24))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return panel
    }
}
