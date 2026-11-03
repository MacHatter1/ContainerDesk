// Accelerated native Stats session. Only the clock, selection, and monitoring
// source are adapted; the production view, charts, and Core history are compiled.
import AppKit
import Darwin
import Observation
import QuartzCore
import SwiftUI
import Synchronization

@MainActor enum StatsBenchmarkClock {
    static var end = Date(timeIntervalSince1970: 1_000_000)
    static var minutes: Int { 60 }
    static var publications = 0
    static var eventRows = 0
    static var pickerEvaluations = 0
    nonisolated private static let drawing = Mutex<[String: (date: Date?, count: Int, window: Int)]>([:])
    static var renderedDate: Date? { drawing.withLock { $0["CPU"]?.date == $0["Memory"]?.date ? $0["CPU"]?.date : nil } }
    static var renderedCount: Int { drawing.withLock { min($0["CPU"]?.count ?? 0, $0["Memory"]?.count ?? 0) } }
    static var renderedWindow: Int? { drawing.withLock { $0["CPU"]?.window == $0["Memory"]?.window ? $0["CPU"]?.window : nil } }
    private static var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]

    static func publication() { publications += 1 }
    static func eventRow() { eventRows += 1 }
    static func pickerBody() { pickerEvaluations += 1 }
    nonisolated static func rendered(_ date: Date?, count: Int, window: Int, metric: String) { drawing.withLock { $0[metric] = (date, count, window) } }
    static func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { sleepers[id] = $0 }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }
    static func refresh() {
        let current = sleepers
        sleepers.removeAll()
        for sleeper in current.values { sleeper.resume() }
    }
}

@MainActor @Observable final class ContainerMonitoringStore {
    var history: ContainerMetricsHistory
    init(_ history: ContainerMetricsHistory) { self.history = history }
}

@MainActor @Observable private final class SoakSelection {
    var date: Date?
    var active = true
    var phase = ScenePhase.active
    var bottom = false
}

private struct SoakRoot: View {
    let monitoring: ContainerMonitoringStore
    @Bindable var selection: SoakSelection

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ContainerMetricsHistoryView(containerID: "web", monitoring: monitoring, isActive: selection.active, hoveredDate: $selection.date)
                    .padding(16).id("top")
                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: selection.bottom) { _, bottom in
                proxy.scrollTo(bottom ? "bottom" : "top", anchor: bottom ? .bottom : .top)
            }
        }
        .opacity(selection.active && selection.phase != .background ? 1 : 0)
        .frame(width: 1_200, height: 700)
        .environment(\.scenePhase, selection.phase)
    }
}

@main @MainActor enum StatsSoakBench {
    static func milliseconds(_ since: ContinuousClock.Instant) -> Double {
        let elapsed = since.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    static func threadCPU() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1e6
    }

    static func pump(_ host: NSView, displaying date: Date? = nil, window: Int? = nil) {
        // This custom loop does not enter NSApplication.run(). Drain temporary
        // AppKit/Charts objects per turn, like the real app's event loop.
        autoreleasepool {
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                CATransaction.flush()
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                host.layoutSubtreeIfNeeded()
                CATransaction.flush()
            } while ((date != nil && StatsBenchmarkClock.renderedDate != date) ||
                     (window != nil && StatsBenchmarkClock.renderedWindow != window)) && ContinuousClock.now < deadline
            precondition(date == nil || StatsBenchmarkClock.renderedDate == date, "Both charts must finish drawing the latest samples")
            precondition(window == nil || StatsBenchmarkClock.renderedWindow == window, "Both charts must finish drawing the selected range")
        }
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * percentile))]
    }

    static func emit(_ row: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    static func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Measure sustained interactive Stats work without App Nap")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let updates = Int(CommandLine.arguments[1])!
        let rangeEvery = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1_024
        let count = 20
        var containers = (0..<count).map { index in
            ResourceSummary(id: index == 0 ? "web" : "worker-\(index)", title: "Container \(index)", state: "running", details: .init(cpuCount: 2, memoryLimitBytes: 536_870_912))
        }
        var history = ContainerMetricsHistory()
        let initial = StatsBenchmarkClock.end
        history.observe(containers, at: initial.addingTimeInterval(-3_600))
        for tick in 0..<3_600 {
            let metrics = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, ContainerMetric(cpuPercent: Double(tick % 80), memoryUsageBytes: Int64(1_024 * (tick % 50 + 1)))) })
            history.append(metrics, containers: containers, at: initial.addingTimeInterval(Double(tick - 3_600)))
        }
        let monitoring = ContainerMonitoringStore(history)
        let selection = SoakSelection()
        let host = NSHostingView(rootView: SoakRoot(monitoring: monitoring, selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 700)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 { pump(host) }
        var collection: [Double] = []
        var refresh: [Double] = []
        var interaction: [Double] = []
        var hoverAndScroll: [Double] = []
        var rangeChanges: [Double] = []
        var refreshCPU: [Double] = []
        var rangeCPU: [Double] = []
        var slowestRangeCPU = 0.0
        var slowestRangeTick = 0
        var rangeRequests = 0
        var selectedMinutes = 60
        var inactiveViolations = 0
        var publicationBeforeInactive = 0
        let began = ContinuousClock.now
        var batches: [[String: Any]] = []

        for tick in 1...updates {
            StatsBenchmarkClock.end = initial.addingTimeInterval(Double(tick))
            // Repeatedly leave Stats and return while the history source remains live.
            if tick % 1_000 == 900 {
                if (tick / 1_000).isMultiple(of: 2) { selection.active = false }
                else { selection.phase = .background }
                pump(host)
                pump(host)
                publicationBeforeInactive = StatsBenchmarkClock.publications
            } else if tick % 1_000 == 950 {
                if StatsBenchmarkClock.publications != publicationBeforeInactive { inactiveViolations += 1 }
                selection.active = true
                selection.phase = .inactive
                pump(host)
            }
            if tick % 300 == 0 {
                containers[0] = .init(id: "web", title: "Container 0", state: "running", details: .init(cpuCount: tick % 600 == 0 ? 2 : 3, memoryLimitBytes: 536_870_912))
                monitoring.history.observe(containers, at: StatsBenchmarkClock.end)
            }
            let metrics = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, ContainerMetric(cpuPercent: Double(tick % 80), memoryUsageBytes: Int64(1_024 * (tick % 50 + 1)))) })
            let started = ContinuousClock.now
            let cpuStarted = threadCPU()
            monitoring.history.append(metrics, containers: containers, at: StatsBenchmarkClock.end)
            if tick % 5 == 0 { StatsBenchmarkClock.refresh() }
            pump(host, displaying: tick % 5 == 0 && selection.active && selection.phase != .background ? StatsBenchmarkClock.end : nil)
            let elapsed = milliseconds(started)
            if tick % 5 == 0 {
                refresh.append(elapsed)
                refreshCPU.append(threadCPU() - cpuStarted)
            } else { collection.append(elapsed) }
            if tick % 128 == 0 {
                let interactionStart = ContinuousClock.now
                selection.date = StatsBenchmarkClock.end.addingTimeInterval(-30)
                selection.bottom.toggle()
                pump(host)
                let cost = milliseconds(interactionStart)
                interaction.append(cost)
                hoverAndScroll.append(cost)
            }
            if tick % rangeEvery == 0, let picker = descendants(host, NSSegmentedControl.self).first {
                let interactionStart = ContinuousClock.now
                let cpuStarted = threadCPU()
                rangeRequests += 1
                picker.selectedSegment = (tick / rangeEvery) % 2
                selectedMinutes = picker.selectedSegment == 0 ? 15 : 60
                if let action = picker.action { NSApplication.shared.sendAction(action, to: picker.target, from: picker) }
                pump(host, window: selection.active && selection.phase != .background ? selectedMinutes : nil)
                let cost = milliseconds(interactionStart)
                interaction.append(cost)
                if cost > (rangeChanges.max() ?? 0) {
                    slowestRangeCPU = threadCPU() - cpuStarted
                    slowestRangeTick = tick
                }
                rangeChanges.append(cost)
                rangeCPU.append(threadCPU() - cpuStarted)
            }
            if tick % 1_000 == 0 || tick == updates {
                let samples = monitoring.history.samples(for: "web")
                let row: [String: Any] = [
                    "tick": tick, "elapsed_seconds": milliseconds(began) / 1_000,
                    "collection_median_ms": percentile(collection, 0.5),
                    "refresh_median_ms": percentile(refresh, 0.5),
                    "interaction_p95_ms": percentile(interaction, 0.95),
                    "hover_scroll_p95_ms": percentile(hoverAndScroll, 0.95),
                    "range_p95_ms": percentile(rangeChanges, 0.95),
                    "range_max_ms": percentile(rangeChanges, 1),
                    "refresh_cpu_median_ms": percentile(refreshCPU, 0.5),
                    "range_cpu_p95_ms": percentile(rangeCPU, 0.95),
                    "range_max_thread_cpu_ms": slowestRangeCPU,
                    "range_max_tick": slowestRangeTick,
                    "range_requests": rangeRequests,
                    "footprint_bytes": footprint(), "retained_samples": samples.count,
                    "retained_containers": monitoring.history.containerCount,
                    "events": monitoring.history.events.count, "publications": StatsBenchmarkClock.publications,
                    "picker_evaluations": StatsBenchmarkClock.pickerEvaluations,
                    "inactive_violations": inactiveViolations,
                    "latest_sample_correct": samples.last?.date == StatsBenchmarkClock.end,
                    "displayed_latest_correct": StatsBenchmarkClock.renderedDate == StatsBenchmarkClock.end,
                    "displayed_range_correct": StatsBenchmarkClock.renderedWindow == selectedMinutes,
                    "displayed_samples": StatsBenchmarkClock.renderedCount,
                ]
                try emit(row)
                batches.append(row)
                collection.removeAll(keepingCapacity: true)
                refresh.removeAll(keepingCapacity: true)
                interaction.removeAll(keepingCapacity: true)
                hoverAndScroll.removeAll(keepingCapacity: true)
                rangeChanges.removeAll(keepingCapacity: true)
                refreshCPU.removeAll(keepingCapacity: true)
                rangeCPU.removeAll(keepingCapacity: true)
                slowestRangeCPU = 0
                slowestRangeTick = 0
            }
        }
        StatsBenchmarkClock.refresh()
        try emit(["complete": true, "updates": updates, "elapsed_seconds": milliseconds(began) / 1_000, "batches": batches.count, "inactive_violations": inactiveViolations])
    }
}
