import SwiftUI
import ContainerDeskCore

struct FeatureRootView: View {
    let section: ContainerSection
    let store: AppStore
    let mlxStore: MLXStore
    let externalMLXStore: ExternalMLXStore
    let sceneID: String
    let navigationPerformance: NavigationPerformanceTracker
    let resourceStates: ResourceFeatureStateCache
    @Binding var selectedWorkspaceID: String
    var cleanupCategory: CleanupCategory? = nil
    @State private var destinationCache = FeatureDestinationCache()

    private let resourceSections: [ContainerSection] = [.containers, .images, .volumes, .networks, .registries, .machines]

    var body: some View {
        // The split view owns these bounds. Keep its sizing probes from
        // recursively measuring the destination's tables and native hosts.
        GeometryReader { geometry in
            FeatureDestinationHost(
                cache: destinationCache,
                key: .init(section: section, unavailable: unavailableReason != nil),
                revision: .init(cleanupCategory: section == .cleanup ? cleanupCategory : nil, unavailableReason: unavailableReason),
                makeRoot: { activation in AnyView(destination(activation: activation)) }
            )
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

    @ViewBuilder private func destination(activation: ResourceFeatureActivation) -> some View {
        if let reason = unavailableReason {
            unavailableContent(reason: reason)
        } else if resourceSections.contains(section) {
            ResourceFeatureView(section: section, store: store, sceneID: sceneID, activation: activation, state: resourceStates.state(for: section))
        } else {
            nonResourceScreen
        }
    }

    private var unavailableReason: String? {
        if section == .mlxModels || section == .cleanup || section == .stacks || section == .logs {
            return nil
        }
        if case .unavailable(let reason) = store.capability(for: section) { return reason }
        return nil
    }

    private func unavailableContent(reason: String) -> some View {
        let store = store
        let title = section.title
        return ContentUnavailableView {
            Label("\(title) Unavailable", systemImage: "shippingbox.circle")
        } description: {
            Text(reason)
        } actions: {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await store.refreshCapabilities() }
            }
        }
    }

    @ViewBuilder private var nonResourceScreen: some View {
        switch section {
        case .stacks: StackWorkspaceFeatureView(store: store, selectedWorkspaceID: $selectedWorkspaceID)
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
