import AppKit
import ContainerDeskCore
import SwiftUI

/// Observable activation and environment values for one scene-local resource
/// destination. Hosting roots remain unchanged as sidebar selection changes.
@MainActor
final class ResourceFeatureActivation: ObservableObject {
    @Published private(set) var isActive: Bool
    let cleanupNavigation: CleanupNavigationAction

    init(isActive: Bool, cleanupNavigation: CleanupNavigationAction) {
        self.isActive = isActive
        self.cleanupNavigation = cleanupNavigation
    }

    func update(isActive: Bool) {
        if self.isActive != isActive { self.isActive = isActive }
    }
}

/// AppKit owns the retained hosting controllers so inactive tables keep stable
/// bounds without being relaid out as zero-sized SwiftUI siblings.
struct ResourceFeatureHost: NSViewControllerRepresentable {
    let section: ContainerSection
    let store: AppStore
    let sceneID: String
    let selectedResourceIsAvailable: Bool

    @Environment(\.openCleanup) private var cleanupNavigation

    func makeNSViewController(context: Context) -> ResourceFeatureContainerController {
        ResourceFeatureContainerController()
    }

    func updateNSViewController(_ controller: ResourceFeatureContainerController, context: Context) {
        controller.update(
            selectedSection: section,
            selectedResourceIsAvailable: selectedResourceIsAvailable,
            store: store,
            sceneID: sceneID,
            cleanupNavigation: cleanupNavigation
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: ResourceFeatureContainerController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 520, height: 360))
    }

    static func dismantleNSViewController(_ controller: ResourceFeatureContainerController, coordinator: ()) {
        controller.deactivateAndRemoveChildren()
    }
}

@MainActor
final class ResourceFeatureContainerController: NSViewController {
    private static let sections: [ContainerSection] = [
        .containers, .images, .volumes, .networks, .registries, .machines
    ]

    private var hostingControllers: [String: NSHostingController<ResourceFeatureView>] = [:]
    private var activations: [String: ResourceFeatureActivation] = [:]

    override func loadView() {
        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
    }

    func update(
        selectedSection: ContainerSection,
        selectedResourceIsAvailable: Bool,
        store: AppStore,
        sceneID: String,
        cleanupNavigation: CleanupNavigationAction
    ) {
        if selectedResourceIsAvailable, Self.sections.contains(selectedSection) {
            installIfNeeded(
                selectedSection,
                store: store,
                sceneID: sceneID,
                cleanupNavigation: cleanupNavigation
            )
        }

        for destination in Self.sections {
            let key = destination.rawValue
            guard let child = hostingControllers[key], let activation = activations[key] else { continue }
            let active = selectedResourceIsAvailable && selectedSection == destination
            activation.update(isActive: active)
            if child.view.isHidden != !active { child.view.isHidden = !active }
        }
    }

    func deactivateAndRemoveChildren() {
        for activation in activations.values { activation.update(isActive: false) }
        for child in hostingControllers.values {
            child.view.isHidden = true
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        hostingControllers.removeAll()
        activations.removeAll()
    }

    private func installIfNeeded(
        _ section: ContainerSection,
        store: AppStore,
        sceneID: String,
        cleanupNavigation: CleanupNavigationAction
    ) {
        let key = section.rawValue
        guard hostingControllers[key] == nil else { return }

        let activation = ResourceFeatureActivation(
            isActive: true,
            cleanupNavigation: cleanupNavigation
        )
        let child = NSHostingController(
            rootView: ResourceFeatureView(section: section, store: store, sceneID: sceneID, activation: activation)
        )
        // The parent supplies the page bounds. Measuring the SwiftUI tree for
        // intrinsic/min/max sizes feeds table layout back into the split view.
        child.sizingOptions = []
        activations[key] = activation
        hostingControllers[key] = child

        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.isHidden = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
