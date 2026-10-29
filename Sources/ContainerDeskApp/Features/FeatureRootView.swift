import SwiftUI
import ContainerDeskCore

struct FeatureRootView: View {
    let section: ContainerSection
    let store: AppStore
    let mlxStore: MLXStore
    let externalMLXStore: ExternalMLXStore
    let sceneID: String
    var cleanupCategory: CleanupCategory? = nil

    var body: some View {
        GeometryReader { geometry in
            featureContent
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private var featureContent: some View {
        Group {
            if section == .mlxModels || section == .cleanup {
                screen
            } else if case .unavailable(let reason) = store.capability(for: section) {
                ContentUnavailableView {
                    Label("\(section.title) Unavailable", systemImage: "shippingbox.circle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Check Again", systemImage: "arrow.clockwise") {
                        Task { await store.refreshCapabilities() }
                    }
                }
            } else {
                screen
            }
        }
    }

    @ViewBuilder private var screen: some View {
        switch section {
        case .containers, .images, .volumes, .networks, .registries, .machines:
            ResourceFeatureView(section: section, store: store, sceneID: sceneID)
        case .builds: BuildFeatureView(store: store)
        case .compose: ComposeFeatureView(store: store)
        case .kubernetes: KubernetesFeatureView(store: store)
        case .system: SystemFeatureView(store: store)
        case .cleanup: CleanupFeatureView(store: store.cleanupStore, appStore: store, initialCategory: cleanupCategory)
        case .activity: ActivityFeatureView(store: store)
        case .mlxModels: MLXFeatureView(store: mlxStore, externalStore: externalMLXStore, sceneID: sceneID)
        }
    }
}
