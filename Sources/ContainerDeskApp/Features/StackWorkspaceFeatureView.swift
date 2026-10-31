import AppKit
import ContainerDeskCore
import SwiftUI

struct StackWorkspaceFeatureView: View {
    let store: AppStore

    private let cpuUsageExplanation = "CPU is shown as fully utilized core equivalents; 1.00 core means one fully utilized CPU core."

    @Environment(\.openCleanup) private var openCleanup
    @Binding var selectedWorkspaceID: String

    @State private var searchText = ""
    @State private var detailTab: DetailTab = .overview
    @State private var pendingAction: PendingStackAction?
    @State private var isRunningAction = false
    @State private var actionError: String?
    @State private var logBuffer = ContainerLogBuffer(maxEntries: 2_000, maxBytes: 120_000)
    @State private var logSearch = ""
    @State private var logTasks: [Task<Void, Never>] = []
    @State private var logOperationIDs: [UUID] = []
    @State private var activeLogStreamIDs: Set<UUID> = []
    @State private var followingLogs = false
    @State private var compactDetailHeader = true
    @State private var editorRequest: StackEditorRequest?
    @State private var runStack: ManagedStack?
    @State private var deletingStack: ManagedStack?

    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        var id: String { rawValue }
    }

    private struct PendingStackAction {
        let action: StackWorkspaceAction
        let workspaceID: String
        let containerIDs: Set<String>
    }

    private var workspaces: [StackWorkspace] {
        store.stackWorkspaces
    }

    private var filteredWorkspaces: [StackWorkspace] {
        guard !searchText.isEmpty else { return workspaces }
        return workspaces.filter { workspace in
            workspace.title.localizedCaseInsensitiveContains(searchText)
                || workspace.containers.contains { container in
                    container.title.localizedCaseInsensitiveContains(searchText)
                        || (container.details.imageReference?.localizedCaseInsensitiveContains(searchText) ?? false)
                        || container.id.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    private var selectedWorkspace: StackWorkspace? {
        filteredWorkspaces.first { $0.id == selectedWorkspaceID }
            ?? filteredWorkspaces.first
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "Stacks", subtitle: "Operate related containers together", symbol: "square.stack.3d.up.fill", tint: .indigo) {
                TextField("Search stacks and containers", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, idealWidth: 200, maxWidth: 260)
                    .accessibilityLabel("Search stacks and containers")
                Button("New Stack", systemImage: "plus") { editorRequest = StackEditorRequest() }
                    .disabled(isRunningAction || store.managedStacks.loadError != nil)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refreshWorkspaceResources(force: true) }
                }
                .disabled(isRunningAction)
            }

            if let error = store.managedStacks.loadError {
                HStack {
                    InlineNotice(message: error, kind: .error)
                    Button("Reload Library") { store.managedStacks.reload() }
                }
                .padding(12)
            }
            if let actionError {
                InlineNotice(message: actionError, kind: .error) { self.actionError = nil }
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }

            if workspaces.isEmpty {
                ContentUnavailableView {
                    Label("No Stacks Yet", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Create a stack, then add existing containers or run new ones into it. Shared project labels are also discovered automatically.")
                } actions: {
                    Button("Create Stack", systemImage: "plus") { editorRequest = StackEditorRequest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.managedStacks.loadError != nil)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    workspaceList
                        .frame(minWidth: 205, idealWidth: 255, maxWidth: 320)
                    Divider()
                    if let selectedWorkspace {
                        workspaceDetail(selectedWorkspace)
                    } else {
                        ContentUnavailableView("No Matching Stacks", systemImage: "magnifyingglass", description: Text("Try another search."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            footer
        }
        .task {
            await refreshWorkspaceResources()
            if selectedWorkspaceID.isEmpty { selectedWorkspaceID = filteredWorkspaces.first?.id ?? "" }
        }
        .onChange(of: filteredWorkspaces.map(\.id)) { _, identities in
            if !identities.contains(selectedWorkspaceID) { selectedWorkspaceID = identities.first ?? "" }
        }
        .onChange(of: selectedWorkspaceID) { _, _ in
            stopFollowingLogs()
            logBuffer = ContainerLogBuffer(maxEntries: 2_000, maxBytes: 120_000)
            actionError = nil
        }
        .onChange(of: detailTab) { _, tab in
            if tab != .logs { stopFollowingLogs() }
        }
        .onChange(of: selectedWorkspace?.containers.map(\.id)) { _, _ in stopFollowingLogs() }
        .onChange(of: store.managedStacks.runtimeScope) { _, _ in
            editorRequest = nil
            runStack = nil
            deletingStack = nil
            pendingAction = nil
            stopFollowingLogs()
        }
        .sheet(item: $editorRequest) { request in
            StackEditorSheet(store: store, request: request) { saved in
                searchText = ""
                selectedWorkspaceID = saved.workspaceID
            }
        }
        .sheet(item: $runStack) { stack in
            ContainerRunSheet(store: store, stackID: stack.id) { _ in }
        }
        .alert("Delete Stack?", isPresented: Binding(get: { deletingStack != nil }, set: { if !$0 { deletingStack = nil } })) {
            Button("Delete Stack", role: .destructive) {
                if let deletingStack {
                    do { try store.managedStacks.delete(deletingStack) }
                    catch { actionError = error.localizedDescription }
                }
                deletingStack = nil
            }
            Button("Cancel", role: .cancel) { deletingStack = nil }
        } message: {
            Text("Remove the saved stack and ungroup its containers. The containers keep running and their data is preserved.")
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(confirmationButtonTitle(pendingAction.action), role: .destructive) {
                    let action = pendingAction
                    self.pendingAction = nil
                    Task { await perform(action.action, workspaceID: action.workspaceID, expectedContainerIDs: action.containerIDs) }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(confirmationMessage)
        }
        .onDisappear { stopFollowingLogs() }
    }

    private var workspaceList: some View {
        List(selection: Binding(
            get: { selectedWorkspaceID.isEmpty ? nil : selectedWorkspaceID },
            set: { selectedWorkspaceID = $0 ?? "" }
        )) {
            ForEach(filteredWorkspaces) { workspace in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(workspace.allowsLifecycleActions ? .indigo : .secondary)
                        Text(workspace.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        StateBadge(state: workspaceState(workspace))
                        Text("\(workspace.containers.count) container\(workspace.containers.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(workspace.id)
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func workspaceDetail(_ workspace: StackWorkspace) -> some View {
        VStack(spacing: 0) {
            detailHeader(workspace)
            DetailTabStrip(selection: Binding(
                get: { detailTab.rawValue },
                set: { detailTab = DetailTab(rawValue: $0) ?? .overview }
            ), tabs: DetailTab.allCases.map(\.rawValue))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Divider()
            Group {
                switch detailTab {
                case .overview: overview(workspace)
                case .logs: logs(workspace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Bool.self) { $0.size.width < 720 } action: { compactDetailHeader = $0 }
    }

    private func detailHeader(_ workspace: StackWorkspace) -> some View {
        Group {
            if compactDetailHeader {
                VStack(alignment: .leading, spacing: 10) {
                    identity(workspace)
                    actionButtons(workspace)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    identity(workspace)
                        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    actionButtons(workspace)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func identity(_ workspace: StackWorkspace) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 38, height: 38)
                .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(groupingDescription(workspace.grouping))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func actionButtons(_ workspace: StackWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Button("Start", systemImage: "play.fill") { request(.start, workspace) }
                    .disabled(!canOperate(workspace) || isRunningAction || workspace.stoppedCount == 0)
                Button("Restart", systemImage: "arrow.clockwise") { request(.restart, workspace) }
                    .disabled(!canOperate(workspace) || isRunningAction || workspace.runningCount == 0)
                Button("Stop", systemImage: "stop.fill", role: .destructive) { request(.stop, workspace) }
                    .disabled(!canOperate(workspace) || isRunningAction || workspace.runningCount == 0)
                Menu {
                    Button("Review Cleanup…", systemImage: "sparkles") { openCleanup() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Review stack cleanup")
            }
            StackManagementActions(stack: managedStack(for: workspace), disabled: isRunningAction || store.managedStacks.loadError != nil) {
                let original = managedStack(for: workspace)
                editorRequest = StackEditorRequest(original: original, name: original?.name ?? workspace.title, containerIDs: original?.containerIDs ?? Set(workspace.containers.map(\.id)))
            } run: { runStack = $0 } delete: { deletingStack = $0 }
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func overview(_ workspace: StackWorkspace) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !workspace.allowsLifecycleActions {
                    InlineNotice(
                        message: "Review these containers and save an editable stack to manage membership and enable stack-wide actions.",
                        kind: .info,
                        title: workspace.grouping.isStandalone ? "Ungrouped container" : "Inferred grouping"
                    )
                }

                AccentPanel(title: "Stack status", symbol: "waveform.path", tint: .indigo) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { statusCounts(workspace); metrics(workspace) }
                        VStack(alignment: .leading, spacing: 10) { statusCounts(workspace); metrics(workspace) }
                    }
                }

                AccentPanel(title: "Containers", symbol: "shippingbox", tint: .green) {
                    VStack(spacing: 0) {
                        if workspace.containers.isEmpty {
                            Text("No containers currently available. Use Manage Containers to add existing ones, or Run Container to launch a new member.")
                                .foregroundStyle(.secondary).padding(.vertical, 14)
                        }
                        ForEach(Array(workspace.containers.enumerated()), id: \.element.id) { index, container in
                            containerRow(container, workspace: workspace)
                            if index < workspace.containers.count - 1 { Divider().padding(.leading, 26) }
                        }
                    }
                }
                if !workspace.missingContainerIDs.isEmpty, let stack = managedStack(for: workspace) {
                    AccentPanel(title: "Unavailable containers", symbol: "shippingbox", tint: .secondary) {
                        ForEach(workspace.missingContainerIDs, id: \.self) { id in
                            HStack {
                                Text(id).font(.callout.monospaced()).lineLimit(1)
                                Spacer()
                                StackMemberMenu(containerID: id, containerTitle: id, stack: stack, library: store.managedStacks) { actionError = $0 }
                            }
                        }
                    }
                }

                if !workspace.images.isEmpty {
                    relatedResources(title: "Images", symbol: "square.stack.3d.up", resources: workspace.images)
                }
                if !workspace.networks.isEmpty {
                    relatedResources(title: "Networks", symbol: "point.3.connected.trianglepath.dotted", resources: workspace.networks)
                }
                if !workspace.volumes.isEmpty {
                    relatedResources(title: "Volumes", symbol: "externaldrive", resources: workspace.volumes)
                }
            }
            .padding(16)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func statusCounts(_ workspace: StackWorkspace) -> some View {
        HStack(spacing: 14) {
            Label("\(workspace.runningCount) running", systemImage: "play.circle.fill").foregroundStyle(.green)
            if workspace.stoppedCount > 0 { Label("\(workspace.stoppedCount) stopped", systemImage: "stop.circle.fill").foregroundStyle(.secondary) }
            if workspace.otherCount > 0 { Label("\(workspace.otherCount) other", systemImage: "ellipsis.circle.fill").foregroundStyle(.orange) }
        }
        .font(.callout)
    }

    private func metrics(_ workspace: StackWorkspace) -> some View {
        HStack(spacing: 16) {
            Label {
                Text(workspace.cpuPercent.map { coreEquivalentSummary($0, suffix: " CPU") } ?? "CPU —")
                    .monospacedDigit()
            } icon: { Image(systemName: "cpu") }
                .help(cpuUsageExplanation)
            Label {
                Text(memorySummary(workspace))
                    .monospacedDigit()
            } icon: { Image(systemName: "memorychip") }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityHint(cpuUsageExplanation)
        .help(cpuUsageExplanation)
    }

    private func containerRow(_ container: ResourceSummary, workspace: StackWorkspace) -> some View {
        let metric = store.containerMetrics[container.id]
        return HStack(spacing: 10) {
            StateBadge(state: container.state ?? "Unknown")
            VStack(alignment: .leading, spacing: 3) {
                Text(container.title).font(.body.weight(.medium)).lineLimit(1)
                if let image = container.details.imageReference {
                    Text(image).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(portSummary(container.details.publishedPorts)).font(.caption.monospaced()).lineLimit(1)
                Text(memberMetricSummary(metric)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(cpuUsageExplanation)
            }
            if let stack = managedStack(for: workspace) {
                StackMemberMenu(containerID: container.id, containerTitle: container.title, stack: stack, library: store.managedStacks) { actionError = $0 }
                    .disabled(isRunningAction)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityHint(cpuUsageExplanation)
    }

    private func relatedResources(title: String, symbol: String, resources: [ResourceSummary]) -> some View {
        AccentPanel(title: title, symbol: symbol, tint: .secondary) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(resources) { resource in
                    HStack(spacing: 8) {
                        Image(systemName: symbol).foregroundStyle(.secondary)
                        Text(resource.title).lineLimit(1)
                        Spacer()
                        if let detail = resource.details.imageReference ?? resource.details.driver {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func logs(_ workspace: StackWorkspace) -> some View {
        VStack(spacing: 8) {
            HStack {
                Label("Merged Container Logs", systemImage: "text.alignleft").font(.headline)
                TextField("Search logs", text: $logSearch).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer(minLength: 8)
                Toggle("Follow", isOn: $followingLogs)
                    .toggleStyle(.switch)
                    .onChange(of: followingLogs) { _, enabled in
                        if enabled { startFollowingLogs(workspace) } else { stopFollowingLogs() }
                    }
                Button("Copy", systemImage: "doc.on.doc") { copyVisibleLogs() }
                    .disabled(visibleLogText.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if workspace.containers.isEmpty {
                ContentUnavailableView("No Containers", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(visibleLogText.isEmpty ? (followingLogs ? "Waiting for log output…" : "Turn on Follow to stream logs from every container in this stack.") : visibleLogText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .padding(10)
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }

    private var visibleLogText: String {
        let logText = logBuffer.entries.map { "[\($0.containerID)] \($0.message)\n" }.joined()
        guard !logSearch.isEmpty else { return logText }
        return logText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(logSearch) }
            .joined(separator: "\n")
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text("\(workspaces.count) stack\(workspaces.count == 1 ? "" : "s")")
                .monospacedDigit()
            Spacer()
            if let fetchedAt = store.snapshots[.containers]?.fetchedAt {
                Text("Updated \(fetchedAt, style: .time)").foregroundStyle(.tertiary)
            }
            if isRunningAction { ProgressView().controlSize(.small); Text("Running stack action…") }
            else if followingLogs { ProgressView().controlSize(.small); Text("Following logs") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var confirmationTitle: String {
        guard let workspace = pendingWorkspace, let pendingAction else { return "Confirm Stack Action" }
        switch pendingAction.action {
        case .stop: return "Stop \(workspace.title)?"
        case .restart: return "Restart \(workspace.title)?"
        case .start: return "Start \(workspace.title)?"
        }
    }

    private var confirmationMessage: String {
        guard let workspace = pendingWorkspace, let pendingAction else { return "" }
        switch pendingAction.action {
        case .stop: return "All \(workspace.runningCount) running containers in this stack will stop gracefully."
        case .restart: return "All \(workspace.runningCount) running containers in this stack will stop, then those containers will start again."
        case .start: return "Stopped containers in this stack will start."
        }
    }

    private func request(_ action: StackWorkspaceAction, _ workspace: StackWorkspace) {
        guard canOperate(workspace) else { return }
        let members = Set(workspace.containers.map(\.id))
        if action == .start { Task { await perform(action, workspaceID: workspace.id, expectedContainerIDs: members) } }
        else { pendingAction = PendingStackAction(action: action, workspaceID: workspace.id, containerIDs: members) }
    }

    private func confirmationButtonTitle(_ action: StackWorkspaceAction) -> String {
        switch action {
        case .start: "Start Stack"
        case .stop: "Stop Stack"
        case .restart: "Restart Stack"
        }
    }

    private var pendingWorkspace: StackWorkspace? {
        guard let pendingAction else { return nil }
        return workspaces.first { $0.id == pendingAction.workspaceID }
    }

    @MainActor private func perform(_ action: StackWorkspaceAction, workspaceID: String, expectedContainerIDs: Set<String>) async {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }), canOperate(workspace) else { return }
        guard Set(workspace.containers.map(\.id)) == expectedContainerIDs else {
            actionError = "Stack membership changed. Review the containers and try again."
            return
        }
        let runtime = store.managedStacks.runtimeScope
        let client = store.client
        isRunningAction = true
        actionError = nil
        defer { isRunningAction = false }
        do {
            let plan = StackWorkspaceCatalog.plan(action, for: workspace)
            for command in plan {
                guard store.managedStacks.runtimeScope == runtime else { throw ManagedStackError.runtimeChanged }
                guard let current = workspaces.first(where: { $0.id == workspaceID }),
                      Set(current.containers.map(\.id)) == expectedContainerIDs else { throw ManagedStackError.staleStack }
                let phaseName = command.phase == .stop ? "Stop" : "Start"
                _ = try await store.execute(
                    CommandRequest(arguments: command.arguments),
                    title: "\(phaseName) Stack · \(workspace.title)", using: client
                )
            }
            guard store.managedStacks.runtimeScope == runtime else { throw ManagedStackError.runtimeChanged }
            await store.refresh(.containers, force: true)
            await store.refresh(.images, force: true)
            await store.refresh(.volumes, force: true)
            await store.refresh(.networks, force: true)
        } catch {
            actionError = error.localizedDescription
            await store.refresh(.containers, force: true)
        }
    }

    @MainActor private func refreshWorkspaceResources(force: Bool = false) async {
        await store.refresh(.containers, force: force)
        await store.refresh(.images, force: force)
        await store.refresh(.volumes, force: force)
        await store.refresh(.networks, force: force)
    }

    @MainActor private func startFollowingLogs(_ workspace: StackWorkspace) {
        cancelLogStreams()
        guard !workspace.containers.isEmpty else { followingLogs = false; return }
        followingLogs = true
        logBuffer = ContainerLogBuffer(maxEntries: 2_000, maxBytes: 120_000)
        logOperationIDs = []
        for container in workspace.containers {
            let stream = store.streamWithID(
                CommandRequest(arguments: ["logs", container.id, "--follow"], captureLimit: 500_000),
                title: "Follow Stack Logs · \(container.title)"
            )
            logOperationIDs.append(stream.operationID)
            activeLogStreamIDs.insert(stream.operationID)
            let label = container.title
            let operationID = stream.operationID
            let events = stream.events
            let task = Task { @MainActor in
                do {
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .standardOutput(let chunk):
                            logBuffer.append(chunk, containerID: label)
                        case .standardError(let chunk):
                            logBuffer.append(chunk, containerID: label, stderr: true)
                        case .completed(let result):
                            if !result.succeeded {
                                logBuffer.append("Command exited with status \(result.exitCode).\n", containerID: label, stderr: true)
                            }
                        }
                    }
                } catch is CancellationError {
                    store.cancelOperation(operationID)
                } catch {
                    if activeLogStreamIDs.contains(operationID) {
                        logBuffer.append(error.localizedDescription + "\n", containerID: label, stderr: true)
                    }
                }
                if activeLogStreamIDs.contains(operationID) { logBuffer.finish(containerID: label) }
                finishLogStream(operationID)
            }
            logTasks.append(task)
        }
    }

    @MainActor private func stopFollowingLogs() {
        followingLogs = false
        cancelLogStreams()
    }

    @MainActor private func cancelLogStreams() {
        logBuffer.finishAll()
        for task in logTasks { task.cancel() }
        logTasks.removeAll()
        for id in logOperationIDs { store.cancelOperation(id) }
        logOperationIDs.removeAll()
        activeLogStreamIDs.removeAll()
    }

    @MainActor private func finishLogStream(_ operationID: UUID) {
        guard activeLogStreamIDs.remove(operationID) != nil else { return }
        logOperationIDs.removeAll { $0 == operationID }
        if activeLogStreamIDs.isEmpty { followingLogs = false }
    }

    private func copyVisibleLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleLogText, forType: .string)
    }

    private func workspaceState(_ workspace: StackWorkspace) -> String {
        if workspace.containers.isEmpty { return workspace.missingContainerIDs.isEmpty ? "Empty" : "Unavailable" }
        if workspace.runningCount == workspace.containers.count { return "Running" }
        if workspace.runningCount == 0 && workspace.stoppedCount == workspace.containers.count { return "Stopped" }
        if workspace.runningCount > 0 { return "Partial" }
        return "Unknown"
    }

    private func groupingDescription(_ grouping: StackWorkspaceGrouping) -> String {
        switch grouping {
        case .managed: "Saved stack · editable membership"
        case .explicitLabel(let key, _): "Verified · \(key)"
        case .sharedNamePrefix: "Inferred from container names"
        case .standalone: "Single container · ungrouped"
        }
    }

    private func managedStack(for workspace: StackWorkspace) -> ManagedStack? {
        guard case .managed(let id) = workspace.grouping else { return nil }
        return store.managedStacks.stacks.first { $0.id == id }
    }

    private func canOperate(_ workspace: StackWorkspace) -> Bool {
        workspace.allowsLifecycleActions && (managedStack(for: workspace) == nil || store.managedStacks.loadError == nil)
    }

    private func memorySummary(_ workspace: StackWorkspace) -> String {
        guard let used = workspace.memoryUsageBytes else { return "Memory —" }
        let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)
        guard let limit = workspace.memoryLimitBytes else { return "\(usedText) memory" }
        return "\(usedText) / \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory))"
    }

    private func memberMetricSummary(_ metric: ContainerMetric?) -> String {
        guard let metric else { return "CPU — · RAM —" }
        let cpu = metric.cpuPercent.map { coreEquivalentSummary($0) } ?? "—"
        let memory = metric.memoryUsageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—"
        return "CPU \(cpu) · RAM \(memory)"
    }

    private func coreEquivalentSummary(_ oneCorePercent: Double, suffix: String = "") -> String {
        guard let coreEquivalents = ContainerCPUUsage.coreEquivalents(oneCorePercent: oneCorePercent) else {
            return "CPU —"
        }
        let rounded = String(format: "%.2f", coreEquivalents)
        let isOneCore = abs(coreEquivalents - 1) < 0.005
        return "\(rounded) \(isOneCore ? "core" : "cores")\(suffix)"
    }

    private func portSummary(_ ports: [PublishedPort]) -> String {
        guard !ports.isEmpty else { return "No published ports" }
        return ports.map { port in
            guard let hostPort = port.hostPort else { return "\(port.containerPort)/\(port.proto ?? "tcp")" }
            return "\(hostPort)→\(port.containerPort)"
        }.joined(separator: ", ")
    }
}
