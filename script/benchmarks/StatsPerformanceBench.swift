// Native full Stats history fixture: injected clock/selection, no runtime client.
import AppKit
import Observation
import QuartzCore
import SwiftUI

@MainActor enum StatsBenchmarkClock {
    static let end = Date(timeIntervalSince1970: 1_000_000)
    static var revisions = 0
    static var eventRows = 0
    static func eventRow() { eventRows += 1 }
    static var minutes: Int { Int(CommandLine.arguments[1])! > 900 ? 60 : 15 }
}
@MainActor @Observable final class ContainerMonitoringStore {
    var history: ContainerMetricsHistory
    init(_ history: ContainerMetricsHistory) { self.history = history }
}
@MainActor @Observable final class StatsBenchmarkSelection { var date: Date? }
struct StatsBenchmarkRoot: View {
    @Bindable var selection: StatsBenchmarkSelection
    let monitoring: ContainerMonitoringStore
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                ContainerMetricsHistoryView(containerID: "web", monitoring: monitoring, hoveredDate: $selection.date)
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
        }
        .onChange(of: selection.date) { StatsBenchmarkClock.revisions += 1 }
        .frame(width: 1_200, height: 700)
    }
}
@main @MainActor enum StatsPerformanceBench {
    static func ms(_ since: ContinuousClock.Instant) -> Double {
        let d = since.duration(to: .now).components
        return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
    }
    static func pump(_ host: NSView, _ complete: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
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
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let count = Int(CommandLine.arguments[1])!
        let eventCount = Int(CommandLine.arguments[2])!
        let end = StatsBenchmarkClock.end
        let start = end.addingTimeInterval(-Double(count - 1))
        var history = ContainerMetricsHistory()
        func resource(_ cpus: Int) -> ResourceSummary { .init(id: "web", title: "web", state: "running", details: .init(cpuCount: cpus, memoryLimitBytes: 1_073_741_824)) }
        history.observe([resource(2)], at: start.addingTimeInterval(-0.01))
        for index in 0..<eventCount {
            history.observe([resource(index % 2 + 1)], at: start.addingTimeInterval(Double(index) * Double(count - 1) / Double(max(1,eventCount))))
        }
        let containers = [resource(2)]
        for tick in 0..<count {
            history.append(["web": .init(cpuPercent: Double(tick % 80), memoryUsageBytes: Int64(1_024 * (tick % 50 + 1)))], containers: containers, at: start.addingTimeInterval(Double(tick)))
        }
        let selection = StatsBenchmarkSelection()
        let monitoring = ContainerMonitoringStore(history)
        let begin = ContinuousClock.now
        let host = NSHostingView(rootView: StatsBenchmarkRoot(selection: selection, monitoring: monitoring))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 700)
        _ = pump(host) { true }
        let initial = ms(begin)
        let initialRows = StatsBenchmarkClock.eventRows
        defer { window.contentView = nil; window.close() }
        for _ in 0..<5 { _ = pump(host) { true } }
        var idle: [Double] = []
        for _ in 0..<5 { let t = ContinuousClock.now; _ = pump(host) { true }; idle.append(ms(t)) }
        var times: [Double] = []
        var hoverRows: [Int] = []
        var success = true
        for tick in 0..<7 {
            let revision = StatsBenchmarkClock.revisions
            let rows = StatsBenchmarkClock.eventRows
            let begin = ContinuousClock.now
            selection.date = start.addingTimeInterval(Double(100 + tick))
            success = pump(host) { StatsBenchmarkClock.revisions > revision } && success
            if tick >= 2 { times.append(ms(begin)); hoverRows.append(StatsBenchmarkClock.eventRows - rows) }
        }
        let row: [String: Any] = ["samples":count,"events":history.events.count,"initial_ms":initial,"initial_event_row_evaluations":initialRows,"hover_event_row_evaluations":hoverRows,"idle_ms":idle,"hover_ms":times,"processed":success]
        if CommandLine.arguments.count > 3, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            }
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:row, options:[.sortedKeys]),as:UTF8.self))
    }
}
