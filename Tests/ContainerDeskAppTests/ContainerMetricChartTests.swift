import AppKit
import ApplicationServices
import Observation
import SwiftUI
import Testing
@testable import ContainerDeskCore
@testable import ContainerDeskApp

@Suite(.serialized)
struct ContainerMetricChartTests {
    @MainActor @Test func bothNativeChartReadoutsFollowSelectionGapsClearingAndNewSamples() async throws {
        _ = NativeTestApplication.shared
        let state = ChartSelectionFixture()
        let host = NSHostingView(rootView: ChartSelectionFixtureView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        try await wait(host) { readout("CPU latest", in: host).contains("80.0 %") && readout("Memory latest", in: host).contains("8.0 MiB") }
        state.selectedDate = state.start.addingTimeInterval(1.1)
        try await wait(host) { readout("CPU selected", in: host).contains("20.0 %") && readout("Memory selected", in: host).contains("6.0 MiB") }
        state.normalized = true
        try await wait(host) { readout("CPU selected", in: host).contains("10.0 %") }
        state.selectedDate = state.start.addingTimeInterval(30)
        try await wait(host) { readout("CPU selected", in: host).contains("—") && readout("Memory selected", in: host).contains("—") }
        state.selectedDate = nil
        try await wait(host) { readout("CPU latest", in: host).contains("40.0 %") && readout("Memory latest", in: host).contains("8.0 MiB") }
        state.samples.append(.init(date: state.start.addingTimeInterval(61), metric: .init(cpuPercent: 60, memoryUsageBytes: 10_485_760), cpuLimit: 2, memoryLimit: 16_777_216))
        state.events.append(.init(date: state.start.addingTimeInterval(45), containerID: "fixture", kind: .restart, detail: "Restart", unexpected: false))
        try await wait(host) {
            readout("CPU latest", in: host).contains("30.0 %") && readout("Memory latest", in: host).contains("10.0 MiB") &&
            nodes(host).contains { string("accessibilityLabel", of: $0).contains("4 samples, 1 events") }
        }
    }

    @MainActor private func wait(_ host: NSView, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }

    @MainActor private func string(_ selector: String, of object: NSObject) -> String {
        let selector = NSSelectorFromString(selector)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }

    @MainActor private func nodes(_ value: Any) -> [NSObject] {
        guard let value = value as? NSObject else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        guard value.responds(to: selector), let children = value.perform(selector)?.takeUnretainedValue() as? [Any] else { return [value] }
        return [value] + children.flatMap { nodes($0) }
    }

    @MainActor private func readout(_ label: String, in host: NSView) -> String {
        nodes(host).map { string("accessibilityLabel", of: $0) }.first { $0.hasPrefix(label + ",") } ?? ""
    }
}

@MainActor @Observable private final class ChartSelectionFixture {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var selectedDate: Date?
    var normalized = false
    var samples: [ContainerHistorySample]
    var events: [ContainerHistoryEvent] = []
    init() {
        let origin = start
        samples = [(0.0, 40.0, 4), (1.0, 20.0, 6), (60.0, 80.0, 8)].map { seconds, cpu, memory in
            .init(date: origin.addingTimeInterval(seconds), metric: .init(cpuPercent: cpu, memoryUsageBytes: Int64(memory) * 1_048_576), cpuLimit: 2, memoryLimit: 16_777_216)
        }
    }
}

private struct ChartSelectionFixtureView: View {
    @Bindable var state: ChartSelectionFixture
    var body: some View {
        HStack {
            ContainerMetricChart(metric: .cpu(normalized: state.normalized), samples: state.samples, events: state.events, start: state.start, end: state.start.addingTimeInterval(90), selectedDate: $state.selectedDate)
            ContainerMetricChart(metric: .memory, samples: state.samples, events: state.events, start: state.start, end: state.start.addingTimeInterval(90), selectedDate: $state.selectedDate)
        }.padding(16).frame(width: 1_200, height: 360)
    }
}
