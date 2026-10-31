import SwiftUI

/// Focus changes update menu availability without rebuilding the app's scenes.
struct ContainerDeskCommands: Commands {
    let store: AppStore
    let mlxStore: MLXStore
    let externalMLXStore: ExternalMLXStore
    @FocusedValue(\.cleanupNavigation) private var cleanupNavigation

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Cleanup…", systemImage: "sparkles") { cleanupNavigation?() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(cleanupNavigation == nil)
            Button("Refresh All Resources") {
                Task {
                    await store.refreshAll()
                    await mlxStore.refresh()
                    await externalMLXStore.refresh(force: true)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
