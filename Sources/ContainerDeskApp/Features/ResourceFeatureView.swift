import SwiftUI
import UniformTypeIdentifiers
import ContainerDeskCore

struct ResourceFeatureView: View {
    let section: ContainerSection
    let store: AppStore
    let sceneID: String
    let activation: ResourceFeatureActivation

    private var isActive: Bool { activation.isActive }
    @Environment(\.openCleanup) private var openCleanup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var state: ResourceFeatureState

    private var snapshot: ResourceSnapshot { store.snapshots[section] ?? ResourceSnapshot() }
    private var items: [ResourceSummary] {
        guard !state.query.isEmpty else { return snapshot.items }
        return snapshot.items.filter {
            $0.title.localizedCaseInsensitiveContains(state.query) ||
            $0.id.localizedCaseInsensitiveContains(state.query) ||
            ($0.subtitle?.localizedCaseInsensitiveContains(state.query) ?? false) ||
            ($0.state?.localizedCaseInsensitiveContains(state.query) ?? false) ||
            ($0.details.imageReference?.localizedCaseInsensitiveContains(state.query) ?? false) ||
            ($0.details.driver?.localizedCaseInsensitiveContains(state.query) ?? false)
        }
    }
    private var selected: ResourceSummary? {
        if let focusedResourceID = state.focusedID, state.selection.contains(focusedResourceID) { return snapshot.items.first { $0.id == focusedResourceID } }
        return sortedItems.first { state.selection.contains($0.id) }
    }
    private var sortedItems: [ResourceSummary] { items.sorted(using: state.sortOrder) }
    private var mutationsUnavailable: Bool { state.operation.isRunning || state.choosingArchive || store.limitsOperationContainerID != nil }

    var body: some View { content }

    private var content: some View {
        VStack(spacing: 0) {
            resourceActionsBar
            operationFeedback
            if let currentNotice = state.notice {
                HStack(spacing: 10) {
                    InlineNotice(message: currentNotice.message, kind: .success, title: currentNotice.title) { dismissNotice() }
                    if !state.transientText.isEmpty, selected != nil, section == .containers || section == .machines || ResourceActionRouting.supportsInspect(section) {
                        Button("View output", systemImage: "text.alignleft") {
                            state.detailTab = section == .containers || section == .machines ? .logs : .inspect
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .transition(.opacity)
                .animation(ContainerDeskMotion.animation(reduceMotion: reduceMotion), value: currentNotice.id)
            }
            VSplitView {
                resourceTable
                    .scrollPosition(id: $state.scrolledResourceID)
                    .frame(minHeight: 180, idealHeight: 400, maxHeight: .infinity)
                detailPaneContainer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .task {
            guard isActive else { return }
            await store.refresh(section)
        }
        .sheet(isPresented: $state.showingCreate, onDismiss: { state.initialImage = "" }) {
            if section == .containers || (section == .images && !state.initialImage.isEmpty) {
                ContainerRunSheet(store: store, initialImage: state.initialImage) { presentNotice($0) }
            } else {
                ResourceFormSheet(section: section, store: store, initialImage: state.initialImage) { presentNotice($0) }
            }
        }
        .sheet(isPresented: $state.showingProfiles) {
            EnvironmentProfilesSheet(store: store)
        }
        .sheet(isPresented: $state.showingAdvanced) {
            AdvancedCommandSheet(section: section, store: store) { presentNotice($0) }
        }
        .sheet(item: $state.pendingAction) { action in
            ResourceActionSheet(action: action, section: section, store: store) { newNotice, output in
                state.transientText = output
                presentNotice(newNotice)
            }
        }
        .sheet(item: $state.limitsTarget) { target in
            EditContainerLimitsSheet(container: target, store: store)
        }
        .confirmationDialog(state.actionReview?.confirmationTitle ?? "Confirm Action", isPresented: Binding(
            get: { state.actionReview != nil },
            set: { if !$0 { state.actionReview = nil } }
        ), titleVisibility: .visible, presenting: state.actionReview) { review in
            Button(review.title, role: .destructive) {
                Task { await state.operation.perform(review, using: store) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { review in
            Text(review.confirmationMessage)
        }
        .onChange(of: state.selection) { old, new in
            if let focusedResourceID = state.focusedID, !new.contains(focusedResourceID) { state.focusedID = new.first }
            if state.focusedID == nil { state.focusedID = new.first }
            if old.isEmpty != new.isEmpty { state.detailTab = .overview }
        }
        .onAppear { if isActive { updateStatsTarget() } }
        .onReceive(activation.$isActive.dropFirst().removeDuplicates()) { active in
            if active { updateStatsTarget() }
            else {
                clearStatsTargetIfNeeded()
                state.dismissPresentations()
            }
        }
        .onChange(of: state.detailTab) { old, new in
            if old == .terminal, new != .terminal { state.terminalSession.terminate() }
            if isActive { updateStatsTarget() }
        }
        .onChange(of: selected?.id) { _, _ in
            guard isActive else { return }
            state.terminalSession.terminate()
            state.detailState = ResourceDetailState()
            state.detailTab = state.requestedDetailTab ?? .overview
            state.requestedDetailTab = nil
            updateStatsTarget()
        }
        .onDisappear {
            clearStatsTargetIfNeeded()
            state.dismissPresentations()
        }
    }

    private var detailPaneContainer: some View {
        VStack(spacing: 0) {
            if let selected {
                ResourceDetailPane(resource: selected, section: section, tab: $state.detailTab, transientText: $state.transientText, store: store, limitsOperationInProgress: store.limitsOperationContainerID == selected.id, activation: activation, operationState: operationState(for: selected.id), actionsUnavailable: mutationsUnavailable, detailState: state.detailState, terminalSession: state.terminalSession) { presentNotice($0) } action: { kind in
                    requestAction(kind, for: selected)
                } onRun: { image in
                    state.initialImage = image
                    state.showingCreate = true
                } onEditLimits: {
                    state.limitsTarget = selected
                }
                .id(selected.id)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: section.symbol)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No resource selected").font(.subheadline.weight(.semibold))
                        Text("Select a row to see details and available actions.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.025))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: selected == nil ? 78 : 240, idealHeight: selected == nil ? 96 : 320, maxHeight: selected == nil ? 96 : .infinity, alignment: .top)
    }

    @ViewBuilder private var resourceTable: some View {
        switch section {
        case .containers: containersTable
        case .images: imagesTable
        case .volumes: volumesTable
        case .networks: networksTable
        case .registries: registriesTable
        case .machines: machinesTable
        default: ContentUnavailableView("No resource table", systemImage: section.symbol)
        }
    }

    private var containersTable: some View {
        Table(sortedItems, selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Container", value: \.title) { item in
                ResourceNameCell(item: item, section: .containers, title: item.title, id: shortID(item.id), isSelected: state.selection.contains(item.id))
            }
            .width(min: 155, ideal: 230)
            TableColumn("Image") { Text($0.details.imageReference.map(shortImageReference) ?? "—").lineLimit(1).foregroundStyle(.secondary) }.width(min: 120, ideal: 180)
            TableColumn("State", value: \.sortState) { item in
                if let operationStatus = operationState(for: item.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(operationStatus).font(.caption)
                    }
                } else {
                    StateBadge(state: item.state ?? "Unknown")
                }
            }.width(min: 85, ideal: 110)
            TableColumn("Ports") { Text(ports($0.details.publishedPorts)).font(.caption.monospaced()).lineLimit(1) }.width(min: 100, ideal: 150)
            TableColumn("CPU % limit") { containerCPUGauge($0, isSelected: state.selection.contains($0.id)).help(cpuGaugeHelp($0)) }.width(min: 112, ideal: 132)
            TableColumn("Memory") { containerMemoryGauge($0, isSelected: state.selection.contains($0.id)) }.width(min: 130, ideal: 150)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu(forSelectionType: String.self) { resourceContextMenu($0) }
    }

    private var imagesTable: some View {
        Table(sortedItems, selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Image", value: \.title) { item in ResourceNameCell(item: item, section: .images, title: displayTitle(item), id: imageShortID(item), isSelected: state.selection.contains(item.id)) }.width(min: 155, ideal: 230)
            TableColumn("Tag") { Text($0.details.imageTag ?? "—").foregroundStyle(.secondary) }.width(min: 90, ideal: 130)
            TableColumn("Platform") { Text($0.details.platform ?? "—").foregroundStyle(.secondary) }.width(min: 100, ideal: 130)
            TableColumn("Size") { Text($0.details.sizeBytes.map(Self.byteCount) ?? "—").monospacedDigit().foregroundStyle(.secondary) }.width(min: 75, ideal: 95)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contextMenu(forSelectionType: String.self) { resourceContextMenu($0) }
    }

    private var volumesTable: some View {
        Table(sortedItems, selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Name", value: \.title) { item in ResourceNameCell(item: item, section: .volumes, title: item.title, id: shortID(item.id), isSelected: state.selection.contains(item.id)) }.width(min: 155, ideal: 230)
            TableColumn("Driver") { Text($0.details.driver ?? "—").foregroundStyle(.secondary) }.width(min: 90, ideal: 120)
            TableColumn("Configured Capacity") { item in
                Text(item.details.sizeBytes.map(Self.byteCount) ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .help("Configured volume capacity from the runtime configuration; this is not measured disk usage.")
            }.width(min: 130, ideal: 160)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contextMenu(forSelectionType: String.self) { resourceContextMenu($0) }
    }

    private var networksTable: some View {
        Table(sortedItems, selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Name", value: \.title) { item in ResourceNameCell(item: item, section: .networks, title: item.title, id: shortID(item.id), isSelected: state.selection.contains(item.id)) }.width(min: 155, ideal: 230)
            TableColumn("Driver") { Text($0.details.driver ?? "—").foregroundStyle(.secondary) }.width(min: 90, ideal: 120)
            TableColumn("Subnet") { Text($0.details.ipv4Subnet ?? "—").foregroundStyle(.secondary) }.width(min: 120, ideal: 160)
            TableColumn("Internal") { Text($0.details.isInternal.map { $0 ? "Yes" : "No" } ?? "—").foregroundStyle(.secondary) }.width(min: 75, ideal: 90)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contextMenu(forSelectionType: String.self) { resourceContextMenu($0) }
    }

    private var registriesTable: some View {
        Table(sortedItems, selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Registry", value: \.title) { item in ResourceNameCell(item: item, section: .registries, title: item.title, id: shortID(item.id), isSelected: state.selection.contains(item.id)) }.width(min: 200, ideal: 300)
            TableColumn("Username") { Text($0.details.registryUsername ?? "—").foregroundStyle(.secondary) }.width(min: 110, ideal: 150)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contextMenu(forSelectionType: String.self) { resourceContextMenu($0) }
    }

    private var machinesTable: some View {
        Table(sortedItems, selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Machine", value: \.title) { item in ResourceNameCell(item: item, section: .machines, title: item.title, id: shortID(item.id), isSelected: state.selection.contains(item.id)) }.width(min: 155, ideal: 230)
            TableColumn("Default") { machine in
                if machine.details.isDefault == true { Label("Default", systemImage: "star.fill").font(.caption).foregroundStyle(.yellow) }
                else { Text("—").foregroundStyle(.secondary) }
            }.width(min: 85, ideal: 100)
            TableColumn("State", value: \.sortState) { StateBadge(state: $0.state ?? "Unknown") }.width(min: 85, ideal: 110)
            TableColumn("CPUs") { Text($0.details.cpuCount.map { String($0) } ?? "—").monospacedDigit() }.width(min: 55, ideal: 70)
            TableColumn("Memory") { Text(($0.details.memoryBytes ?? $0.details.memoryLimitBytes).map(Self.byteCount) ?? "—").monospacedDigit() }.width(min: 75, ideal: 95)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contextMenu(forSelectionType: String.self) { resourceContextMenu($0) }
    }

    @ViewBuilder private func resourceContextMenu(_ ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first, let resource = snapshot.items.first(where: { $0.id == id }) {
            if section == .containers {
                let running = isRunning(resource)
                let operationStatus = operationState(for: id)
                let canChange = !mutationsUnavailable
                if let operationStatus {
                    Text(operationStatus)
                } else if canChange {
                    if running {
                        Button("Stop…", systemImage: "stop.fill") { requestAction(.stop, for: resource) }
                        Button("Restart…", systemImage: "arrow.clockwise") { requestAction(.restart, for: resource) }
                    } else {
                        Button("Start", systemImage: "play.fill") { requestAction(.start, for: resource) }
                    }
                }
                Divider()
                Button("View Logs", systemImage: "text.alignleft") { showDetails(for: id, tab: .logs) }
                Button("View Stats", systemImage: "chart.xyaxis.line") { showDetails(for: id, tab: .stats) }
                if running && operationStatus == nil {
                    Button("Open Terminal", systemImage: "terminal") { showDetails(for: id, tab: .terminal) }
                }
                Button("Inspect", systemImage: "info.circle") { showDetails(for: id, tab: .inspect) }
                Divider()
                if canChange && (store.cliPath == nil || running) {
                    Menu("Advanced", systemImage: "slider.horizontal.3") {
                        if store.cliPath == nil {
                            Button("Edit Limits…", systemImage: "slider.horizontal.3") { state.limitsTarget = resource }
                        }
                        if running {
                            Button("Send Signal…", systemImage: "bolt") { requestAction(.signal, for: resource) }
                        }
                    }
                }
            } else if ResourceActionRouting.supportsInspect(section) {
                Button("Inspect", systemImage: "info.circle") { showDetails(for: id, tab: .inspect) }
                Divider()
            }
            if ResourceActionRouting.supportsDelete(section) {
                if !mutationsUnavailable {
                    Button("Delete…", systemImage: "trash", role: .destructive) { requestAction(.delete, for: resource) }
                }
            } else if section == .registries {
                Button("Log Out…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { requestAction(.logout, for: resource) }
            }
        } else if ids.count > 1 {
            Text("Choose one row to act on")
        }
    }

    private func showDetails(for id: String, tab: ResourceDetailTab) {
        if selected?.id != id { state.requestedDetailTab = tab }
        state.selection = [id]
        state.focusedID = id
        state.detailTab = tab
    }

    private func requestAction(_ kind: ResourceActionKind, for resource: ResourceSummary? = nil) {
        guard !mutationsUnavailable else { return }
        if section == .images && (kind == .load || kind == .save) {
            guard kind == .load || resource != nil else { return }
            let runtime = store.captureReviewedRuntime()
            state.choosingArchive = true
            Task {
                defer { state.choosingArchive = false }
                let url: URL?
                if kind == .save, let resource { url = await ImageArchivePanels.save(image: resource) }
                else { url = await ImageArchivePanels.load() }
                guard let url else { return }
                let review = ResourceActionOperation.Review(kind: kind, section: section, resources: kind == .save ? resource.map { [$0] } ?? [] : [], runtime: runtime, archiveURL: url)
                await state.operation.perform(review, using: store)
            }
        } else if kind == .delete || (section == .containers && [.start, .stop, .restart, .stopAll].contains(kind)) {
            let resources: [ResourceSummary]
            if kind == .stopAll {
                resources = snapshot.items.filter(isRunning)
                guard !resources.isEmpty else { return }
            } else {
                guard let resource else { return }
                if section == .containers && [.stop, .restart].contains(kind), !isRunning(resource) { return }
                if section == .containers && kind == .start && isRunning(resource) { return }
                resources = [resource]
            }
            let review = ResourceActionOperation.Review(kind: kind, section: section, resources: resources, runtime: store.captureReviewedRuntime())
            if review.requiresConfirmation { state.actionReview = review }
            else { Task { await state.operation.perform(review, using: store) } }
        } else {
            state.pendingAction = .init(kind: kind, id: resource?.id)
        }
    }

    private func operationState(for id: String) -> String? {
        guard let review = state.operation.activeReview, review.resources.contains(where: { $0.id == id }) else { return nil }
        switch review.kind {
        case .start: return "Starting…"
        case .stop, .stopAll: return "Stopping…"
        case .restart: return "Restarting…"
        case .delete: return "Deleting…"
        default: return nil
        }
    }

    @ViewBuilder private var operationFeedback: some View {
        if let review = state.operation.activeReview {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(review.progressMessage).font(.callout)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        } else if let failure = state.operation.failure {
            InlineNotice(message: failure, kind: .error, title: "Action Failed") { state.operation.clearResult() }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        } else if let currentNotice = state.operation.notice {
            InlineNotice(message: currentNotice.message, kind: .success, title: currentNotice.title) { state.operation.clearResult() }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private var resourceActionsBar: some View {
        WorkspaceHeader(title: section.title, subtitle: summaryText, symbol: section.symbol, tint: sectionTint) {
            ViewThatFits(in: .horizontal) {
                resourceActionControls(searchWidth: 148, compact: false)
                resourceActionControls(searchWidth: 86, compact: true)
            }
        }
    }

    private func resourceActionControls(searchWidth: CGFloat, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button { Task { await store.refresh(section, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh \(section.title)")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $state.query).textFieldStyle(.plain).frame(width: searchWidth)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            if section == .containers {
                Button { state.showingProfiles = true } label: {
                    if compact { Image(systemName: "square.stack") }
                    else { Label("Profiles", systemImage: "square.stack") }
                }
                .help("Manage reusable environment profiles")
            }
            Menu {
                ForEach(secondaryActions, id: \.title) { action in
                    Button(action.title, systemImage: action.symbol) {
                        if action.kind == .prune {
                            openCleanup(CleanupCategory(rawValue: section.rawValue))
                        } else {
                            requestAction(action.kind, for: selected)
                        }
                    }
                    .disabled(
                        mutationsUnavailable ||
                        (state.selection.count > 1 && requiresSingleTarget(action.kind)) ||
                        ([.start, .restart, .save].contains(action.kind) && selected == nil) ||
                        (action.kind == .start && selected.map(isRunning) == true) ||
                        (action.kind == .restart && selected.map(isRunning) != true) ||
                        (action.kind == .stopAll && !snapshot.items.contains(where: isRunning))
                    )
                }
                if section == .containers {
                    Button("Edit Limits…", systemImage: "slider.horizontal.3") {
                        state.limitsTarget = selected
                    }
                    .disabled(selected == nil || state.selection.count > 1 || store.cliPath != nil || mutationsUnavailable)
                    .help(store.cliPath != nil ? "Edit Limits requires the default Apple Container CLI; a CLI override is active" : store.limitsOperationContainerID != nil ? "A container limits recreation is already in progress" : "Recreate the selected container with new CPU and memory limits")
                }
                Divider()
                if ResourceActionRouting.supportsDelete(section) {
                    Button(state.selection.count > 1 ? "Delete One Resource…" : "Delete Selected…", systemImage: "trash", role: .destructive) {
                        requestAction(.delete, for: selected)
                    }
                    .disabled(selected == nil || state.selection.count > 1 || mutationsUnavailable)
                }
                if supportsAdvanced { Button("Advanced CLI Command…", systemImage: "terminal") { state.showingAdvanced = true } }
            } label: { Image(systemName: "ellipsis.circle") }
                .help("More actions")
            Button { state.showingCreate = true } label: {
                Label(compact ? "Create" : primaryActionTitle, systemImage: primaryActionSymbol)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)
            .help(primaryActionTitle)
        }
    }

    private var sectionTint: Color {
        switch section {
        case .stacks: .indigo
        case .containers: .green
        case .images: .blue
        case .volumes: .purple
        case .networks: .cyan
        case .registries: .orange
        case .machines: .indigo
        case .builds: .orange
        case .compose: .indigo
        case .kubernetes: .cyan
        case .system: .blue
        case .activity: .purple
        case .logs: .teal
        case .mlxModels: .teal
        case .cleanup: .teal
        }
    }

    private func presentNotice(_ value: FeatureNotice) {
        withAnimation(ContainerDeskMotion.animation(reduceMotion: reduceMotion)) { state.notice = value }
    }

    private func dismissNotice() {
        withAnimation(ContainerDeskMotion.animation(reduceMotion: reduceMotion)) { state.notice = nil }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(items.count) items").monospacedDigit().foregroundStyle(.secondary)
            snapshotState
            if let backend = store.resourceReadBackends[section] {
                Label(backend == .nativeAPI ? "Native API" : (store.cliPath == nil && store.resourceReadFallbackReasons[section] != nil ? "CLI fallback" : "CLI"), systemImage: backend == .nativeAPI ? "bolt.horizontal.circle" : "terminal")
                    .foregroundStyle(.secondary)
                    .help(store.resourceReadFallbackReasons[section] ?? "\(section.title) list source")
            }
            Spacer()
            if let fetchedAt = snapshot.fetchedAt { Text("Updated \(fetchedAt, style: .time)").foregroundStyle(.tertiary) }
        }
        .font(.caption).padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
    }

    private var summaryText: String {
        switch section {
        case .containers:
            let running = snapshot.items.filter { ($0.state ?? "").localizedCaseInsensitiveContains("running") }.count
            let stopped = snapshot.items.filter {
                let state = ($0.state ?? "").lowercased()
                return state.contains("stopped") || state.contains("exited")
            }.count
            let other = snapshot.items.count - running - stopped
            let otherSummary = other > 0 ? "  ·  \(other) other" : ""
            return "\(snapshot.items.count) containers  ·  \(running) running  ·  \(stopped) stopped\(otherSummary)"
        case .images:
            let groups = Dictionary(grouping: snapshot.items) { $0.details.digest ?? $0.details.imageReference ?? $0.id }
            let sizes = groups.values.compactMap { group in group.compactMap(\.details.sizeBytes).first }
            let total = sizes.reduce(0, +)
            return "\(snapshot.items.count) images  ·  \(sizes.count == groups.count && !groups.isEmpty ? Self.byteCount(total) : "—") total"
        default: return "\(snapshot.items.count) \(section.title.lowercased())"
        }
    }

    private var supportsAdvanced: Bool { [.containers, .images, .volumes, .networks, .machines].contains(section) }
    private func requiresSingleTarget(_ kind: ResourceActionKind) -> Bool {
        [.start, .stop, .restart, .delete, .push, .save, .logout, .setDefault, .signal].contains(kind)
    }
    private func shortID(_ id: String) -> String { id.count > 18 ? String(id.prefix(12)) + "…" : id }
    private func displayTitle(_ item: ResourceSummary) -> String {
        guard section == .images else { return item.title }
        let reference = item.details.imageRepository ?? item.details.imageReference ?? item.title
        let leaf = reference.split(separator: "/").last.map(String.init) ?? reference
        let withoutDigest = leaf.split(separator: "@", maxSplits: 1).first.map(String.init) ?? leaf
        return withoutDigest.split(separator: ":", maxSplits: 1).first.map(String.init) ?? withoutDigest
    }
    private func imageShortID(_ item: ResourceSummary) -> String {
        let digest = item.details.digest ?? item.id
        let value = digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
        return value.count > 12 ? String(value.prefix(12)) + "…" : value
    }
    private func tag(_ reference: String) -> String {
        let leaf = reference.split(separator: "/").last.map(String.init) ?? reference
        guard let colon = leaf.lastIndex(of: ":") else { return "latest" }
        return String(leaf[leaf.index(after: colon)...])
    }
    private func shortImageReference(_ reference: String) -> String { reference.split(separator: "/").last.map(String.init) ?? reference }
    private func ports(_ values: [PublishedPort]) -> String {
        guard !values.isEmpty else { return "—" }
        return values.map { port in
            guard let host = port.hostPort else { return "\(port.containerPort)/\(port.proto ?? "tcp")" }
            return "\(host)→\(port.containerPort)"
        }.joined(separator: ", ")
    }
    @ViewBuilder private func containerCPUGauge(_ resource: ResourceSummary, isSelected: Bool) -> some View {
        let metric = isRunning(resource) ? store.containerMetrics[resource.id]?.cpuPercent : nil
        if let metric, metric.isFinite {
            let allocation = cpuAllocationCount(for: resource)
            let allocationPercent = ContainerCPUUsage.allocationPercent(oneCorePercent: metric, allocatedCPUs: allocation)
            let utilization = allocationPercent.map { $0 / 100 }
            let fraction = utilization.map { min(max($0, 0), 1) }
            let warning = utilization.flatMap(utilizationWarning)
            let display = cpuDisplay(metric: metric, allocation: allocation, allocationPercent: allocationPercent, resourceTitle: resource.title, warning: warning)
            ResourceMetricGauge(
                title: "CPU",
                value: display.value,
                fraction: fraction,
                tint: utilizationTint(utilization),
                warning: warning,
                accessibilityValue: display.accessibility,
                isSelected: isSelected
            )
        } else {
            let message = isRunning(resource)
                ? "\(resource.title), measuring CPU; waiting for a second cumulative stats sample"
                : "\(resource.title), CPU usage unavailable while the container is not running"
            ResourceMetricGauge(title: "CPU", value: "—", fraction: nil, tint: .secondary, warning: nil, accessibilityValue: message, isSelected: isSelected)
        }
    }
    @ViewBuilder private func containerMemoryGauge(_ resource: ResourceSummary, isSelected: Bool) -> some View {
        let metric = isRunning(resource) ? store.containerMetrics[resource.id]?.memoryUsageBytes : nil
        let limit = resource.details.memoryLimitBytes
        if let metric, let limit, limit > 0 {
            let utilization = Double(metric) / Double(limit)
            let warning = utilizationWarning(utilization)
            let usageText = Self.byteCount(metric)
            let limitText = Self.byteCount(limit)
            ResourceMetricGauge(
                title: "Memory",
                value: "\(usageText) / \(limitText)",
                fraction: min(max(utilization, 0), 1),
                tint: utilizationTint(utilization),
                warning: warning,
                accessibilityValue: "\(resource.title), memory \(usageText) of \(limitText), \(formatPercent(utilization)) configured capacity. \(warning ?? "Normal utilization")",
                isSelected: isSelected
            )
        } else {
            let value = metric.map(Self.byteCount) ?? "—"
            let limitText = limit.map(Self.byteCount) ?? "—"
            ResourceMetricGauge(title: "Memory", value: "\(value) / \(limitText)", fraction: nil, tint: .secondary, warning: nil, accessibilityValue: "\(resource.title), memory usage or limit unavailable", isSelected: isSelected)
        }
    }
    private func isRunning(_ resource: ResourceSummary) -> Bool { (resource.state ?? "").localizedCaseInsensitiveContains("running") }
    private func updateStatsTarget() {
        store.setStatsTarget(section == .containers && state.detailTab == .stats ? selected?.id : nil, forWindow: sceneID)
    }
    private func clearStatsTargetIfNeeded() {
        guard section == .containers, state.detailTab == .stats, let id = selected?.id else { return }
        store.clearStatsTarget(id, forWindow: sceneID)
    }
    private func cpuGaugeHelp(_ resource: ResourceSummary) -> String {
        if let count = cpuAllocationCount(for: resource) {
            guard let metric = store.containerMetrics[resource.id]?.cpuPercent, metric.isFinite,
                  let allocationPercent = ContainerCPUUsage.allocationPercent(oneCorePercent: metric, allocatedCPUs: count) else {
                return "Measuring CPU. The CLI needs a second cumulative sample to calculate usage; statistics sampling takes about 2 seconds. Configured CPU limit: \(count) CPUs."
            }
            let utilization = allocationPercent / 100
            let warning = utilizationWarning(utilization).map { " \($0) utilization warning." } ?? ""
            return "CPU is shown as percent of the configured \(count)-CPU limit (\(String(format: "%.1f", allocationPercent))%). Raw usage is \(String(format: "%.1f", metric))% of one core; 100% equals one core. The ring gauges against the CPU limit.\(warning)"
        }
        if isRunning(resource), store.containerMetrics[resource.id]?.cpuPercent == nil {
            return "Measuring CPU. The CLI needs a second cumulative sample to calculate usage; statistics sampling takes about 2 seconds. The configured CPU limit is unavailable."
        }
        if let metric = store.containerMetrics[resource.id]?.cpuPercent,
           let cores = ContainerCPUUsage.coreEquivalents(oneCorePercent: metric) {
            return "CPU usage is \(String(format: "%.1f", metric))% of one core (\(String(format: "%.2f", cores)) core equivalents). Configured CPU limit is unavailable, so no limit percentage or ring is shown."
        }
        return "CPU usage is reported as percent of one core; 100% equals one core. Configured CPU limit is unavailable, so no limit percentage or ring is shown."
    }
    private func cpuAllocationCount(for resource: ResourceSummary) -> Int? {
        (resource.details.cpuCount ?? resource.details.cpuAllocation).flatMap { $0 > 0 ? $0 : nil }
    }
    private func cpuDisplay(metric: Double, allocation: Int?, allocationPercent: Double?, resourceTitle: String, warning: String?) -> (value: String, accessibility: String) {
        if let allocation, let allocationPercent {
            return (
                String(format: "%.1f%%", allocationPercent),
                "\(resourceTitle), CPU \(String(format: "%.1f", allocationPercent)) percent of the \(allocation)-CPU limit. Raw usage is \(String(format: "%.1f", metric)) percent of one core. \(warning ?? "Normal utilization")"
            )
        }
        return (
            "\(String(format: "%.1f", metric))% 1-core",
            "\(resourceTitle), CPU usage is \(String(format: "%.1f", metric)) percent of one core. Configured CPU allocation is unavailable; allocation percentage cannot be calculated."
        )
    }
    private func utilizationTint(_ ratio: Double?) -> Color {
        guard let ratio, ratio.isFinite else { return .secondary }
        if ratio >= 0.9 { return .red }
        if ratio >= 0.7 { return .orange }
        return .blue
    }
    private func utilizationWarning(_ ratio: Double) -> String? {
        guard ratio.isFinite else { return nil }
        if ratio >= 0.9 { return "High" }
        if ratio >= 0.7 { return "Elevated" }
        return nil
    }
    private func formatPercent(_ ratio: Double) -> String {
        ratio.isFinite ? String(format: "%.0f%%", ratio * 100) : "—"
    }
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private static func byteCount(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

    @ViewBuilder private var snapshotState: some View {
        switch snapshot.state {
        case .idle: Label("Not loaded", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .loading: Label("Refreshing", systemImage: "arrow.trianglehead.2.clockwise").foregroundStyle(.secondary)
        case .loaded: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
        }
    }

    private var primaryActionTitle: String {
        switch section {
        case .containers: "Run Container"
        case .images: "Pull Image"
        case .volumes: "Create Volume"
        case .networks: "Create Network"
        case .registries: "Log In"
        case .machines: "Create Machine"
        default: "Create"
        }
    }
    private var primaryActionSymbol: String {
        switch section {
        case .containers: "play.fill"
        case .images: "arrow.down.circle"
        case .registries: "person.badge.key"
        default: "plus"
        }
    }
    private var secondaryActions: [ResourceToolbarAction] {
        switch section {
        case .containers: [.init("Start Selected", "play.fill", .start), .init("Restart Selected…", "arrow.clockwise", .restart), .init("Stop All…", "stop.fill", .stopAll), .init("Remove Stopped", "trash", .prune)]
        case .images: [.init("Push Image…", "arrow.up.circle", .push), .init("Load Archive…", "archivebox", .load), .init("Save Archive…", "square.and.arrow.down", .save), .init("Prune Unused", "trash", .prune)]
        case .volumes: [.init("Prune Unused", "trash", .prune)]
        case .networks: [.init("Prune Unused", "trash", .prune)]
        case .registries: [.init("Log Out…", "rectangle.portrait.and.arrow.right", .logout)]
        case .machines: [.init("Set Default…", "star", .setDefault)]
        default: []
        }
    }
}

private struct ResourceToolbarAction: Identifiable {
    let title: String
    let symbol: String
    let kind: ResourceActionKind
    var id: String { title }
    init(_ title: String, _ symbol: String, _ kind: ResourceActionKind) { self.title = title; self.symbol = symbol; self.kind = kind }
}

private struct ResourceNameCell: View {
    let item: ResourceSummary
    let section: ContainerSection
    let title: String
    let id: String
    var isSelected = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: section.symbol).foregroundStyle(isSelected ? Color.white : Color.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.body.weight(.medium)).lineLimit(1).foregroundStyle(isSelected ? Color.white : Color.primary)
                    if item.details.isDefault == true { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                if item.id != item.title { Text(id).font(.caption.monospaced()).foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary).lineLimit(1) }
            }
        }
        .contentShape(Rectangle())
    }
}

enum ResourceDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview", logs = "Logs", terminal = "Terminal", stats = "Stats", inspect = "Inspect", files = "Files"
    var id: String { rawValue }
    static func available(for section: ContainerSection) -> [Self] {
        switch section {
        case .containers: allCases
        case .machines: [.overview, .logs, .terminal, .inspect]
        default: ResourceActionRouting.supportsInspect(section) ? [.overview, .inspect] : [.overview]
        }
    }
}

struct ResourcePendingAction: Identifiable {
    let id = UUID()
    let kind: ResourceActionKind
    var resourceID: String?
    init(kind: ResourceActionKind, id: String? = nil) { self.kind = kind; self.resourceID = id }
}

enum ResourceActionKind: String, CaseIterable, Identifiable {
    case stop, stopAll, delete, prune, push, save, load, logout, setDefault, logs, stats, exec, start, restart, signal, tag
    var id: String { rawValue }
}

struct StateBadge: View {
    let state: String
    private var color: Color {
        let lower = state.lowercased()
        if ["running", "ready", "succeeded", "active"].contains(where: { lower.contains($0) }) { return .green }
        if ["failed", "error"].contains(where: { lower.contains($0) }) { return .red }
        if ["exited", "stopped"].contains(where: { lower.contains($0) }) { return .secondary }
        return .orange
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(state).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct ContainerRuntimeBanner: View {
    let onServiceControl: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Container Runtime").font(.headline)
                Text(SystemServiceActions.stopConfirmation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Service…", action: onServiceControl)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .padding(14)
    }
}

private extension ResourceSummary {
    var sortSubtitle: String { subtitle ?? "" }
    var sortState: String { state ?? "" }
}

extension ContainerSection {
    var symbol: String {
        switch self {
        case .stacks: "square.stack.3d.up.fill"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .builds: "hammer"
        case .volumes: "externaldrive"
        case .networks: "point.3.connected.trianglepath.dotted"
        case .registries: "person.badge.key"
        case .machines: "desktopcomputer"
        case .compose: "square.3.layers.3d"
        case .kubernetes: "ship"
        case .system: "gearshape.2"
        case .activity: "clock.arrow.circlepath"
        case .logs: "text.alignleft"
        case .mlxModels: "cpu"
        case .cleanup: "sparkles"
        }
    }
}

private struct ResourceMetricGauge: View {
    let title: String
    let value: String
    let fraction: Double?
    let tint: Color
    let warning: String?
    let accessibilityValue: String
    var isSelected = false

    var body: some View {
        HStack(spacing: 5) {
            openRing
            Text(value)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            if let warning {
                Text(warning)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
        .accessibilityValue(value)
    }

    private var openRing: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke((isSelected ? Color.white : Color.secondary).opacity(isSelected ? 0.42 : 0.18), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(135))
            if let fraction, fraction.isFinite {
                let clamped = min(max(fraction, 0), 1)
                if clamped > 0 {
                    Circle()
                        .trim(from: 0, to: 0.75 * clamped)
                        .stroke(displayTint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(135))
                }
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var displayTint: Color {
        guard isSelected else { return tint }
        // Keep elevated and high readings recognizable; use a high-contrast
        // neutral ring for normal usage on the native blue selection row.
        return warning == nil ? .white : tint
    }
}
