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
    private var terminationReady = false
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
        // A normal Quit must not interrupt the disk replacement between delete and recovery.
        guard store?.limitsOperationContainerID == nil else { return .terminateCancel }
        guard let mlxStore else { return .terminateNow }
        if terminationReady { return .terminateNow }
        guard !terminationInProgress else { return .terminateCancel }
        terminationInProgress = true
        Task { @MainActor in
            await mlxStore.shutdown()
            terminationReady = true
            terminationInProgress = false
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }
}
