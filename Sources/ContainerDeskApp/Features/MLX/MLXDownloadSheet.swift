import SwiftUI

struct MLXDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: MLXStore
    var reportError: (String) -> Void
    @State private var repositoryID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceHeader(title: "Download a model", subtitle: "Explicit Hugging Face download · saved in your managed models folder", symbol: "arrow.down.circle.fill", tint: .teal)
                .padding(.horizontal, -22)
                .padding(.top, -22)
            AccentPanel(title: "Repository", symbol: "shippingbox", tint: .teal) {
                Text("Enter a public repository ID in owner/model form.").foregroundStyle(.secondary)
                TextField("owner/model", text: $repositoryID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(beginDownload)
            }
            if !store.downloadOutput.isEmpty {
                AccentPanel(title: "Download output", symbol: "terminal", tint: .blue) {
                    ScrollView {
                        Text(store.downloadOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                }
            }
            if let error = store.downloadError { InlineNotice(message: error, kind: .error) }
            HStack {
                if store.downloadInProgress {
                    ProgressView().controlSize(.small)
                    Text("Download progress is indeterminate; output is shown as it arrives.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Download") { store.cancelDownload() }
                } else {
                    Spacer()
                    Button("Close") { dismiss() }
                    Button("Download") { beginDownload() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.capability.available || store.isShuttingDown || repositoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear { repositoryID = store.lastRepositoryID }
    }

    private func beginDownload() {
        store.download(repositoryID: repositoryID)
        if let error = store.downloadError { reportError(error) }
    }
}
