import AppKit
import ContainerDeskCore
import OSLog
import QuartzCore
import SwiftUI

/// Measures sidebar selection until the main run loop settles after the selected
/// destination has updated. This includes synchronous SwiftUI/AppKit work without
/// forcing layout, and remains stable when the window is occluded. Enable with
/// `--navigation-metrics`; normal launches do not create observers or log events.
@MainActor
final class NavigationPerformanceTracker {
    private enum BenchmarkError: LocalizedError {
        case timedOut(ContainerSection)

        var errorDescription: String? {
            switch self {
            case .timedOut(let section): "Navigation to \(section.title) did not settle within 15 seconds."
            }
        }
    }

    private struct Sample: Codable {
        let from: String
        let to: String
        let milliseconds: Double
        let warmup: Bool
    }

    private struct PendingMeasurement {
        let generation: UInt64
        let from: ContainerSection
        let to: ContainerSection
        let startedAt: CFTimeInterval
        let interval: OSSignpostIntervalState
    }

    private let enabled: Bool
    private let logger: Logger
    private let signposter: OSSignposter
    private var generation: UInt64 = 0
    private var pending: PendingMeasurement?
    private var scheduledGeneration: UInt64?
    private var runLoopObserver: CFRunLoopObserver?
    private var lastMeasurement: Sample?
    private var benchmarkStarted = false

    init(
        enabled: Bool = ProcessInfo.processInfo.arguments.contains("--navigation-metrics")
            || ProcessInfo.processInfo.arguments.contains("--navigation-benchmark"),
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.thomasswift.ContainerDesk"
    ) {
        self.enabled = enabled
        logger = Logger(subsystem: subsystem, category: "NavigationPerformance")
        signposter = OSSignposter(subsystem: subsystem, category: "NavigationPerformance")
    }

    func begin(from: ContainerSection, to: ContainerSection) {
        guard enabled, from != to else { return }
        cancelPending()
        generation &+= 1
        pending = PendingMeasurement(
            generation: generation,
            from: from,
            to: to,
            startedAt: CACurrentMediaTime(),
            interval: signposter.beginInterval("Sidebar Navigation Settle")
        )
    }

    func destinationDidUpdate(_ section: ContainerSection) {
        guard enabled,
              let pending,
              pending.to == section,
              scheduledGeneration != pending.generation else { return }
        scheduledGeneration = pending.generation

        // Install the observer on the next turn so it cannot fire for the run
        // loop cycle that is still applying this representable update.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRunLoopSettle(generation: pending.generation)
        }
    }

    private func scheduleRunLoopSettle(generation: UInt64) {
        guard pending?.generation == generation else { return }
        removeRunLoopObserver()
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.finish(generation: generation)
            }
        }
        runLoopObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func finish(generation: UInt64) {
        guard let pending, pending.generation == generation else { return }
        let milliseconds = (CACurrentMediaTime() - pending.startedAt) * 1_000
        removeRunLoopObserver()
        scheduledGeneration = nil
        self.pending = nil
        lastMeasurement = Sample(from: pending.from.rawValue, to: pending.to.rawValue, milliseconds: milliseconds, warmup: false)

        signposter.endInterval("Sidebar Navigation Settle", pending.interval)
        logger.info(
            "navigation_settle_ms=\(milliseconds, format: .fixed(precision: 2)) from=\(pending.from.rawValue, privacy: .public) to=\(pending.to.rawValue, privacy: .public)"
        )
    }

    /// Drives the same selection binding as the sidebar, without accessibility
    /// traversal or screen capture during the measured intervals.
    func runBenchmark(navigate: (ContainerSection) -> Void) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--navigation-benchmark"), !benchmarkStarted,
              let output = arguments.first(where: { $0.hasPrefix("--navigation-benchmark-output=") }) else { return }
        benchmarkStarted = true
        let path = String(output.dropFirst("--navigation-benchmark-output=".count))
        var samples: [Sample] = []
        do {
            try await Task.sleep(for: .seconds(2))
            navigate(.containers)
            try await Task.sleep(for: .seconds(1))
            // The first cycle creates destinations; subsequent cycles measure
            // warm navigation through resource and ordinary feature pages.
            for cycle in 0..<4 {
                for section: ContainerSection in [.images, .containers, .activity, .containers, .cleanup, .system, .containers] {
                    lastMeasurement = nil
                    navigate(section)
                    let deadline = CACurrentMediaTime() + 15
                    while lastMeasurement == nil, CACurrentMediaTime() < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard let measurement = lastMeasurement else {
                        throw BenchmarkError.timedOut(section)
                    }
                    samples.append(Sample(from: measurement.from, to: measurement.to, milliseconds: measurement.milliseconds, warmup: cycle == 0))
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            let data = try JSONEncoder().encode(samples)
            try data.write(to: URL(filePath: path), options: .atomic)
            logger.info("navigation_benchmark_complete samples=\(samples.count) output=\(path, privacy: .public)")
        } catch {
            if let data = try? JSONEncoder().encode(["error": error.localizedDescription]) {
                try? data.write(to: URL(filePath: path), options: .atomic)
            }
            logger.error("navigation_benchmark_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelPending() {
        removeRunLoopObserver()
        scheduledGeneration = nil
        if let pending {
            signposter.endInterval("Sidebar Navigation Settle", pending.interval)
            self.pending = nil
        }
    }

    private func removeRunLoopObserver() {
        guard let runLoopObserver else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
        self.runLoopObserver = nil
    }
}

/// A one-point native view marks when the selected destination hierarchy has
/// been updated without forcing it to lay out or draw synchronously.
struct NavigationSettleProbe: NSViewRepresentable {
    let section: ContainerSection
    let tracker: NavigationPerformanceTracker

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        tracker.destinationDidUpdate(section)
    }
}
