import ContainerDeskCore
import Foundation
import Observation

/// The small surface the UI needs from the cleanup service. Keeping it injectable
/// lets store tests exercise the deletion queue without touching a real runtime.
@MainActor
public protocol CleanupServicing {
    func scan() async -> CleanupScan
    func revalidate(_ candidate: CleanupCandidate) async -> CleanupEligibility
    func verifyRemoval(_ candidate: CleanupCandidate) async -> CleanupRemovalVerification
    func command(for candidate: CleanupCandidate) throws -> CommandRequest
}

extension ContainerCleanupService: CleanupServicing {}

public enum CleanupItemState: Sendable, Equatable {
    case removed
    case skipped(String)
    case failed(String)
    case unverified(String)
    case notAttempted
}

public struct CleanupItemResult: Identifiable, Sendable, Equatable {
    public let candidate: CleanupCandidate
    public let state: CleanupItemState
    public var id: String { candidate.id }

    public init(candidate: CleanupCandidate, state: CleanupItemState) {
        self.candidate = candidate
        self.state = state
    }
}

public struct CleanupRemovalReport: Sendable, Equatable {
    public let items: [CleanupItemResult]
    public let stopped: Bool
    public let beforeDiskUsage: SystemDiskUsage?
    public let afterDiskUsage: SystemDiskUsage?

    public init(items: [CleanupItemResult], stopped: Bool, beforeDiskUsage: SystemDiskUsage?, afterDiskUsage: SystemDiskUsage?) {
        self.items = items
        self.stopped = stopped
        self.beforeDiskUsage = beforeDiskUsage
        self.afterDiskUsage = afterDiskUsage
    }

    /// A measured change in total runtime storage, not an estimate of shared layers.
    public var measuredDiskReductionBytes: Int64? {
        guard let before = beforeDiskUsage?.total, let after = afterDiskUsage?.total, before >= after else { return nil }
        return before - after
    }
}

@MainActor
@Observable
public final class CleanupStore {
    public private(set) var scanResult: CleanupScan?
    public private(set) var isScanning = false
    public private(set) var isRemoving = false
    public private(set) var currentItemTitle: String?
    public private(set) var completedCount = 0
    public private(set) var totalCount = 0
    public private(set) var removalReport: CleanupRemovalReport?
    public private(set) var lastError: String?
    public private(set) var generation = 0

    @ObservationIgnored private let serviceFactory: @MainActor (any ContainerClient) -> any CleanupServicing
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var clientEpoch = 0
    @ObservationIgnored private var stopRequested = false

    public init(serviceFactory: @escaping @MainActor (any ContainerClient) -> any CleanupServicing = { ContainerCleanupService(client: $0) }) {
        self.serviceFactory = serviceFactory
    }

    public var isBusy: Bool { isScanning || isRemoving }

    public func invalidate() {
        clientEpoch += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanResult = nil
        removalReport = nil
        lastError = "The container CLI changed. Scan again to review current resources."
        if isRemoving { stopRequested = true }
        generation += 1
    }

    public func scan(using appStore: AppStore) async {
        guard !isBusy else { return }
        let client = appStore.client
        let epoch = clientEpoch
        let cliPath = appStore.cliPath
        let service = serviceFactory(client)
        isScanning = true
        lastError = nil
        removalReport = nil
        scanTask = Task { [weak self] in
            let result = await service.scan()
            guard !Task.isCancelled else { return }
            guard let self, self.clientEpoch == epoch, appStore.cliPath == cliPath else { return }
            self.scanResult = result
            self.generation += 1
            self.isScanning = false
            self.scanTask = nil
        }
        await scanTask?.value
        if isScanning, clientEpoch == epoch {
            isScanning = false
            scanTask = nil
        }
    }

    /// Stops after the in-flight target completes; it never interrupts an
    /// individual resource deletion halfway through.
    public func stopAfterCurrent() {
        guard isRemoving else { return }
        stopRequested = true
    }

    public func remove(selection: [CleanupCandidate], using appStore: AppStore) async {
        guard !isBusy, let scan = scanResult else { return }
        guard !selection.isEmpty else { return }
        let byID = Dictionary(scan.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [CleanupItemResult] = []
        var seenIDs = Set<String>()
        let uniqueSelection = selection.filter { seenIDs.insert($0.id).inserted }
        let reviewed = uniqueSelection.filter { candidate in
            guard let current = byID[candidate.id], current == candidate else {
                items.append(CleanupItemResult(candidate: candidate, state: .skipped("The reviewed resource changed after this scan.")))
                return false
            }
            return true
        }
        let client = appStore.client
        let epoch = clientEpoch
        let cliPath = appStore.cliPath
        let service = serviceFactory(client)
        let beforeDiskUsage = scan.diskUsage
        stopRequested = false
        isRemoving = true
        currentItemTitle = nil
        completedCount = items.count
        totalCount = uniqueSelection.count
        lastError = nil
        removalReport = nil
        for candidate in reviewed {
            if stopRequested || clientEpoch != epoch || appStore.cliPath != cliPath { break }
            currentItemTitle = candidate.title

            let eligibility = await service.revalidate(candidate)
            guard clientEpoch == epoch, appStore.cliPath == cliPath else { break }
            if stopRequested { break }
            guard eligibility.eligible else {
                items.append(CleanupItemResult(candidate: candidate, state: .skipped(eligibility.reason)))
                completedCount += 1
                currentItemTitle = nil
                continue
            }

            do {
                let request = try service.command(for: candidate)
                try await appStore.execute(
                    request,
                    title: "Remove \(candidate.category.title): \(candidate.title)",
                    using: client,
                    allowRetry: false,
                    allowCancellation: false
                )
                switch await service.verifyRemoval(candidate) {
                case .removed:
                    items.append(CleanupItemResult(candidate: candidate, state: .removed))
                case .stillPresent(let reason):
                    items.append(CleanupItemResult(candidate: candidate, state: .failed(reason)))
                case .unverified(let reason):
                    items.append(CleanupItemResult(candidate: candidate, state: .unverified(reason)))
                }
            } catch {
                items.append(CleanupItemResult(candidate: candidate, state: .failed(error.localizedDescription)))
            }
            completedCount += 1
            currentItemTitle = nil

            // Observe a stop request after recording the current item's result.
            if stopRequested || clientEpoch != epoch || appStore.cliPath != cliPath { break }
        }

        let attemptedIDs = Set(items.map(\.id))
        for candidate in reviewed where !attemptedIDs.contains(candidate.id) {
            items.append(CleanupItemResult(candidate: candidate, state: .notAttempted))
        }
        currentItemTitle = nil

        let stopped = stopRequested || clientEpoch != epoch || appStore.cliPath != cliPath
        var afterDiskUsage: SystemDiskUsage?
        if clientEpoch == epoch, appStore.cliPath == cliPath {
            let afterScan = await service.scan()
            if clientEpoch == epoch, appStore.cliPath == cliPath {
                scanResult = afterScan
                generation += 1
                afterDiskUsage = afterScan.diskUsage
            }
        }
        let configurationChanged = clientEpoch != epoch || appStore.cliPath != cliPath
        if configurationChanged { scanResult = nil }
        removalReport = CleanupRemovalReport(items: items, stopped: stopped || configurationChanged, beforeDiskUsage: beforeDiskUsage, afterDiskUsage: afterDiskUsage)
        isRemoving = false
        stopRequested = false
    }
}
