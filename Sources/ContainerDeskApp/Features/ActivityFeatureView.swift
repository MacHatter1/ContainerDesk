import SwiftUI
import ContainerDeskCore

struct ActivityFeatureView: View {
    let store: AppStore
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var retrying = false
    @State private var retryError: String?

    private var records: [OperationRecord] {
        let filtered = store.operations.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.commandPreview.localizedCaseInsensitiveContains(query) || ($0.error?.localizedCaseInsensitiveContains(query) ?? false) }
        return filtered.sorted { $0.startedAt > $1.startedAt }
    }
    private var selected: OperationRecord? { store.operations.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "Activity", subtitle: "Recent CLI operations", symbol: "clock.arrow.circlepath", tint: .purple) {
                TextField("Search activity", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, idealWidth: 200, maxWidth: 260)
                    .accessibilityLabel("Search activity")
                ViewThatFits(in: .horizontal) {
                    countLabel(compact: false)
                    countLabel(compact: true)
                }
            }
            VSplitView {
                Table(records, selection: $selectedID, sortOrder: .constant([KeyPathComparator(\OperationRecord.startedAt, order: .reverse)])) {
                    TableColumn("Operation", value: \.title) { operation in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(operation.title).font(.body.weight(.medium))
                            Text(operation.commandPreview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.width(min: 180, ideal: 320)
                    TableColumn("State", value: \.state.rawValue) { operation in StateBadge(state: operation.state.rawValue.capitalized) }.width(min: 90, ideal: 110)
                    TableColumn("Started", value: \.startedAt) { operation in Text(operation.startedAt, style: .time).monospacedDigit() }.width(min: 80, ideal: 110)
                    TableColumn("Duration") { operation in Text(duration(operation)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 70, ideal: 90)
                }
                    .frame(maxWidth: .infinity, minHeight: 190, idealHeight: 420, maxHeight: .infinity)
                Group {
                    if let selected {
                        ScrollView(.vertical) {
                            AccentPanel(title: selected.title, symbol: "clock.arrow.circlepath", tint: selected.state == .failed ? .red : .purple) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ViewThatFits(in: .horizontal) {
                                        operationControls(selected)
                                        VStack(alignment: .leading, spacing: 8) {
                                            StateBadge(state: selected.state.rawValue.capitalized)
                                            HStack {
                                                Spacer()
                                                operationButtons(selected)
                                            }
                                        }
                                    }
                                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                                        GridRow {
                                            Text("Command").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                            Text(selected.commandPreview)
                                                .font(.system(.caption, design: .monospaced))
                                                .lineLimit(2)
                                                .truncationMode(.middle)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        GridRow {
                                            Text("Exit code").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                            Text(selected.exitCode.map { String($0) } ?? "—").monospacedDigit()
                                        }
                                        GridRow {
                                            Text("Duration").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                            Text(duration(selected)).monospacedDigit()
                                        }
                                    }
                                    if let error = selected.error { InlineNotice(message: error, kind: .error) }
                                    if let retryError { InlineNotice(message: retryError, kind: .error) }
                                    Label("Output is not retained in Activity.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        FeatureEmptyState(title: "Select an operation", message: "Operation details and retry controls appear here.", symbol: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150, idealHeight: 240, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Label("Previews and outcome metadata only", systemImage: "lock.shield")
                    Spacer(minLength: 8)
                    Text("Updated live").foregroundStyle(.tertiary)
                }
                HStack {
                    Label("Metadata only", systemImage: "lock.shield")
                    Spacer(minLength: 8)
                    Text("Live").foregroundStyle(.tertiary).help("Activity updates live")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(10).background(.bar)
        }
    }

    private func duration(_ operation: OperationRecord) -> String {
        guard let end = operation.finishedAt else { return "Running" }
        let seconds = max(0, end.timeIntervalSince(operation.startedAt))
        if seconds < 1 { return "<1s" }
        return String(format: "%.1fs", seconds)
    }

    private func countLabel(compact: Bool) -> some View {
        Text(compact ? "\(records.count)" : "\(records.count) operation\(records.count == 1 ? "" : "s")")
            .font(.callout.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(records.count) operation\(records.count == 1 ? "" : "s")")
    }

    @ViewBuilder private func operationControls(_ operation: OperationRecord) -> some View {
        HStack {
            StateBadge(state: operation.state.rawValue.capitalized)
            Spacer(minLength: 8)
            operationButtons(operation)
        }
    }

    @ViewBuilder private func operationButtons(_ operation: OperationRecord) -> some View {
        if operation.state == .running && operation.canCancel {
            Button("Cancel", role: .destructive) { store.cancelOperation(operation.id) }
        }
        if operation.state == .failed && operation.canRetry {
            Button(retrying ? "Retrying…" : "Retry", systemImage: "arrow.clockwise") { Task { await retry(operation) } }
                .disabled(retrying)
        }
    }
    private func retry(_ operation: OperationRecord) async {
        retrying = true; retryError = nil
        do { _ = try await store.retryOperation(operation.id) }
        catch { retryError = error.localizedDescription }
        retrying = false
    }
}
