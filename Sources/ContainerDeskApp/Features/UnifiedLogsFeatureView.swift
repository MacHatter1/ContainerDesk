import AppKit
import ContainerDeskCore
import SwiftUI
import UniformTypeIdentifiers

struct UnifiedLogsFeatureView: View {
    let store: AppStore
    @State private var logs = UnifiedLogsStore()
    @State private var projection = ContainerLogProjection()
    @State private var sources = Set<String>()
    @State private var selected = Set<Int>()
    @State private var query = ""
    @State private var containerFilter = ""
    @State private var showTimestamps = true
    @State private var followLatest = true
    @State private var useRange = false
    @State private var rangeStart = Date.now.addingTimeInterval(-900)
    @State private var rangeEnd = Date.now
    @State private var exportError: String?
    @State private var jumpToken = 0

    private var containers: [ResourceSummary] { store.snapshots[.containers]?.items ?? [] }
    private var logFilter: ContainerLogFilter {
        ContainerLogFilter(sources: sources, containerID: containerFilter, query: query,
            range: useRange && rangeStart <= rangeEnd ? rangeStart...rangeEnd : nil)
    }
    private struct ProjectionInput: Hashable {
        let snapshotID: UUID
        let filter: ContainerLogFilter
        let validRange: Bool
    }
    private var projectionInput: ProjectionInput {
        .init(snapshotID: logs.snapshot.id, filter: logFilter, validRange: !useRange || rangeStart <= rangeEnd)
    }
    private var visible: [ContainerLogEntry] {
        guard !useRange || rangeStart <= rangeEnd else { return [] }
        return projection.displayRows(in: logs.snapshot, matching: logFilter)
    }
    private var exportEntries: [ContainerLogEntry] {
        let rows = visible
        return selected.isEmpty ? rows : rows.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "Unified Logs", subtitle: "A single console for your containers", symbol: "text.alignleft", tint: .teal) {
                Text("\(logs.streamingIDs.count) streaming").font(.callout).foregroundStyle(.secondary)
                if projection.isFiltering { ProgressView().controlSize(.small).accessibilityLabel("Filtering logs") }
            }
            controls
            if useRange { rangeControls }
            if let exportError { InlineNotice(message: exportError, kind: .error).padding(.horizontal, 12) }
            ForEach(logs.errors.keys.sorted(), id: \.self) { id in
                HStack {
                    Label("\(id): \(logs.errors[id] ?? "")", systemImage: "exclamationmark.triangle").lineLimit(2)
                    Spacer()
                    Button("Reconnect") { logs.retry(id: id, client: store.client) }
                }.font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.vertical, 4)
            }
            console
            HStack(spacing: 12) {
                Text("\(visible.count) lines · \(selected.count) selected").monospacedDigit()
                if logs.isPaused { Text("Paused · \(logs.pendingCount) new lines") }
                Spacer()
                Text("Shift-click to select a range").foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary).padding(10).background(.bar)
            if logs.discardedCount > 0 {
                Text("\(logs.discardedCount) older lines removed. Session buffer keeps up to 20,000 lines / 4 MB of UTF-8 text.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            }
        }
        .task(id: projectionInput) {
            guard projectionInput.validRange else { return }
            do { _ = try await projection.rowsAsync(in: logs.snapshot, matching: logFilter) }
            catch is CancellationError { }
            catch { exportError = "Log filtering could not finish." }
        }
        .task(id: store.cliPath) {
            logs.stop()
            logs = UnifiedLogsStore()
            sources.removeAll()
            selected.removeAll()
            containerFilter = ""
            await store.refresh(.containers)
            guard !Task.isCancelled else { return }
            sources = Set(containers.map(\.id))
            configure()
        }
        .onChange(of: sources) { _, _ in configure(); selected.removeAll() }
        .onChange(of: query) { _, _ in selected.removeAll() }
        .onChange(of: containerFilter) { _, _ in selected.removeAll() }
        .onChange(of: useRange) { _, enabled in
            selected.removeAll()
            if enabled { rangeEnd = .now; rangeStart = rangeEnd.addingTimeInterval(-900) }
        }
        .onChange(of: rangeStart) { _, _ in selected.removeAll() }
        .onChange(of: rangeEnd) { _, _ in selected.removeAll() }
        .onChange(of: logs.entries.first?.id) { _, _ in
            if !selected.isEmpty { selected.formIntersection(Set(logs.entries.map(\.id))) }
        }
        .onDisappear { logs.stop() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu("Sources (\(sources.count))") {
                    Button("Select All") { sources = Set(containers.map(\.id)) }
                    Button("Deselect All") { sources.removeAll() }
                    Divider()
                    ForEach(containers) { item in
                        Toggle(item.title, isOn: Binding(get: { sources.contains(item.id) }, set: { enabled in
                            if enabled { sources.insert(item.id) } else { sources.remove(item.id) }
                        }))
                    }
                }.fixedSize()
                Picker("Container", selection: $containerFilter) {
                    Text("All sources").tag("")
                    ForEach(sources.sorted(), id: \.self) { id in Text(name(id)).tag(id) }
                }.frame(maxWidth: 240)
                TextField("Filter log text", text: $query).textFieldStyle(.roundedBorder)
                Button(logs.isPaused ? "Resume" : "Pause", systemImage: logs.isPaused ? "play.fill" : "pause.fill") {
                    logs.setPaused(!logs.isPaused)
                }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            HStack {
                Toggle("Timestamps", isOn: $showTimestamps)
                Toggle("Time range", isOn: $useRange)
                Spacer()
                Toggle("Follow latest", isOn: $followLatest)
                Button("Jump to Latest", systemImage: "arrow.down.to.line") {
                    useRange = false
                    logs.setPaused(false)
                    followLatest = true
                    selected.removeAll()
                    jumpToken += 1
                }
                Button("Export…", systemImage: "square.and.arrow.up", action: export).disabled(exportEntries.isEmpty)
            }.font(.callout)
            Text("Timestamps show when lines arrived. Pause freezes the console while collection continues in the bounded session buffer.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }

    private var rangeControls: some View {
        HStack {
            DatePicker("From", selection: $rangeStart, displayedComponents: [.date, .hourAndMinute])
            DatePicker("To", selection: $rangeEnd, displayedComponents: [.date, .hourAndMinute])
            if rangeStart > rangeEnd { Text("Start must precede end").foregroundStyle(.red) }
        }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            List(selection: $selected) {
                ForEach(visible) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        if showTimestamps {
                            Text(entry.receivedAt, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
                        }
                        Text(name(entry.containerID)).foregroundStyle(color(entry.containerID))
                            .frame(width: 130, alignment: .leading).lineLimit(1).truncationMode(.middle).help(entry.containerID)
                        Text(entry.message).frame(maxWidth: .infinity, alignment: .leading)
                        if entry.isStandardError { Text("stderr").foregroundStyle(.secondary).font(.caption2) }
                    }.font(.system(.caption, design: .monospaced)).tag(entry.id).id(entry.id)
                        .listRowSeparator(.hidden)
                }
            }.listStyle(.plain)
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView(sources.isEmpty ? "Choose log sources" : "No matching log lines", systemImage: "text.alignleft", description: Text("Choose containers in Sources, then adjust your filters as needed."))
                    }
                }
                .onChange(of: visible.last?.id) { _, id in
                    if followLatest, !logs.isPaused, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: followLatest) { _, follow in
                    if follow, let id = visible.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: jumpToken) { _, _ in
                    if let id = visible.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: selected) { _, ids in if !ids.isEmpty { followLatest = false } }
        }
    }

    private func configure() {
        if !containerFilter.isEmpty, !sources.contains(containerFilter) { containerFilter = "" }
        logs.configure(ids: sources, client: store.client)
    }
    private func name(_ id: String) -> String { projection.sourceNames(for: containers)[id] ?? id }
    private func color(_ id: String) -> Color {
        let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .green, .indigo, .brown]
        let hash = id.utf8.reduce(0) { ($0 * 31 + Int($1)) % 65_521 }
        return palette[hash % palette.count]
    }
    private func export() {
        let rows = exportEntries
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "container-logs.txt"
        panel.message = "Export \(rows.count) filtered \(selected.isEmpty ? "lines" : "selected lines") with arrival timestamps and container sources."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ContainerLogBuffer.export(rows).write(to: url, atomically: true, encoding: .utf8); exportError = nil }
        catch { exportError = error.localizedDescription }
    }
}
