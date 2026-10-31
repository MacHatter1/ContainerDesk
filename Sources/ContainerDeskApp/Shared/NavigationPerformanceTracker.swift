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
        case missingWindow
        case missingWindowContent
        case missingSidebar
        case sidebarFocusRejected
        case missingSidebarCoordinator
        case missingSidebarSelection
        case missingSidebarRow(ContainerSection)
        case keyboardEventUnavailable

        var errorDescription: String? {
            switch self {
            case .timedOut(let section): "Navigation to \(section.title) did not settle within 15 seconds."
            case .missingWindow: "Native benchmark: no key/main window is available, or the sidebar has detached from its window."
            case .missingWindowContent: "Native benchmark: the key/main window has no content view."
            case .missingSidebar: "Native benchmark: no outline with ContainerSidebarList.Coordinator was found in the key/main window."
            case .sidebarFocusRejected: "Native benchmark: the window rejected keyboard focus for the sidebar outline."
            case .missingSidebarCoordinator: "Native benchmark: the sidebar outline no longer has ContainerSidebarList.Coordinator as its delegate."
            case .missingSidebarSelection: "Native benchmark: the sidebar has no selected section or native row."
            case .missingSidebarRow(let section): "Native benchmark: no native sidebar row exists for \(section.title)."
            case .keyboardEventUnavailable: "A native navigation keyboard event could not be created."
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
    private var lastMeasurementFinishedAt: CFTimeInterval?
    private var benchmarkStarted = false
    private var keyboardBenchmarkInProgress = false

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
            // Run after the ordinary AppKit/Core Animation commit observers,
            // rather than ending the measurement ahead of frame preparation.
            Int.max
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
        let finishedAt = CACurrentMediaTime()
        let milliseconds = (finishedAt - pending.startedAt) * 1_000
        removeRunLoopObserver()
        scheduledGeneration = nil
        self.pending = nil
        lastMeasurement = Sample(from: pending.from.rawValue, to: pending.to.rawValue, milliseconds: milliseconds, warmup: false)
        lastMeasurementFinishedAt = finishedAt

        signposter.endInterval("Sidebar Navigation Settle", pending.interval)
        if !keyboardBenchmarkInProgress {
            logger.info(
                "navigation_settle_ms=\(milliseconds, format: .fixed(precision: 2)) from=\(pending.from.rawValue, privacy: .public) to=\(pending.to.rawValue, privacy: .public)"
            )
        }
    }

    /// Drives the same selection binding as the sidebar, without accessibility
    /// traversal or screen capture during the measured intervals.
    func runBenchmark(prepare: () async throws -> Void = {}, navigate: (ContainerSection) -> Void) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--navigation-benchmark"), !benchmarkStarted,
              let output = arguments.first(where: { $0.hasPrefix("--navigation-benchmark-output=") }) else { return }
        benchmarkStarted = true
        let path = String(output.dropFirst("--navigation-benchmark-output=".count))
        let useKeyboard = arguments.contains("--navigation-benchmark-input=keyboard")
        let route: [ContainerSection] = arguments.contains("--navigation-benchmark-route=stacks")
            ? [.stacks, .containers]
            : [.stacks, .containers, .images, .containers, .activity, .containers, .cleanup, .system, .containers]
        var samples: [Sample] = []
        do {
            try await Task.sleep(for: .seconds(2))
            NSApp.activate(ignoringOtherApps: true)
            let window = try await benchmarkWindow()
            window.makeKeyAndOrderFront(nil)
            try await prepare()
            navigate(.containers)
            try await Task.sleep(for: .seconds(1))
            let sidebar = useKeyboard ? try benchmarkSidebar(in: window) : nil
            keyboardBenchmarkInProgress = useKeyboard
            defer { keyboardBenchmarkInProgress = false }
            // The first cycle creates destinations; subsequent cycles measure
            // warm navigation through resource and ordinary feature pages.
            for cycle in 0..<4 {
                for section in route {
                    let measurement: Sample
                    if let sidebar {
                        measurement = try await navigateWithKeyboard(to: section, in: sidebar)
                    } else {
                        lastMeasurement = nil
                        navigate(section)
                        measurement = try await waitForMeasurement(to: section)
                    }
                    samples.append(Sample(from: measurement.from, to: measurement.to, milliseconds: measurement.milliseconds, warmup: cycle == 0))
                    if !useKeyboard { try await Task.sleep(for: .milliseconds(200)) }
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

    private func waitForMeasurement(to section: ContainerSection? = nil) async throws -> Sample {
        let deadline = CACurrentMediaTime() + 15
        while CACurrentMediaTime() < deadline {
            if let sample = lastMeasurement, section == nil || sample.to == section?.rawValue {
                return sample
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BenchmarkError.timedOut(section ?? .containers)
    }

    private func benchmarkWindow() async throws -> NSWindow {
        let deadline = CACurrentMediaTime() + 15
        while CACurrentMediaTime() < deadline {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
                return window
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BenchmarkError.missingWindow
    }

    private func benchmarkSidebar(in window: NSWindow) throws -> NSOutlineView {
        func find(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView,
               outline.delegate is ContainerSidebarList.Coordinator { return outline }
            for child in view.subviews {
                if let outline = find(in: child) { return outline }
            }
            return nil
        }
        // Traverse the local native hierarchy once, before timing, without AX
        // requests or screen capture. Prefer this app's existing main window.
        guard let content = window.contentView else { throw BenchmarkError.missingWindowContent }
        guard let outline = find(in: content) else { throw BenchmarkError.missingSidebar }
        guard window.makeFirstResponder(outline) else { throw BenchmarkError.sidebarFocusRejected }
        return outline
    }

    private func navigateWithKeyboard(to destination: ContainerSection, in outline: NSOutlineView) async throws -> Sample {
        guard let coordinator = outline.delegate as? ContainerSidebarList.Coordinator else {
            throw BenchmarkError.missingSidebarCoordinator
        }
        guard let window = outline.window else { throw BenchmarkError.missingWindow }
        guard let source = coordinator.selection.wrappedValue, outline.selectedRow >= 0 else {
            throw BenchmarkError.missingSidebarSelection
        }
        let targetRow = coordinator.row(for: destination, in: outline)
        guard targetRow >= 0 else { throw BenchmarkError.missingSidebarRow(destination) }
        guard window.makeFirstResponder(outline) else { throw BenchmarkError.sidebarFocusRejected }
        let routeStartedAt = CACurrentMediaTime()
        var steps = 0
        var finalStep: Sample?
        while outline.selectedRow != targetRow {
            let previousRow = outline.selectedRow
            let down = previousRow < targetRow
            guard let scalar = UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey) else {
                throw BenchmarkError.keyboardEventUnavailable
            }
            let characters = String(scalar)
            lastMeasurement = nil
            for type: NSEvent.EventType in [.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero,
                    modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: down ? 125 : 126) else {
                    throw BenchmarkError.keyboardEventUnavailable
                }
                NSApp.postEvent(event, atStart: false)
            }
            finalStep = try await waitForMeasurement()
            steps += 1
            guard outline.selectedRow != previousRow, steps <= outline.numberOfRows else {
                throw BenchmarkError.timedOut(destination)
            }
        }
        guard let finalStep, finalStep.to == destination.rawValue,
              let finishedAt = lastMeasurementFinishedAt else { throw BenchmarkError.timedOut(destination) }
        let milliseconds = (finishedAt - routeStartedAt) * 1_000
        logger.info("navigation_keyboard_route_ms=\(milliseconds, format: .fixed(precision: 2)) from=\(source.rawValue, privacy: .public) to=\(destination.rawValue, privacy: .public) steps=\(steps) final_step_settle_ms=\(finalStep.milliseconds, format: .fixed(precision: 2))")
        // Keep the existing report schema and route pairs. Non-adjacent targets
        // include the complete sequence of native arrow selections, not just its
        // final step; adjacent Stacks/Containers directly compares input modes.
        return Sample(from: source.rawValue, to: destination.rawValue, milliseconds: milliseconds, warmup: false)
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
