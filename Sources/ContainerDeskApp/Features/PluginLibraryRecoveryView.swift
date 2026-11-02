import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PluginLibraryRecoveryNotice: View {
    let library: PluginLibraryStore
    let kind: PluginLibraryKind
    @State private var showingRecovery = false

    var body: some View {
        Group {
            if let error = library.error(for: kind) {
                HStack {
                    InlineNotice(message: error, kind: .error)
                    Button("Library Recovery…") { showingRecovery = true }
                }.padding()
            }
        }.sheet(isPresented: $showingRecovery) { PluginLibraryRecoverySheet(library: library, kind: kind) }
    }
}

struct PluginLibraryRecoverySheet: View {
    let library: PluginLibraryStore
    let kind: PluginLibraryKind
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var message: String?
    @State private var importing = false
    @State private var review: PluginLibraryRecoveryReview?
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover \(kind.title)").font(.title2)
            Text("Retry reading the saved library, import a repaired JSON array, or start an empty library. Import and reset first save an exact copy of the old value on this Mac. These actions change remembered references only; they do not remove containers, clusters or Compose files.")
            if let error = error ?? library.error(for: kind) { InlineNotice(message: error, kind: .error) }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Retry Read") { library.retry(kind) }
                Button("Export Saved Data…", action: export)
                Button("Import Repaired JSON…") { importing = true }
                Button("Reset Library…", role: .destructive) {
                    do { review = try library.recoveryReview(kind); confirmingReset = true }
                    catch { self.error = error.localizedDescription }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 660)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_000_001) ?? Data()
                let review = try library.recoveryReview(kind)
                let backup = try library.recover(review, repairedJSON: data)
                error = nil; message = "Imported repaired library. Original saved at \(backup.path)."
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Reset remembered \(kind.title)?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Back Up and Reset", role: .destructive) {
                do {
                    guard let review else { return }
                    let backup = try library.recover(review)
                    error = nil; message = "Library reset. Original saved at \(backup.path)."
                } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("An exact backup must be saved successfully before the remembered library is cleared.") }
    }

    private func export() {
        do {
            let review = try library.recoveryReview(kind)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(kind.rawValue)-library-backup.plist"
            panel.allowedContentTypes = [.propertyList]
            if panel.runModal() == .OK, let url = panel.url {
                try library.export(review, to: url)
                error = nil; message = "Saved an exact copy at \(url.path)."
            }
        } catch { self.error = error.localizedDescription }
    }
}
