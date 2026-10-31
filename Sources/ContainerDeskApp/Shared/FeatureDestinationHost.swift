import AppKit
import ContainerDeskCore
import SwiftUI

/// Scene-local roots retain UI state without retaining inactive views in the window.
@MainActor
final class FeatureDestinationCache {
    struct Key: Hashable {
        let section: ContainerSection
        let unavailable: Bool
    }

    struct Revision: Equatable {
        let cleanupCategory: CleanupCategory?
        let unavailableReason: String?
    }

    @MainActor private final class CleanupRelay {
        var action = CleanupNavigationAction()
    }

    @MainActor private final class Entry {
        let controller: NSHostingController<AnyView>
        let activation: ResourceFeatureActivation
        var content: AnyView
        var scenePhase: ScenePhase
        var revision: Revision
        var constraints: [NSLayoutConstraint] = []

        init(root: AnyView, content: AnyView, scenePhase: ScenePhase, activation: ResourceFeatureActivation, revision: Revision) {
            controller = NSHostingController(rootView: root)
            controller.sizingOptions = []
            self.activation = activation
            self.content = content
            self.scenePhase = scenePhase
            self.revision = revision
        }
    }

    private let cleanupRelay = CleanupRelay()
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []
    private var activeKey: Key?
    // A complete sidebar traversal must not evict the pages it just warmed.
    private let capacity = ContainerSection.allCases.count

    func show(
        key: Key,
        revision: Revision,
        in container: NSViewController,
        cleanupNavigation: CleanupNavigationAction,
        colorScheme: ColorScheme,
        scenePhase: ScenePhase = .active,
        makeRoot: (ResourceFeatureActivation) -> AnyView
    ) {
        cleanupRelay.action = cleanupNavigation
        if activeKey != key, let previous = activeKey, let entry = entries[previous] {
            // A suspended sheet must not reappear when its destination is revisited.
            let hasPresentation = !(entry.controller.presentedViewControllers ?? []).isEmpty
                || entry.controller.view.window?.attachedSheet != nil
            detach(entry)
            activeKey = nil
            if hasPresentation { evict(previous) }
        }

        let entry: Entry
        if let existing = entries[key] {
            entry = existing
            if entry.revision != revision || entry.scenePhase != scenePhase {
                if entry.revision != revision { entry.content = makeRoot(entry.activation) }
                entry.controller.rootView = root(entry.content, scenePhase: scenePhase)
                entry.revision = revision
                entry.scenePhase = scenePhase
            }
        } else {
            let activation = ResourceFeatureActivation(isActive: false)
            let content = makeRoot(activation)
            entry = Entry(root: root(content, scenePhase: scenePhase), content: content, scenePhase: scenePhase,
                          activation: activation, revision: revision)
            entries[key] = entry
        }

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if entry.controller.view.appearance?.name != appearance {
            entry.controller.view.appearance = NSAppearance(named: appearance)
        }
        if activeKey != key {
            let child = entry.controller
            child.view.translatesAutoresizingMaskIntoConstraints = false
            child.view.frame = container.view.bounds
            child.view.isHidden = false
            entry.activation.update(isActive: true)
            container.addChild(child)
            container.view.addSubview(child.view)
            entry.constraints = [
                child.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
                child.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
            ]
            NSLayoutConstraint.activate(entry.constraints)
            activeKey = key
        }
        recency.removeAll { $0 == key }
        recency.append(key)
        while entries.count > capacity, let oldest = recency.first { evict(oldest) }
    }

    func clear() {
        for key in Array(entries.keys) { evict(key) }
        activeKey = nil
    }

    private func root(_ content: AnyView, scenePhase: ScenePhase) -> AnyView {
        let relay = cleanupRelay
        return AnyView(content.environment(\.scenePhase, scenePhase).environment(\.openCleanup, CleanupNavigationAction { category in
            relay.action(category)
        }))
    }

    private func detach(_ entry: Entry) {
        if let window = entry.controller.view.window,
           let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: entry.controller.view) {
            window.makeFirstResponder(nil)
        }
        entry.activation.update(isActive: false)
        entry.controller.view.isHidden = true
        NSLayoutConstraint.deactivate(entry.constraints)
        entry.constraints.removeAll()
        entry.controller.view.removeFromSuperview()
        entry.controller.removeFromParent()
    }

    private func evict(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        detach(entry)
        for presented in entry.controller.presentedViewControllers ?? [] {
            entry.controller.dismiss(presented)
        }
        entry.controller.rootView = AnyView(EmptyView())
        entry.controller.view.needsLayout = true
        entry.controller.view.layoutSubtreeIfNeeded()
        recency.removeAll { $0 == key }
        if activeKey == key { activeKey = nil }
    }
}

struct FeatureDestinationHost: NSViewControllerRepresentable {
    let cache: FeatureDestinationCache
    let key: FeatureDestinationCache.Key
    let revision: FeatureDestinationCache.Revision
    let makeRoot: (ResourceFeatureActivation) -> AnyView
    @Environment(\.openCleanup) private var cleanupNavigation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> FeatureDestinationCache { cache }

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(frame: .zero)
        return controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {
        cache.show(key: key, revision: revision, in: controller,
                   cleanupNavigation: cleanupNavigation, colorScheme: colorScheme, scenePhase: scenePhase, makeRoot: makeRoot)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSViewController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 520, height: 360))
    }

    static func dismantleNSViewController(_ controller: NSViewController, coordinator: FeatureDestinationCache) {
        coordinator.clear()
    }
}
