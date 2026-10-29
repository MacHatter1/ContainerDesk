import AppKit
import ContainerDeskCore
import SwiftUI

struct ExternalMLXServicesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var externalStore: ExternalMLXStore
    let mlxStore: MLXStore
    let sceneID: String
    @Binding var query: String
    var didCopyEndpoint: (URL) -> Void

    @State private var selectedID: String?
    @State private var sortOrder: [KeyPathComparator<ExternalMLXRow>] = [KeyPathComparator(\.name)]

    private var servers: [MLXExternalServerRecord] {
        let ownedPorts = Set(mlxStore.runningServers.filter { [.starting, .running, .stopping].contains($0.state) }.map(\.port))
        return externalStore.visibleServers(excludingPorts: ownedPorts)
    }

    private var rows: [ExternalMLXRow] {
        servers.flatMap { server in
            let models = server.models.isEmpty ? [nil] : server.models.map(Optional.some)
            return models.map { ExternalMLXRow(server: server, model: $0) }
        }
        .filter { row in
            query.isEmpty || row.name.localizedCaseInsensitiveContains(query) ||
                row.server.processName.localizedCaseInsensitiveContains(query) ||
                row.server.backend?.localizedCaseInsensitiveContains(query) == true ||
                row.server.endpoint.absoluteString.localizedCaseInsensitiveContains(query)
        }
        .sorted(using: sortOrder)
    }

    private var selectedRow: ExternalMLXRow? { rows.first { $0.id == selectedID } }

    var body: some View {
        GeometryReader { geometry in
            VSplitView {
                servicesTable
                    .frame(width: geometry.size.width)
                    .frame(minHeight: 170, idealHeight: 390, maxHeight: .infinity)
                serviceDetail
                    .frame(width: geometry.size.width)
                    .frame(minHeight: 240, idealHeight: 320, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let subscriptionID = externalStore.beginObserving(sceneID: sceneID)
            defer { externalStore.endObserving(subscriptionID: subscriptionID) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private var servicesTable: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "Verified loopback services", subtitle: "Current-user listeners · read only", symbol: "server.rack", tint: .teal)

            if !externalStore.hasCompletedScan && externalStore.isRefreshing {
                ContentUnavailableView {
                    ProgressView("Scanning local services…")
                } description: {
                    Text("Only verified MLX-compatible services bound to loopback are shown.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty && externalStore.scanFailure != nil {
                ContentUnavailableView {
                    Label("Local service scan failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(externalStore.scanFailure ?? "The local listener scan could not be completed.")
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await externalStore.refresh(force: true) } }
                        .disabled(externalStore.isRefreshing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label(externalStore.hasCompletedScan ? "No verified MLX services" : "Scan for running services", systemImage: "server.rack")
                } description: {
                    Text(externalStore.hasCompletedScan
                         ? "No current-user loopback service reported an MLX model endpoint. Existing processes and model files are not changed."
                         : "Refresh to inspect current-user loopback listeners for a verified MLX model endpoint.")
                } actions: {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await externalStore.refresh(force: true) } }
                        .disabled(externalStore.isRefreshing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let scanFailure = externalStore.scanFailure {
                    InlineNotice(message: "The latest scan failed: \(scanFailure)", kind: .warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                }
                Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
                    TableColumn("Model or Service", value: \.name) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.system(.body, weight: .medium)).lineLimit(1)
                            Text(row.model == nil ? "No model name reported" : row.server.processName)
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("Status") { row in
                        Label(row.server.status == .reachable ? "Reachable" : "Unavailable",
                              systemImage: row.server.status == .reachable ? "circle.fill" : "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(selectedID == row.id ? Color.white : (row.server.status == .reachable ? Color.green : Color.orange))
                    }
                    .width(min: 100, ideal: 120)
                    TableColumn("Backend") { row in Text(row.model?.backend ?? row.server.backend ?? "Not reported").foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 120, ideal: 180)
                    TableColumn("Endpoint") { row in Text(row.server.endpoint.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 160, ideal: 220)
                    TableColumn("Ownership") { _ in Label("External", systemImage: "arrow.up.right.square").font(.caption).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 105)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serviceDetail: some View {
        VStack(spacing: 0) {
            if let row = selectedRow {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(ContainerDeskTypography.detailTitle).lineLimit(1)
                        Text("External service · \(row.server.processName) · PID \(String(row.server.processID))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 6)
                    Button("Copy Endpoint", systemImage: "doc.on.doc") { didCopyEndpoint(row.server.endpoint) }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                overview(row)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("Select a running service", systemImage: "server.rack", description: Text("External services are shown separately and never receive ContainerDesk lifecycle or chat controls."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func overview(_ row: ExternalMLXRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NeutralPanel(title: "External service") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                        detailRow("Ownership", "External · managed by another process")
                        detailRow("Status", row.server.status == .reachable ? "Reachable" : "Unavailable")
                        detailRow("Process", row.server.processName)
                        detailRow("Process ID", String(row.server.processID))
                        detailRow("Endpoint", row.server.endpoint.absoluteString)
                        detailRow("Backend", row.model?.backend ?? row.server.backend ?? "Not reported")
                    }
                    HStack {
                        Button("Copy Endpoint", systemImage: "doc.on.doc") { didCopyEndpoint(row.server.endpoint) }
                        Spacer()
                        Text("Read only").font(.caption).foregroundStyle(.secondary)
                    }
                }
                NeutralPanel(title: "Model metadata") {
                    if let model = row.model {
                        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                            detailRow("Reported name", model.name)
                            detailRow("Backend", model.backend ?? row.server.backend ?? "Not reported")
                            if let contextTokens = model.contextTokens { detailRow("Context tokens", contextTokens.formatted()) }
                            if let description = model.description { detailRow("Description", description) }
                        }
                    } else {
                        Text("The service did not report a model name.").foregroundStyle(.secondary)
                    }
                    Text("Model files and their storage location are not reported by this service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let detail = row.server.detail {
                    NeutralPanel(title: "Discovery") { Text(detail).foregroundStyle(.secondary) }
                }
            }
            .padding(18)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ExternalMLXRow: Identifiable {
    let server: MLXExternalServerRecord
    let model: MLXExternalModelRecord?

    var id: String { "\(server.id)|\(model?.id ?? "service")" }
    var name: String { model?.name ?? "MLX service on port \(server.endpoint.port ?? 0)" }
}
