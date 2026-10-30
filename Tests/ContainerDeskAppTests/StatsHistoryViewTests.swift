import AppKit
import ApplicationServices
import ContainerDeskCore
import Observation
import SwiftUI
import Testing
@testable import ContainerDeskApp

@Suite(.serialized)
struct StatsHistoryViewTests {
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
                ContainerMetricsHistoryView(containerID: "web", monitoring: monitoring)
                    .padding(16).id("history-top")
            }
            .onChange(of: scroll.revision) {
                switch scroll.destination {
                case .top: proxy.scrollTo("history-top", anchor: .top)
                case .event(let id): proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }.frame(width: width, height: 800)
    }
}
