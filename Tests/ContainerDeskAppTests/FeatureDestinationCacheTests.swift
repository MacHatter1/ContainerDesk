import AppKit
import ContainerDeskCore
import SwiftUI
import Testing
@testable import ContainerDeskApp

@Suite(.serialized)
struct FeatureDestinationCacheTests {
    @MainActor @Test func switchingDetachesThePreviousRootAndReusesItsController() async throws {
        let fixture = DestinationCacheFixture()
        defer { fixture.close() }
        let first = try fixture.show(.containers)
        let firstConstraints = fixture.parent.view.constraints
        #expect(firstConstraints.count == 4)
        #expect(firstConstraints.allSatisfy { $0.isActive })

        let second = try fixture.show(.images)
        #expect(fixture.parent.children.count == 1)
        #expect(fixture.parent.children.first === second)
        #expect(fixture.parent.view.subviews.count == 1)
        #expect(fixture.parent.view.subviews.first === second.view)
        #expect(first.parent == nil)
        #expect(first.view.superview == nil)
        #expect(first.view.window == nil)
        #expect(first.view.isHidden)
        #expect(firstConstraints.allSatisfy { !$0.isActive })
        #expect(fixture.signal(.containers).activations.first?.isActive == false)

        let returned = try fixture.show(.containers)
        #expect(returned === first)
        #expect(!returned.view.isHidden)
        #expect(second.parent == nil)
        #expect(second.view.superview == nil)
        #expect(second.view.window == nil)
        #expect(fixture.parent.children.count == 1)
        #expect(fixture.parent.view.subviews.count == 1)
        #expect(fixture.parent.view.constraints.count == 4)
        #expect(fixture.signal(.containers).builds == 1)
        #expect(fixture.signal(.containers).activations.first?.isActive == true)
    }

    @MainActor @Test func anOrdinaryChildControllerDoesNotEvictItsCachedDestination() async throws {
        let fixture = DestinationCacheFixture()
        defer { fixture.close() }
        let first = try fixture.show(.containers)
        let layoutChild = NSViewController()
        layoutChild.view = NSView(frame: .zero)
        first.addChild(layoutChild)
        defer { layoutChild.removeFromParent() }

        _ = try fixture.show(.images)
        let returned = try fixture.show(.containers)
        #expect(returned === first)
        #expect(layoutChild.parent === first)
        #expect(fixture.signal(.containers).builds == 1)
    }

    @MainActor @Test func returningToADestinationPreservesStateButRestartsItsVisibleLifecycle() async throws {
        let fixture = DestinationCacheFixture()
        defer { fixture.close() }
        let a = fixture.signal(.containers)
        let b = fixture.signal(.images)
        let first = try fixture.show(.containers)
        try await fixture.waitUntil("A must appear and start its SwiftUI task") {
            a.stateValues == [1] && a.taskStarts == 1
        }

        _ = try fixture.show(.images)
        try await fixture.waitUntil("Detaching A must disappear and cancel its task") {
            a.disappearances == 1 && a.taskCancellations == 1
                && b.stateValues == [1] && b.taskStarts == 1
        }
        #expect(a.activations.first?.isActive == false)

        let returned = try fixture.show(.containers)
        #expect(returned === first)
        try await fixture.waitUntil("Returning A must preserve its state and restart its task") {
            a.stateValues == [1, 2] && a.taskStarts == 2
                && b.disappearances == 1 && b.taskCancellations == 1
        }
        #expect(a.builds == 1)
        #expect(a.activations.first?.isActive == true)
        #expect(b.activations.first?.isActive == false)
    }

    @MainActor @Test func cachePreservesEveryDestinationThenEvictsTheLeastRecentAdditionalKeyAndClearsGraphs() async throws {
        let fixture = DestinationCacheFixture()
        defer { fixture.close() }
        let sections = ContainerSection.allCases
        var controllers: [ContainerSection: NSHostingController<AnyView>] = [:]
        for section in sections {
            controllers[section] = try fixture.show(section)
            let signal = fixture.signal(section)
            try await fixture.waitUntil("Each cached root must mount before switching away") {
                signal.stateValues == [1] && signal.taskStarts == 1
            }
        }

        // A complete sidebar traversal must preserve every destination's root
        // and state instead of evicting earlier pages as later ones are visited.
        for section in sections {
            let controller = try fixture.show(section)
            #expect(controller === controllers[section])
            let signal = fixture.signal(section)
            #expect(signal.builds == 1)
            try await fixture.waitUntil("Every destination must retain its SwiftUI state after a full traversal") {
                signal.stateValues == [1, 2] && signal.taskStarts == 2
            }
        }
        // An unavailable variant is an additional key beyond all destinations.
        // Refresh Stacks so Containers remains the least recent entry.
        #expect(try fixture.show(.stacks) === controllers[.stacks])
        _ = try fixture.show(.kubernetes, unavailable: true)
        let additional = fixture.signal(.kubernetes, unavailable: true)
        try await fixture.waitUntil("The additional key must mount before testing eviction and clear") {
            additional.stateValues == [1] && additional.taskStarts == 1
        }
        let evicted = fixture.signal(.containers)
        try await fixture.waitUntil("Eviction must dismantle the old graph even while its controller is retained") {
            evicted.graphDismantles == 1 && evicted.taskCancellations == evicted.taskStarts
        }
        #expect(evicted.activations.first?.isActive == false)
        #expect(controllers[.containers]?.parent == nil)
        #expect(controllers[.containers]?.view.window == nil)
        #expect(controllers[.containers]?.view.superview == nil)

        let previousStateValues = evicted.stateValues
        let previousTaskStarts = evicted.taskStarts
        let rebuilt = try fixture.show(.containers)
        #expect(rebuilt !== controllers[.containers])
        try await fixture.waitUntil("An evicted destination must start with fresh SwiftUI state") {
            evicted.stateValues == previousStateValues + [1]
                && evicted.taskStarts == previousTaskStarts + 1
        }
        #expect(evicted.builds == 2)
        #expect(evicted.activations.count == 2)
        #expect(evicted.activations[0].isActive == false)
        #expect(evicted.activations[1].isActive == true)

        // Keep every controller alive externally: clearing must release their
        // SwiftUI graphs rather than relying on controller deinitialization.
        fixture.cache.clear()
        try await fixture.waitUntil("Clear must dismantle every built graph and cancel every task") {
            fixture.signals.values.allSatisfy {
                $0.graphDismantles == $0.builds && $0.taskCancellations == $0.taskStarts
            }
        }
        #expect(fixture.parent.children.isEmpty)
        #expect(fixture.parent.view.subviews.isEmpty)
        #expect(fixture.parent.view.constraints.isEmpty)
        #expect(fixture.signals.values.flatMap(\.activations).allSatisfy { !$0.isActive })
        #expect(fixture.retainedControllers.allSatisfy {
            $0.parent == nil && $0.view.superview == nil && $0.view.window == nil
        })
    }

    @MainActor @Test func scenePhaseChangesReachTheCachedRootWithoutRebuildingOrResettingItsState() async throws {
        let fixture = DestinationCacheFixture()
        defer { fixture.close() }
        let signal = fixture.signal(.containers)
        let first = try fixture.show(.containers, scenePhase: .inactive)
        try await fixture.waitUntil("The hosted root must receive its initial scene phase") {
            signal.phases.last == .inactive && signal.stateValues == [1]
        }

        let active = try fixture.show(.containers, scenePhase: .active)
        #expect(active === first)
        try await fixture.waitUntil("A phase change must reach the existing SwiftUI graph") {
            signal.phases.last == .active
        }
        #expect(signal.builds == 1)
        #expect(signal.stateValues == [1])

        #expect(try fixture.show(.containers, scenePhase: .inactive) === first)
        try await fixture.waitUntil("The cached root must also receive later inactive phases") {
            signal.phases.last == .inactive
        }
        #expect(signal.builds == 1)
        #expect(signal.stateValues == [1])
    }

    @MainActor @Test func rootsRebuildOnlyForChangedRevisionsAndCachesBelongToTheirScene() async throws {
        let firstScene = DestinationCacheFixture()
        let secondScene = DestinationCacheFixture()
        defer { firstScene.close(); secondScene.close() }
        let original = try firstScene.show(.cleanup)
        #expect(try firstScene.show(.cleanup) === original)
        #expect(firstScene.signal(.cleanup).builds == 1)

        let changed = FeatureDestinationCache.Revision(cleanupCategory: nil, unavailableReason: "Runtime unavailable")
        #expect(try firstScene.show(.cleanup, revision: changed) === original)
        #expect(firstScene.signal(.cleanup).builds == 2)
        #expect(try firstScene.show(.cleanup, revision: changed) === original)
        #expect(firstScene.signal(.cleanup).builds == 2)

        let unavailable = try firstScene.show(.cleanup, unavailable: true, revision: changed)
        #expect(unavailable !== original)
        #expect(firstScene.signal(.cleanup, unavailable: true).builds == 1)
        let otherSceneRoot = try secondScene.show(.cleanup)
        #expect(otherSceneRoot !== original)
        #expect(otherSceneRoot !== unavailable)
        #expect(secondScene.signal(.cleanup).builds == 1)

        firstScene.cache.clear()
        #expect(secondScene.parent.children.first === otherSceneRoot)
        #expect(secondScene.signal(.cleanup).activations.first?.isActive == true)
    }
}

@MainActor private final class DestinationProbeSignal {
    var builds = 0
    var stateValues: [Int] = []
    var disappearances = 0
    var taskStarts = 0
    var taskCancellations = 0
    var graphDismantles = 0
    var activations: [ResourceFeatureActivation] = []
    var phases: [ScenePhase] = []
}

@MainActor private struct DestinationLifecycleProbe: View {
    let signal: DestinationProbeSignal
    @State private var appearances = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DestinationGraphProbe(signal: signal)
            .frame(width: 80, height: 30)
            .onAppear {
                appearances += 1
                signal.stateValues.append(appearances)
                signal.phases.append(scenePhase)
            }
            .onChange(of: scenePhase) { _, phase in signal.phases.append(phase) }
            .onDisappear { signal.disappearances += 1 }
            .task { @MainActor in
                signal.taskStarts += 1
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch is CancellationError {
                    signal.taskCancellations += 1
                } catch {
                    Issue.record("The lifecycle probe's task failed without cancellation: \(error)")
                }
            }
    }
}

@MainActor private struct DestinationGraphProbe: NSViewRepresentable {
    let signal: DestinationProbeSignal

    func makeCoordinator() -> DestinationProbeSignal { signal }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: DestinationProbeSignal) {
        coordinator.graphDismantles += 1
    }
}

@MainActor private final class DestinationCacheFixture {
    let cache = FeatureDestinationCache()
    let parent = NSViewController()
    let window: NSWindow
    private(set) var signals: [FeatureDestinationCache.Key: DestinationProbeSignal] = [:]
    private(set) var retainedControllers: [NSHostingController<AnyView>] = []

    init() {
        _ = NativeTestApplication.shared
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        window = NSWindow(contentRect: parent.view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = parent
    }

    func signal(_ section: ContainerSection, unavailable: Bool = false) -> DestinationProbeSignal {
        let key = FeatureDestinationCache.Key(section: section, unavailable: unavailable)
        if let existing = signals[key] { return existing }
        let signal = DestinationProbeSignal()
        signals[key] = signal
        return signal
    }

    @discardableResult
    func show(
        _ section: ContainerSection,
        unavailable: Bool = false,
        revision: FeatureDestinationCache.Revision = .init(cleanupCategory: nil, unavailableReason: nil),
        scenePhase: ScenePhase = .active
    ) throws -> NSHostingController<AnyView> {
        let signal = signal(section, unavailable: unavailable)
        cache.show(
            key: .init(section: section, unavailable: unavailable),
            revision: revision,
            in: parent,
            cleanupNavigation: CleanupNavigationAction(),
            colorScheme: .light,
            scenePhase: scenePhase
        ) { activation in
            signal.builds += 1
            signal.activations.append(activation)
            return AnyView(DestinationLifecycleProbe(signal: signal))
        }
        parent.view.layoutSubtreeIfNeeded()
        let controller = try #require(parent.children.first as? NSHostingController<AnyView>)
        if !retainedControllers.contains(where: { $0 === controller }) {
            retainedControllers.append(controller)
        }
        return controller
    }

    func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            parent.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        try #require(condition(), "\(description)")
    }

    func close() {
        cache.clear()
        window.contentViewController = nil
        window.close()
    }
}
