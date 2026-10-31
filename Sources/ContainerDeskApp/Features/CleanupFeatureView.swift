import ContainerDeskCore
import SwiftUI

private struct CleanupReview: Identifiable {
    let id = UUID()
    let candidates: [CleanupCandidate]
}

struct CleanupFeatureView: View {
    let store: CleanupStore
    let appStore: AppStore
    let initialCategory: CleanupCategory?

    @State private var searchText = ""
    @State private var selectedCategory: CleanupCategory?
    @State private var selectedIDs = Set<String>()
    @State private var hasInitializedSelection = false
    @State private var previousIdentities: [String: CleanupIdentity] = [:]
    @State private var review: CleanupReview?

    init(store: CleanupStore, appStore: AppStore, initialCategory: CleanupCategory? = nil) {
        self.store = store
        self.appStore = appStore
        self.initialCategory = initialCategory
        self._selectedCategory = State(initialValue: initialCategory)
    }

    private var scan: CleanupScan? { store.scanResult }
    private var candidates: [CleanupCandidate] { scan?.candidates ?? [] }
    private var filteredCandidates: [CleanupCandidate] {
        candidates.filter { candidate in
            (selectedCategory == nil || candidate.category == selectedCategory)
                && (searchText.isEmpty || candidate.title.localizedCaseInsensitiveContains(searchText)
                    || candidate.reason.localizedCaseInsensitiveContains(searchText)
                    || candidate.resourceID.localizedCaseInsensitiveContains(searchText))
        }
    }
    private var selectedCandidates: [CleanupCandidate] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "Cleanup", subtitle: "Review unused resources before removing them", symbol: "sparkles.rectangle.stack", tint: .teal) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        if store.isRemoving {
                            Button("Stop After Current", systemImage: "stop.circle") { store.stopAfterCurrent() }
                        }
                        rescanButton
                    }
                    Menu {
                        if store.isRemoving {
                            Button("Stop After Current", systemImage: "stop.circle") { store.stopAfterCurrent() }
                        }
                        rescanButton
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let diskUsage = scan?.diskUsage { storageOverview(diskUsage) }
                    if let lastError = store.lastError {
                        InlineNotice(message: lastError, kind: .warning)
                    }
                    if let scan, !scan.warnings.isEmpty {
                        ForEach(Array(scan.warnings.enumerated()), id: \.offset) { entry in
                            InlineNotice(message: entry.element, kind: .warning)
                        }
                    }
                    if let scan, !scan.categoryFailures.isEmpty {
                        ForEach(CleanupCategory.allCases.filter { scan.categoryFailures[$0] != nil }, id: \.self) { category in
                            InlineNotice(message: "\(category.title): \(scan.categoryFailures[category] ?? "Scan failed")", kind: .error)
                        }
                    }
                    if let report = store.removalReport { removalSummary(report) }
                    if store.isRemoving {
                        AccentPanel(title: "Removing reviewed resources", symbol: "trash", tint: .orange) {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(value: Double(store.completedCount), total: Double(max(store.totalCount, 1)))
                                HStack {
                                    Text(store.currentItemTitle.map { "Checking \($0)…" } ?? "Finishing current item…")
                                        .font(.callout).lineLimit(2)
                                    Spacer()
                                    Text("\(store.completedCount) of \(store.totalCount)")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    resourceBrowser
                }
                .padding(18)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if scan == nil { await store.scan(using: appStore) }
        }
        .onChange(of: appStore.cliPath) { _, _ in
            selectedIDs.removeAll()
            hasInitializedSelection = false
        }
        .onAppear { reconcileSelection() }
        .onChange(of: initialCategory) { _, newValue in
            selectedCategory = newValue
            selectedIDs.removeAll()
            hasInitializedSelection = false
            reconcileSelection()
        }
        .onChange(of: store.generation) { _, _ in reconcileSelection() }
        .sheet(item: $review) { snapshot in reviewSheet(for: snapshot) }
        .frame(minWidth: 520, minHeight: 600)
    }

    private var rescanButton: some View {
        Button {
            Task { await store.scan(using: appStore) }
        } label: {
            if store.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                }
            } else {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
        }
        .disabled(store.isBusy)
        .help("Read current storage and unused resources")
    }

    private func storageOverview(_ usage: SystemDiskUsage) -> some View {
        AccentPanel(title: "Runtime storage", symbol: "externaldrive", tint: .teal) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    storageCard("Containers", usage.containers, symbol: "shippingbox")
                    storageCard("Images", usage.images, symbol: "cube")
                    storageCard("Volumes", usage.volumes, symbol: "externaldrive")
                    storageTotal(usage.total)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        storageCard("Containers", usage.containers, symbol: "shippingbox")
                        storageCard("Images", usage.images, symbol: "cube")
                    }
                    GridRow {
                        storageCard("Volumes", usage.volumes, symbol: "externaldrive")
                        storageTotal(usage.total)
                    }
                }
            }
        }
    }

    private func storageCard(_ title: String, _ usage: CleanupResourceUsage, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(byteLabel(usage.sizeInBytes))
                .font(.title3.weight(.semibold))
            Text("\(usage.active.map { String($0) } ?? "—") active")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text("\(usage.reclaimable.map { byteLabel($0) } ?? "—") reclaimable")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func storageTotal(_ total: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Total").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(byteLabel(total))
                .font(.title3.weight(.semibold))
            Text("runtime reported").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var resourceBrowser: some View {
        AccentPanel(title: "Unused resources", symbol: "checklist", tint: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        searchField
                        categoryPicker
                        Spacer(minLength: 4)
                        selectionActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { searchField; categoryPicker }
                        HStack { Spacer(); selectionActions }
                    }
                }

                if store.isScanning && scan == nil {
                    ProgressView("Scanning runtime resources…")
                        .frame(maxWidth: .infinity, minHeight: 230)
                } else if scan == nil {
                    FeatureEmptyState(title: "Ready to scan", message: "Scan reads runtime storage and checks each resource for active references.", symbol: "sparkles.rectangle.stack")
                        .frame(maxWidth: .infinity, minHeight: 230)
                } else if filteredCandidates.isEmpty {
                    FeatureEmptyState(title: searchText.isEmpty ? "No cleanup candidates" : "No matches", message: searchText.isEmpty ? "The scan found no eligible unused resources." : "Try a different name, ID, or category.", symbol: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 230)
                } else {
                    VStack(spacing: 0) {
                        ForEach(CleanupCategory.allCases.filter { category in filteredCandidates.contains(where: { $0.category == category }) }, id: \.self) { category in
                            categorySection(category, items: filteredCandidates.filter { $0.category == category })
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45)))
                }
            }
        }
    }

    private var searchField: some View {
        TextField("Search name, ID, or reason", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
            .accessibilityLabel("Search cleanup candidates")
    }

    private var categoryPicker: some View {
        Picker("Category", selection: $selectedCategory) {
            Text("All categories").tag(CleanupCategory?.none)
            ForEach(CleanupCategory.allCases, id: \.self) { category in
                Text(category.title).tag(Optional(category))
            }
        }
        .labelsHidden()
        .frame(width: 190)
    }

    private var selectionActions: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Button("Remove Selected", systemImage: "trash") { beginReview() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedCandidates.isEmpty || store.isBusy)
        }
    }

    private func categorySection(_ category: CleanupCategory, items: [CleanupCandidate]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: category.symbol).foregroundStyle(.indigo)
                Text(category.title).font(.subheadline.weight(.semibold))
                Text("\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if category == .volumes {
                    Text("Stored data · off by default").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.quaternary.opacity(0.35))
            ForEach(items) { candidate in
                candidateRow(candidate)
                if candidate.id != items.last?.id { Divider().padding(.leading, 44) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func candidateRow(_ candidate: CleanupCandidate) -> some View {
        Toggle(isOn: Binding(
            get: { selectedIDs.contains(candidate.id) },
            set: { isSelected in
                if isSelected { selectedIDs.insert(candidate.id) }
                else { selectedIDs.remove(candidate.id) }
            }
        )) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(candidate.reason).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Text(candidate.resourceID).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let bytes = candidate.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(candidate.category.title): \(candidate.title)")
        .help(candidate.category == .volumes ? "Removing this volume permanently deletes its stored data." : candidate.reason)
    }

    private func reviewSheet(for snapshot: CleanupReview) -> some View {
        let reviewSelection = snapshot.candidates
        return VStack(alignment: .leading, spacing: 16) {
            Label("Review removal", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.red)
            Text("The selected resources will be checked again immediately before each removal.")
                .foregroundStyle(.secondary)
            InlineNotice(message: "Removal is permanent. Removing a container deletes its writable-layer data, and removing a volume permanently deletes its stored data.", kind: .warning)
            Text("\(reviewSelection.count) exact resources")
                .font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(CleanupCategory.allCases, id: \.self) { category in
                    let count = reviewSelection.filter { $0.category == category }.count
                    if count > 0 { Label("\(count) \(category.title.lowercased())", systemImage: category.symbol) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(reviewSelection) { candidate in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(candidate.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if let bytes = candidate.sizeBytes {
                                    Text("Est. \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                                        .foregroundStyle(.secondary).fixedSize()
                                }
                            }
                            Text(candidate.resourceID).font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(candidate.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 190)
            HStack {
                Button("Cancel") { review = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove \(reviewSelection.count) Selected", systemImage: "trash", role: .destructive) {
                    let frozen = reviewSelection
                    review = nil
                    Task { await store.remove(selection: frozen, using: appStore) }
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .keyboardShortcut(.defaultAction)
                .disabled(reviewSelection.isEmpty || store.isBusy)
            }
        }
        .padding(22)
        .frame(width: 560, height: 570)
    }

    private func removalSummary(_ report: CleanupRemovalReport) -> some View {
        let removed = report.items.filter { $0.state == .removed }.count
        let skipped = report.items.filter { if case .skipped = $0.state { true } else { false } }.count
        let failed = report.items.filter { if case .failed = $0.state { true } else { false } }.count
        let unverified = report.items.filter { if case .unverified = $0.state { true } else { false } }.count
        let pending = report.items.filter { $0.state == .notAttempted }.count
        let needsAttention = failed > 0 || unverified > 0 || skipped > 0
        return AccentPanel(title: "Removal results", symbol: report.stopped ? "pause.circle" : (needsAttention ? "exclamationmark.triangle" : "checkmark.circle"), tint: needsAttention ? .orange : .green) {
            VStack(alignment: .leading, spacing: 8) {
                resultCounts(removed: removed, skipped: skipped, failed: failed, unverified: unverified, pending: pending)
                if let bytes = report.measuredDiskReductionBytes {
                    Text("Measured runtime storage reduction: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Storage reduction could not be measured from the runtime response.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(report.items) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.candidate.title).fontWeight(.medium)
                        Text(itemStateDescription(item.state)).foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
        }
    }

    private func resultCounts(removed: Int, skipped: Int, failed: Int, unverified: Int, pending: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                resultBadge("\(removed) removed", symbol: "checkmark.circle.fill", tint: .green)
                resultBadge("\(skipped) skipped", symbol: "arrowshape.turn.up.right", tint: .secondary)
                resultBadge("\(failed) failed", symbol: "xmark.circle.fill", tint: failed > 0 ? .red : .secondary)
                resultBadge("\(unverified) unverified", symbol: "questionmark.circle.fill", tint: unverified > 0 ? .orange : .secondary)
                if pending > 0 { resultBadge("\(pending) not attempted", symbol: "pause.circle", tint: .secondary) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    resultBadge("\(removed) removed", symbol: "checkmark.circle.fill", tint: .green)
                    resultBadge("\(skipped) skipped", symbol: "arrowshape.turn.up.right", tint: .secondary)
                }
                GridRow {
                    resultBadge("\(failed) failed", symbol: "xmark.circle.fill", tint: failed > 0 ? .red : .secondary)
                    resultBadge("\(unverified) unverified", symbol: "questionmark.circle.fill", tint: unverified > 0 ? .orange : .secondary)
                }
                if pending > 0 {
                    GridRow { resultBadge("\(pending) not attempted", symbol: "pause.circle", tint: .secondary); EmptyView() }
                }
            }
        }
    }

    private func resultBadge(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol).foregroundStyle(tint).fixedSize(horizontal: true, vertical: false)
    }

    private func itemStateDescription(_ state: CleanupItemState) -> String {
        switch state {
        case .removed: "Removed"
        case .skipped(let reason): "Skipped · \(reason)"
        case .failed(let reason): "Failed · \(reason)"
        case .unverified(let reason): "Unverified · \(reason)"
        case .notAttempted: "Not attempted"
        }
    }

    private func beginReview() {
        let frozenSelection = selectedCandidates
        guard !frozenSelection.isEmpty else { return }
        review = CleanupReview(candidates: frozenSelection)
    }

    private func reconcileSelection() {
        if hasInitializedSelection {
            selectedIDs = CleanupSelection.retained(selectedIDs, previous: previousIdentities, candidates: candidates)
        } else if scan != nil {
            if store.removalReport == nil {
                selectedIDs = Set(candidates.filter {
                    $0.category != .volumes && (initialCategory == nil || $0.category == initialCategory)
                }.map(\.id))
            }
            hasInitializedSelection = true
        }
        previousIdentities = candidates.reduce(into: [:]) { $0[$1.id] = $1.identity }
    }

    private func byteLabel(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
