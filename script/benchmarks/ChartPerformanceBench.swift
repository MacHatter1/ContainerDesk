import AppKit
import Observation
import QuartzCore
import SwiftUI

// The runner inserts these counters into disposable copies of the real chart
// source. No instrumentation is added to the shipping app.
@MainActor enum ChartBenchmarkRecorder {
    static var plotBodies = 0
    static var selectionChanges = 0
    static var projectionBuilds: [Int] = []
    static func plot() { plotBodies += 1 }
    static func projection(_ count: Int) { projectionBuilds.append(count) }
}

@MainActor @Observable final class ChartBenchmarkState { var selectedDate: Date? }

struct ChartBenchmarkView: View {
    @Bindable var state: ChartBenchmarkState
    let samples: [ContainerHistorySample]
    let events: [ContainerHistoryEvent]
    let start: Date
    var body: some View {
        HStack {
            ContainerMetricChart(metric: .cpu(normalized: false), samples: samples, events: events, start: start, end: start.addingTimeInterval(Double(samples.count)), selectedDate: $state.selectedDate)
            ContainerMetricChart(metric: .memory, samples: samples, events: events, start: start, end: start.addingTimeInterval(Double(samples.count)), selectedDate: $state.selectedDate)
        }
        .padding(16).frame(width: 1_200, height: 360)
        .onChange(of: state.selectedDate) { ChartBenchmarkRecorder.selectionChanges += 1 }
    }
}

@main @MainActor enum ChartPerformanceBench {
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }

    static func pump(_ host: NSView, until complete: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        } while !complete() && ContinuousClock.now < deadline
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        return complete()
    }

    static func main() throws {
        let count = Int(CommandLine.arguments[1])!
        let eventCount = Int(CommandLine.arguments[2])!
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let samples = (0..<count).map { tick in
            ContainerHistorySample(date: start.addingTimeInterval(Double(tick)), metric: .init(cpuPercent: Double(tick % 80), memoryUsageBytes: Int64(1_024 * (tick % 50 + 1))), cpuLimit: 2, memoryLimit: 1_048_576)
        }
        let events = (0..<eventCount).map { index in
            ContainerHistoryEvent(date: start.addingTimeInterval(Double(index) * Double(count) / Double(max(1, eventCount))), containerID: "web", kind: .limits, detail: "Limit changed", unexpected: false)
        }
        let state = ChartBenchmarkState()
        let host = NSHostingView(rootView: ChartBenchmarkView(state: state, samples: samples, events: events, start: start))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 360)
        defer { window.contentView = nil; window.close() }
        var success = pump(host) { ChartBenchmarkRecorder.plotBodies >= 2 }
        // Settle width-driven downsampling and initial native chart layout.
        for _ in 0..<5 { _ = pump(host) { true } }
        let initialProjectionBuilds = ChartBenchmarkRecorder.projectionBuilds
        var idle: [Double] = []
        for _ in 0..<5 {
            let begin = ContinuousClock.now
            _ = pump(host) { true }
            idle.append(milliseconds(since: begin))
        }
        var timings: [Double] = []
        var plotBodies: [Int] = []
        var projectionBuilds: [[Int]] = []
        for tick in 0..<7 {
            let previous = ChartBenchmarkRecorder.plotBodies
            let buildIndex = ChartBenchmarkRecorder.projectionBuilds.count
            let revision = ChartBenchmarkRecorder.selectionChanges
            let begin = ContinuousClock.now
            state.selectedDate = start.addingTimeInterval(Double(100 + tick))
            success = pump(host) { ChartBenchmarkRecorder.selectionChanges > revision } && success
            let elapsed = milliseconds(since: begin)
            if tick >= 2 {
                timings.append(elapsed)
                plotBodies.append(ChartBenchmarkRecorder.plotBodies - previous)
                projectionBuilds.append(Array(ChartBenchmarkRecorder.projectionBuilds[buildIndex...]))
            }
        }
        let result: [String: Any] = ["samples_each": count, "events": eventCount, "charts": 2,
            "hover_update_ms": timings, "idle_layout_ms": idle, "static_plot_body_calls": plotBodies,
            "initial_projection_builds": initialProjectionBuilds, "hover_projection_builds": projectionBuilds, "processed_updates": success]
        if CommandLine.arguments.count > 3,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
