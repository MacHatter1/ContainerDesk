import SwiftUI

struct AdvancedCommandControls: View {
    let running: Bool
    let valid: Bool
    let run: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack {
            Button(running ? "Running…" : "Run", action: run)
                .disabled(running || !valid)
            if running { Button("Cancel", role: .destructive, action: cancel) }
        }
        .buttonStyle(.borderedProminent)
    }
}
