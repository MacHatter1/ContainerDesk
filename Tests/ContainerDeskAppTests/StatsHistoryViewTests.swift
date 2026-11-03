import AppKit
import ApplicationServices
import ContainerDeskCore
import Observation
import QuartzCore
import SwiftUI
import Testing
@testable import ContainerDeskApp

@Suite(.serialized)
struct StatsHistoryViewTests {
    @MainActor @Test
    func resizingKeepsTheNativePickerAndBothChartsAtTheSelectedRange() async throws {
        _ = NativeTestApplication.shared
        let suite = "StatsResize.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitoring = ContainerMonitoringStore(defaults: defaults, notificationHandler: { _, _ in })
        let container = ResourceSummary(id: "web", title: "web", state: "running")
        monitoring.observe([container])
        monitoring.append(["web": .init(cpuPercent: 12, memoryUsageBytes: 4_194_304)], containers: [container])
        let size = StatsResizeControl()
        let host = NSHostingView(rootView: StatsResizeTestRoot(monitoring: monitoring, size: size))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await wait(host) { strings(host).contains { $0.contains("Memory latest, 4.0 MiB") } }
        let picker = try #require(descendants(host, as: NSSegmentedControl.self).first)
        choose(1, in: picker)
        for width in [600.0, 1_200, 600, 1_200] {
            size.width = width
            window.setContentSize(NSSize(width: width, height: 800))
            try await wait(host) {
                let labels = strings(host)
                return ["CPU", "Memory"].allSatisfy { metric in
                    labels.contains { $0.hasPrefix("\(metric) over the last 60 minutes") }
                }
            }
            #expect(descendants(host, as: NSSegmentedControl.self).first === picker)
            #expect(picker.selectedSegment == 1)
            #expect(strings(host).contains { $0.contains("Memory latest, 4.0 MiB") })
        }
    }

    @MainActor @Test
    func backgroundWindowStopsPresentationButInactiveVisibleWindowKeepsUpdating() async throws {
        _ = NativeTestApplication.shared
        let suite = "StatsScenePhase.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitoring = ContainerMonitoringStore(defaults: defaults, notificationHandler: { _, _ in })
        let container = ResourceSummary(id: "web", title: "web", state: "running")
        let activation = ResourceFeatureActivation(isActive: true)
        monitoring.observe([container])
        monitoring.append(["web": .init(memoryUsageBytes: 4_194_304)], containers: [container])
        let host = NSHostingView(rootView: StatsActivationTestRoot(monitoring: monitoring, activation: activation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await wait(host) { strings(host).contains { $0.contains("Memory latest, 4.0 MiB") } }
        host.rootView = StatsActivationTestRoot(monitoring: monitoring, activation: activation, phase: .background)
        try await allowRefreshCycles(host)
        monitoring.append(["web": .init(memoryUsageBytes: 8_388_608)], containers: [container])
        try await allowRefreshCycles(host)
        #expect(strings(host).contains { $0.contains("Memory latest, 4.0 MiB") }, "Background Stats must not publish while collection continues")
        host.rootView = StatsActivationTestRoot(monitoring: monitoring, activation: activation, phase: .inactive)
        try await wait(host) { strings(host).contains { $0.contains("Memory latest, 8.0 MiB") } }
    }

    @MainActor @Test
    func changingRangeUsesTheSameCoherentHourOfHistoryWithoutAnEmptyPublication() async throws {
        _ = NativeTestApplication.shared
        let suite = "StatsRangePublication.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitoring = ContainerMonitoringStore(defaults: defaults, notificationHandler: { _, _ in })
        let container = ResourceSummary(id: "web", title: "web", state: "running")
        let now = Date.now
        monitoring.observe([container], at: now.addingTimeInterval(-1_200))
        monitoring.append(["web": .init(memoryUsageBytes: 1_048_576)], containers: [container], at: now.addingTimeInterval(-1_200))
        monitoring.append(["web": .init(memoryUsageBytes: 4_194_304)], containers: [container], at: now)
        let host = NSHostingView(rootView: ScrollView {
            ContainerMetricsHistoryView(containerID: "web", monitoring: monitoring, refreshInterval: .seconds(3_600)).padding(16)
        }.frame(width: 1_200, height: 700).environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await wait(host) { strings(host).contains { $0.contains("Memory latest, 4.0 MiB") } }
        monitoring.append(["web": .init(memoryUsageBytes: 8_388_608)], containers: [container], at: now.addingTimeInterval(1))
        choose(1, in: try #require(descendants(host, as: NSSegmentedControl.self).first))
        try await wait(host) { strings(host).contains { $0.contains("60 minutes, 2 samples") } }
        #expect(strings(host).contains { $0.contains("Memory latest, 4.0 MiB") })
        #expect(monitoring.history.latestSample(for: "web")?.metric.memoryUsageBytes == 8_388_608)
    }

    @MainActor @Test
    func inactiveHistoryStopsPublishingAndReturnsWithFreshSamples() async throws {
        _ = NativeTestApplication.shared
        let suite = "StatsActivation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitoring = ContainerMonitoringStore(defaults: defaults, notificationHandler: { _, _ in })
        let container = ResourceSummary(id: "web", title: "web", state: "running")
        let activation = ResourceFeatureActivation(isActive: true)
        monitoring.observe([container])
        monitoring.append(["web": .init(memoryUsageBytes: 4_194_304)], containers: [container])
        let host = NSHostingView(rootView: StatsActivationTestRoot(monitoring: monitoring, activation: activation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await wait(host) { strings(host).contains { $0.contains("Memory latest, 4.0 MiB") } }
        for value in 5...9 {
            activation.update(isActive: false)
            try await allowRefreshCycles(host)
            monitoring.append(["web": .init(memoryUsageBytes: Int64(value) * 1_048_576)], containers: [container])
            try await allowRefreshCycles(host)
            #expect(monitoring.history.latestSample(for: "web")?.metric.memoryUsageBytes == Int64(value) * 1_048_576)
            #expect(strings(host).contains { $0.contains("Memory latest, \(value - 1).0 MiB") }, "Inactive Stats must not publish while collection continues")
            activation.update(isActive: true)
            try await wait(host) { strings(host).contains { $0.contains("Memory latest, \(value).0 MiB") } }
        }
    }

    @MainActor @Test
    func liveCollectionDoesNotRelayoutTheFullHourOnEverySample() async throws {
        _ = NativeTestApplication.shared
        let suite = "StatsLiveLayout.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitoring = ContainerMonitoringStore(defaults: defaults, notificationHandler: { _, _ in })
        let container = ResourceSummary(id: "web", title: "web", state: "running", details: .init(cpuCount: 2, memoryLimitBytes: 536_870_912))
        let now = Date.now
        monitoring.observe([container], at: now.addingTimeInterval(-3_600))
        for tick in 0..<3_600 {
            monitoring.append(["web": .init(cpuPercent: Double(tick % 80), memoryUsageBytes: Int64(1_024 * (tick % 50 + 1)))], containers: [container], at: now.addingTimeInterval(Double(tick - 3_600)))
        }
        // A long cadence means any change to the displayed hour can only come
        // from collection leaking into presentation, not from a refresh.
        let host = NSHostingView(rootView: ScrollView {
            ContainerMetricsHistoryView(containerID: "web", monitoring: monitoring, refreshInterval: .seconds(3_600)).padding(16)
        }.frame(width: 1_200, height: 700).environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await wait(host) { strings(host).contains { $0.contains("CPU latest") } }
        let picker = try #require(descendants(host, as: NSSegmentedControl.self).first)
        choose(1, in: picker)
        try await wait(host) {
            let labels = strings(host)
            return ["CPU", "Memory"].allSatisfy { metric in labels.contains { $0.hasPrefix("\(metric) over the last 60 minutes") } }
        }
        let published = strings(host).filter { $0.contains("over the last 60 minutes") }
        #expect(published.count == 2)
        var times: [Double] = []
        for tick in 0..<24 {
            let started = ContinuousClock.now
            monitoring.append(["web": .init(cpuPercent: Double(tick % 80), memoryUsageBytes: Int64(1_024 * (tick % 50 + 1)))], containers: [container], at: now.addingTimeInterval(Double(tick)))
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(1))
            host.layoutSubtreeIfNeeded()
            let elapsed = started.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        let median = times.sorted()[times.count / 2]
        print("Stats live publication layout median: \(median) ms (24 updates, full-hour history)")
        #expect(strings(host).filter { $0.contains("over the last 60 minutes") } == published, "Collection must not change the displayed hour between presentation refreshes")
        #expect(median < 50, "Collection must leave the main loop responsive between presentation refreshes")
    }

    @MainActor @Test(arguments: [1_200.0, 600.0])
    func historyKeepsItsRangeDataAndScrollableEventsAtBothWidths(_ width: Double) async throws {
        _ = NativeTestApplication.shared
        let suite = "StatsHistoryView.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitoring = ContainerMonitoringStore(defaults: defaults, notificationHandler: { _, _ in })
        let now = Date.now
        func resource(_ cpus: Int) -> ResourceSummary {
            .init(id: "web", title: "web", state: "running", details: .init(cpuCount: cpus, memoryLimitBytes: 536_870_912))
        }
        monitoring.observe([resource(2)], at: now.addingTimeInterval(-1_300))
        monitoring.observe([resource(3)], at: now.addingTimeInterval(-1_200))
        for index in 0..<100 {
            monitoring.observe([resource(index + 4)], at: now.addingTimeInterval(-300 + Double(index) * 0.2))
        }
        monitoring.append(["web": .init(cpuPercent: 80, memoryUsageBytes: 4_194_304)], containers: [resource(103)], at: now.addingTimeInterval(-1))
        let scroll = StatsScrollControl()
        let recentOldest = try #require(monitoring.history.events.dropFirst().first?.id)
        let overallOldest = try #require(monitoring.history.events.first?.id)
        let host = NSHostingView(rootView: StatsHistoryTestRoot(monitoring: monitoring, scroll: scroll, width: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await wait(host) { hasEventCount(100, in: host) }
        #expect(strings(host).contains { $0.contains("Memory latest, 4.0 MiB") })
        #expect(!strings(host).contains { $0.contains("CPU limit: 3 ·") })
        scroll.go(.event(recentOldest))
        try await wait(host) { strings(host).contains { $0.contains("CPU limit: 4 ·") } }
        scroll.go(.top)
        try await wait(host) { hasEventCount(100, in: host) && !descendants(host, as: NSSegmentedControl.self).isEmpty }
        let picker = try #require(descendants(host, as: NSSegmentedControl.self).first)
        choose(1, in: picker)
        try await wait(host) { hasEventCount(101, in: host) }
        scroll.go(.event(overallOldest))
        try await wait(host) { strings(host).contains { $0.contains("CPU limit: 3 ·") } }
        scroll.go(.top)
        try await wait(host) { hasEventCount(101, in: host) && !descendants(host, as: NSSegmentedControl.self).isEmpty }
        choose(0, in: try #require(descendants(host, as: NSSegmentedControl.self).first))
        try await wait(host) { hasEventCount(100, in: host) }
        monitoring.observe([resource(104)], at: now.addingTimeInterval(-0.5))
        try await wait(host) { hasEventCount(101, in: host) }
        scroll.go(.event(try #require(monitoring.history.events.last?.id)))
        try await wait(host) { strings(host).contains { $0.contains("CPU limit: 104 ·") } }
    }

    /// Gives the 10 ms presentation loop several cycles to react to an
    /// activation change, so a "must not publish" check cannot pass vacuously.
    @MainActor private func allowRefreshCycles(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor private func wait(_ host: NSView, line: UInt = #line, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        if !predicate() {
            let labels = strings(host)
            print("Stats wait line \(line); event labels: \(labels.filter { $0.contains("events") }); row labels: \(labels.filter { $0.contains("CPU limit:") }.prefix(12))")
        }
        #expect(predicate())
    }
    @MainActor private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }
    @MainActor private func choose(_ segment: Int, in picker: NSSegmentedControl) {
        picker.selectedSegment = segment
        if let action = picker.action { NSApplication.shared.sendAction(action, to: picker.target, from: picker) }
    }
    @MainActor private func hasEventCount(_ count: Int, in host: NSView) -> Bool {
        strings(host).contains { text in
            text.filter { !$0.isWhitespace && $0 != "," }.contains("\(count)events")
        }
    }
    @MainActor private func strings(_ value: Any) -> [String] {
        guard let value = value as? NSObject else { return [] }
        var result: [String] = []
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if value.responds(to: selector), let text = value.perform(selector)?.takeUnretainedValue() as? String { result.append(text) }
        }
        let selector = NSSelectorFromString("accessibilityChildren")
        if value.responds(to: selector), let children = value.perform(selector)?.takeUnretainedValue() as? [Any] { result += children.flatMap { strings($0) } }
        return result
    }
}

@MainActor @Observable private final class StatsScrollControl {
    enum Destination: Equatable { case top, event(UUID) }
    var destination = Destination.top
    var revision = 0
    func go(_ destination: Destination) { self.destination = destination; revision += 1 }
}

private struct StatsHistoryTestRoot: View {
    let monitoring: ContainerMonitoringStore
    @Bindable var scroll: StatsScrollControl
    let width: Double
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ContainerMetricsHistoryView(containerID: "web", monitoring: monitoring, refreshInterval: .milliseconds(10))
                    .padding(16).id("history-top")
            }
            .onChange(of: scroll.revision) {
                switch scroll.destination {
                case .top: proxy.scrollTo("history-top", anchor: .top)
                case .event(let id): proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }.frame(width: width, height: 800)
            .environment(\.scenePhase, .active)
    }
}

private struct StatsActivationTestRoot: View {
    let monitoring: ContainerMonitoringStore
    @ObservedObject var activation: ResourceFeatureActivation
    var phase = ScenePhase.active

    var body: some View {
        ScrollView {
            ContainerMetricsHistoryView(containerID: "web", monitoring: monitoring, isActive: activation.isActive, refreshInterval: .milliseconds(10))
                .padding(16)
        }.frame(width: 1_200, height: 700)
            .environment(\.scenePhase, phase)
    }
}

@MainActor @Observable private final class StatsResizeControl {
    var width = 1_200.0
}

private struct StatsResizeTestRoot: View {
    let monitoring: ContainerMonitoringStore
    let size: StatsResizeControl

    var body: some View {
        ScrollView {
            ContainerMetricsHistoryView(containerID: "web", monitoring: monitoring, refreshInterval: .seconds(3_600))
                .padding(16)
        }.frame(width: size.width, height: 800)
            .environment(\.scenePhase, .active)
    }
}
