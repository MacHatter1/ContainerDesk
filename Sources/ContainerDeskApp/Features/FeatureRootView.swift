import SwiftUI
import ContainerDeskCore

struct FeatureRootView: View {
    let section: ContainerSection
    let store: AppStore
    let mlxStore: MLXStore
    let externalMLXStore: ExternalMLXStore
    let sceneID: String
    let navigationPerformance: NavigationPerformanceTracker
    var cleanupCategory: CleanupCategory? = nil

    private let resourceSections: [ContainerSection] = [.containers, .images, .volumes, .networks, .registries, .machines]

    var body: some View {
        // The split view owns these bounds. Keep its sizing probes from
        // recursively measuring the destination's tables and native hosts.
        GeometryReader { geometry in
            destination
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle(section.title)
        .overlay(alignment: .topLeading) {
            NavigationSettleProbe(section: section, tracker: navigationPerformance)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var destination: some View {
        ZStack(alignment: .topLeading) {
            ResourceFeatureHost(section: section, store: store, sceneID: sceneID, selectedResourceIsAvailable: isAvailableResource)
                .opacity(isAvailableResource ? 1 : 0)
                .allowsHitTesting(isAvailableResource)
                .accessibilityHidden(!isAvailableResource)

            if resourceSections.contains(section), !isAvailableResource {
                unavailableContent
            } else if !resourceSections.contains(section) {
                nonResourceContent
            }
        }
    }

    private var isAvailableResource: Bool {
        resourceSections.contains(section) && {
            if case .unavailable = store.capability(for: section) { return false }
            return true
        }()
    }

    @ViewBuilder private var nonResourceContent: some View {
        if section == .mlxModels || section == .cleanup || section == .stacks || section == .logs {
            nonResourceScreen
        } else if case .unavailable = store.capability(for: section) {
            unavailableContent
        } else {
            nonResourceScreen
        }
    }

    @ViewBuilder private var unavailableContent: some View {
        if case .unavailable(let reason) = store.capability(for: section) {
            ContentUnavailableView {
                Label("\(section.title) Unavailable", systemImage: "shippingbox.circle")
            } description: {
                Text(reason)
            } actions: {
                Button("Check Again", systemImage: "arrow.clockwise") {
                    Task { await store.refreshCapabilities() }
                }
            }
        }
    }

    @ViewBuilder private var nonResourceScreen: some View {
        switch section {
        case .stacks: StackWorkspaceFeatureView(store: store)
        case .containers, .images, .volumes, .networks, .registries, .machines: EmptyView()
        case .builds: BuildFeatureView(store: store)
        case .compose: ComposeFeatureView(store: store)
        case .kubernetes: KubernetesFeatureView(store: store)
        case .system: SystemFeatureView(store: store)
        case .cleanup: CleanupFeatureView(store: store.cleanupStore, appStore: store, initialCategory: cleanupCategory)
        case .activity: ActivityFeatureView(store: store)
        case .logs: UnifiedLogsFeatureView(store: store)
        case .mlxModels: MLXFeatureView(store: mlxStore, externalStore: externalMLXStore, sceneID: sceneID)
        }
    }
}
