// Pair baseline/current updates within one process so each pair shares the
// same scheduler, run-loop timers, font caches and power-management state.
import AppKit
import Darwin
import Observation
import QuartzCore
import SwiftUI
import Synchronization

@MainActor enum ChartBenchmarkRecorder {
    static var plotBodies = 0
    static var readoutBodies = 0
    static var selectionChanges = 0
    static var projectionBuilds: [Int] = []
    nonisolated private static let draws = Mutex<Int>(0)
    static var plotDrawCount: Int { draws.withLock { $0 } }
    static func plot() { plotBodies += 1 }
    static func readout() { readoutBodies += 1 }
    static func projection(_ count: Int) { projectionBuilds.append(count) }
    nonisolated static func plotDraw() { draws.withLock { $0 += 1 } }
}

@MainActor enum BeforeChartBenchmarkRecorder {
    static var plotBodies = 0
    static var readoutBodies = 0
    static var selectionChanges = 0
    static var projectionBuilds: [Int] = []
    nonisolated private static let draws = Mutex<Int>(0)
    static var plotDrawCount: Int { draws.withLock { $0 } }
    static func plot() { plotBodies += 1 }
    static func readout() { readoutBodies += 1 }
    static func projection(_ count: Int) { projectionBuilds.append(count) }
    nonisolated static func plotDraw() { draws.withLock { $0 += 1 } }
}

@MainActor @Observable final class PairedChartSelection { var date: Date? }

private struct PairedChartRoot: View {
    let before: Bool
    @Bindable var selection: PairedChartSelection
    let samples: [ContainerHistorySample]
    let events: [ContainerHistoryEvent]
    let start: Date
    var body: some View {
        Group {
            if before {
                HStack {
                    BeforeContainerMetricChart(metric: .cpu(normalized: false), samples: samples, events: events, start: start, end: start.addingTimeInterval(Double(samples.count)), selectedDate: $selection.date)
                    BeforeContainerMetricChart(metric: .memory, samples: samples, events: events, start: start, end: start.addingTimeInterval(Double(samples.count)), selectedDate: $selection.date)
                }
            } else {
                HStack {
                    ContainerMetricChart(metric: .cpu(normalized: false), samples: samples, events: events, start: start, end: start.addingTimeInterval(Double(samples.count)), selectedDate: $selection.date)
                    ContainerMetricChart(metric: .memory, samples: samples, events: events, start: start, end: start.addingTimeInterval(Double(samples.count)), selectedDate: $selection.date)
                }
            }
        }
        .padding(16).frame(width: 1_200, height: 360)
        .onChange(of: selection.date) {
            if before { BeforeChartBenchmarkRecorder.selectionChanges += 1 }
            else { ChartBenchmarkRecorder.selectionChanges += 1 }
        }
    }
}

@main @MainActor enum PairedChartPerformanceBench {
    private struct Counters {
        let plots: Int
        let readouts: Int
        let draws: Int
        let changes: Int
    }
    private static func counters(_ before: Bool) -> Counters {
        before ? .init(plots: BeforeChartBenchmarkRecorder.plotBodies, readouts: BeforeChartBenchmarkRecorder.readoutBodies, draws: BeforeChartBenchmarkRecorder.plotDrawCount, changes: BeforeChartBenchmarkRecorder.selectionChanges) :
            .init(plots: ChartBenchmarkRecorder.plotBodies, readouts: ChartBenchmarkRecorder.readoutBodies, draws: ChartBenchmarkRecorder.plotDrawCount, changes: ChartBenchmarkRecorder.selectionChanges)
    }
    private static func cpu() -> Double {
        var value = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value)
        return Double(value.tv_sec) * 1_000 + Double(value.tv_nsec) / 1e6
    }
    private static func ms(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
    private static func pump(_ host: NSView, until complete: () -> Bool) -> Bool {
        autoreleasepool {
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
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Pair native chart hover measurements without App Nap")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let count = Int(CommandLine.arguments[1])!
        let eventCount = Int(CommandLine.arguments[2])!
        let updates = Int(CommandLine.arguments[3])!
        let round = Int(CommandLine.arguments[4])!
        let start = Date(timeIntervalSince1970: 1_000_000)
        let samples = (0..<count).map { tick in
            ContainerHistorySample(date: start.addingTimeInterval(Double(tick)), metric: .init(cpuPercent: Double(tick % 80), memoryUsageBytes: Int64(1_024 * (tick % 50 + 1))), cpuLimit: 2, memoryLimit: 1_048_576)
        }
        let events = (0..<eventCount).map { index in
            ContainerHistoryEvent(date: start.addingTimeInterval(Double(index) * Double(count) / Double(max(1, eventCount))), containerID: "web", kind: .limits, detail: "Limit changed", unexpected: false)
        }
        let states = [PairedChartSelection(), PairedChartSelection()]
        let hosts = states.enumerated().map { index, state in
            NSHostingView(rootView: PairedChartRoot(before: index == 0, selection: state, samples: samples, events: events, start: start))
        }
        let windows = hosts.map { host in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 360)
            return window
        }
        defer { for window in windows { window.contentView = nil; window.close() } }
        var success = true
        for index in [round % 2, 1 - round % 2] {
            success = pump(hosts[index]) { counters(index == 0).plots >= 2 } && success
        }
        for _ in 0..<5 { for host in hosts { _ = pump(host) { true } } }
        let initialDraws = [counters(true).draws, counters(false).draws]
        let initialBuilds = [BeforeChartBenchmarkRecorder.projectionBuilds, ChartBenchmarkRecorder.projectionBuilds]
        var idle = [[Double]](repeating: [], count: 2)
        for _ in 0..<5 {
            for index in 0..<2 {
                let began = ContinuousClock.now
                _ = pump(hosts[index]) { true }
                idle[index].append(ms(began))
            }
        }
        var wall = [[Double]](repeating: [], count: 2)
        var threadCPU = wall
        var plots = [[Int]](repeating: [], count: 2)
        var readouts = plots
        var draws = plots
        var projections = [[[Int]]](repeating: [], count: 2)
        for tick in 0..<(updates + 2) {
            let first = (tick + round) % 2
            for index in [first, 1 - first] {
                let previous = counters(index == 0)
                let buildIndex = index == 0 ? BeforeChartBenchmarkRecorder.projectionBuilds.count : ChartBenchmarkRecorder.projectionBuilds.count
                let cpuStart = cpu()
                let began = ContinuousClock.now
                states[index].date = start.addingTimeInterval(Double(100 + tick % max(1, count - 200)))
                success = pump(hosts[index]) { counters(index == 0).changes > previous.changes } && success
                let elapsed = ms(began), cpuElapsed = cpu() - cpuStart
                if tick >= 2 {
                    let current = counters(index == 0)
                    wall[index].append(elapsed); threadCPU[index].append(cpuElapsed)
                    plots[index].append(current.plots - previous.plots)
                    readouts[index].append(current.readouts - previous.readouts)
                    draws[index].append(current.draws - previous.draws)
                    let builds = index == 0 ? BeforeChartBenchmarkRecorder.projectionBuilds : ChartBenchmarkRecorder.projectionBuilds
                    projections[index].append(Array(builds[buildIndex...]))
                }
            }
        }
        var rows: [[String: Any]] = []
        for index in 0..<2 {
            rows.append(["version": index == 0 ? "before" : "after", "samples_each": count, "events": eventCount, "charts": 2,
                         "hover_update_ms": wall[index], "hover_thread_cpu_ms": threadCPU[index], "idle_layout_ms": idle[index],
                         "static_plot_body_calls": plots[index], "readout_body_calls": readouts[index], "static_plot_draw_calls": draws[index],
                         "plot_draw_instrumented": initialDraws[index] >= 2, "initial_projection_builds": initialBuilds[index],
                         "hover_projection_builds": projections[index], "processed_updates": success])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
    }
}
