import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct CleanupStoreTests {
    @MainActor
    @Test func removesOnlyTheReviewedExactCandidateAndRequiresPostCheck() async throws {
        let first = candidate("sha256:exact-one")
        let second = candidate("sha256:exact-two")
        let service = StubCleanupService(candidates: [first, second], validation: [first.id: [true, false]])
        let client = RecordingCleanupClient()
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)

        await store.remove(selection: [first], using: appStore)

        #expect(await client.recordedArguments() == [["remove", "image", "sha256:exact-one"]])
        #expect(store.removalReport?.items == [CleanupItemResult(candidate: first, state: .removed)])
        #expect(store.scanResult?.candidates.map(\.id) == [first.id, second.id])
        #expect(appStore.operations.first?.canRetry == false)
        #expect(appStore.operations.first?.canCancel == false)
    }

    @MainActor
    @Test func recordsFailureAndContinuesWithRemainingReviewedTargets() async throws {
        let first = candidate("sha256:bad")
        let second = candidate("sha256:good")
        let service = StubCleanupService(candidates: [first, second], validation: [first.id: [true, false], second.id: [true, false]])
        let client = RecordingCleanupClient(failingOperands: [first.resourceID])
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)

        await store.remove(selection: [first, second], using: appStore)

        #expect(store.removalReport?.items.map(\.state) == [
            .failed("failed"), .removed,
        ])
        #expect(await client.recordedArguments().count == 2)
    }

    @MainActor
    @Test func stopRequestFinishesCurrentItemAndDoesNotStartTheNext() async throws {
        let first = candidate("sha256:first")
        let second = candidate("sha256:second")
        let service = StubCleanupService(candidates: [first, second], validation: [first.id: [true, false]])
        let client = RecordingCleanupClient(runDelay: .milliseconds(120))
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)

        let removal = Task { await store.remove(selection: [first, second], using: appStore) }
        try await Task.sleep(for: .milliseconds(25))
        store.stopAfterCurrent()
        await removal.value

        #expect(await client.recordedArguments().count == 1)
        #expect(store.removalReport?.stopped == true)
        #expect(store.removalReport?.items.map(\.state) == [.removed, .notAttempted])
    }

    @MainActor
    @Test func simultaneousRemovalCallCannotStartASecondQueue() async throws {
        let first = candidate("sha256:only")
        let service = StubCleanupService(candidates: [first], validation: [first.id: [true, false, true, false]])
        let client = RecordingCleanupClient(runDelay: .milliseconds(100))
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)

        let firstQueue = Task { await store.remove(selection: [first], using: appStore) }
        try await Task.sleep(for: .milliseconds(15))
        await store.remove(selection: [first], using: appStore)
        await firstQueue.value

        #expect(await client.recordedArguments().count == 1)
        #expect(store.removalReport?.items.count == 1)
    }

    @MainActor
    @Test func invalidatingConfigurationStopsTheQueueBeforeAnotherTarget() async throws {
        let first = candidate("sha256:first-config")
        let second = candidate("sha256:second-config")
        let service = StubCleanupService(candidates: [first, second], validation: [first.id: [true, false]])
        let client = RecordingCleanupClient(runDelay: .milliseconds(110))
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)

        let removal = Task { await store.remove(selection: [first, second], using: appStore) }
        try await Task.sleep(for: .milliseconds(20))
        store.invalidate()
        await removal.value

        #expect(await client.recordedArguments().count == 1)
        #expect(store.scanResult == nil)
        #expect(store.removalReport?.stopped == true)
        #expect(store.removalReport?.items.map(\.state) == [.removed, .notAttempted])
    }

    @MainActor
    @Test func unverifiedPostCheckIsNeverCountedAsRemoved() async throws {
        let item = candidate("sha256:uncertain")
        let service = StubCleanupService(candidates: [item], validation: [item.id: [true]])
        service.verification[item.id] = [.unverified("The image inventory could not be read.")]
        let client = RecordingCleanupClient()
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)

        await store.remove(selection: [item], using: appStore)

        #expect(store.removalReport?.items.map(\.state) == [.unverified("The image inventory could not be read.")])
    }

    @MainActor
    @Test func stopDuringRevalidationDoesNotStartTheNextDelete() async throws {
        let first = candidate("sha256:validation-one")
        let second = candidate("sha256:validation-two")
        let service = StubCleanupService(candidates: [first, second], validation: [first.id: [true]])
        service.holdNextValidation()
        let client = RecordingCleanupClient()
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)

        let removal = Task { await store.remove(selection: [first, second], using: appStore) }
        while !service.isHoldingValidation { await Task.yield() }
        store.stopAfterCurrent()
        service.releaseValidation()
        await removal.value

        #expect(await client.recordedArguments().isEmpty)
        #expect(store.removalReport?.items.map(\.state) == [.notAttempted, .notAttempted])
    }

    @MainActor
    @Test func configurationChangeDuringFinalScanPreservesRemovalResults() async {
        let first = candidate("sha256:final-scan")
        let service = StubCleanupService(candidates: [first], validation: [:])
        let client = RecordingCleanupClient()
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)
        service.onScan = { [weak store] in store?.invalidate() }

        await store.remove(selection: [first], using: appStore)

        #expect(store.scanResult == nil)
        #expect(store.removalReport?.stopped == true)
        #expect(store.removalReport?.items.map(\.state) == [.removed])
    }

    @MainActor
    @Test func duplicateAndStaleReviewedSelectionsAreHandledWithoutGuessing() async throws {
        let reviewed = candidate("sha256:same-id")
        let service = StubCleanupService(candidates: [reviewed], validation: [:])
        let client = RecordingCleanupClient()
        let appStore = AppStore(client: client)
        let store = CleanupStore(serviceFactory: { _ in service })
        await store.scan(using: appStore)
        let replacement = CleanupCandidate(
            category: .images,
            resourceID: reviewed.resourceID,
            title: "Replaced image",
            reason: "New identity",
            identity: .image(digest: "sha256:different", reference: "replacement", aliases: [], sizeBytes: 100)
        )
        service.replaceCandidates([replacement])
        await store.scan(using: appStore)

        await store.remove(selection: [reviewed, reviewed], using: appStore)

        #expect(await client.recordedArguments().isEmpty)
        #expect(store.removalReport?.items == [CleanupItemResult(candidate: reviewed, state: .skipped("The reviewed resource changed after this scan."))])
    }

    private func candidate(_ id: String) -> CleanupCandidate {
        CleanupCandidate(
            category: .images,
            resourceID: id,
            title: id,
            reason: "Unused image",
            identity: .image(digest: id, reference: id, aliases: [], sizeBytes: 100)
        )
    }
}

@MainActor
private final class StubCleanupService: CleanupServicing {
    var onScan: (() -> Void)?
    private var candidates: [CleanupCandidate]
    private var validation: [String: [Bool]]
    private var validationIndexes: [String: Int] = [:]
    var verification: [String: [CleanupRemovalVerification]] = [:]
    private var verificationIndexes: [String: Int] = [:]
    private var holdValidation = false
    private var validationContinuation: CheckedContinuation<Void, Never>?
    private(set) var isHoldingValidation = false

    init(candidates: [CleanupCandidate], validation: [String: [Bool]]) {
        self.candidates = candidates
        self.validation = validation
    }

    func scan() async -> CleanupScan {
        onScan?()
        return CleanupScan(candidates: candidates, warnings: [], categoryFailures: [:], diskUsage: nil)
    }

    func revalidate(_ candidate: CleanupCandidate) async -> CleanupEligibility {
        if holdValidation {
            holdValidation = false
            isHoldingValidation = true
            await withCheckedContinuation { validationContinuation = $0 }
            isHoldingValidation = false
        }
        let entries = validation[candidate.id] ?? [true]
        let index = validationIndexes[candidate.id, default: 0]
        validationIndexes[candidate.id] = min(index + 1, entries.count - 1)
        let eligible = entries[min(index, entries.count - 1)]
        return CleanupEligibility(eligible: eligible, reason: eligible ? "Still unused" : "No longer present")
    }

    func verifyRemoval(_ candidate: CleanupCandidate) async -> CleanupRemovalVerification {
        let entries = verification[candidate.id] ?? [.removed]
        let index = verificationIndexes[candidate.id, default: 0]
        verificationIndexes[candidate.id] = min(index + 1, entries.count - 1)
        return entries[min(index, entries.count - 1)]
    }

    func replaceCandidates(_ candidates: [CleanupCandidate]) { self.candidates = candidates }
    func holdNextValidation() { holdValidation = true }
    func releaseValidation() { validationContinuation?.resume(); validationContinuation = nil }

    func command(for candidate: CleanupCandidate) throws -> CommandRequest {
        CommandRequest(arguments: ["remove", "image", candidate.resourceID])
    }
}

private actor RecordingCleanupClient: ContainerClient {
    private var arguments: [[String]] = []
    private let failingOperands: Set<String>
    private let runDelay: Duration

    init(failingOperands: Set<String> = [], runDelay: Duration = .zero) {
        self.failingOperands = failingOperands
        self.runDelay = runDelay
    }

    func recordedArguments() -> [[String]] { arguments }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        arguments.append(request.arguments)
        if runDelay > .zero { try await Task.sleep(for: runDelay) }
        let operand = request.arguments.last ?? ""
        let failed = failingOperands.contains(operand)
        return CommandResult(
            standardOutput: "",
            standardError: failed ? "failed" : "",
            exitCode: failed ? 1 : 0,
            terminationReason: .exit,
            duration: .zero
        )
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
