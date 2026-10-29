import Foundation
import Testing
@testable import ContainerDeskCore

@Suite(.serialized)
struct MLXModelCatalogSingleFlightTests {
    @Test func simultaneousRefreshesForSameConfigurationShareOneScan() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("managed"))
        let scanner = HeldCatalogScanner()
        let service = DefaultMLXModelService(configuration: configuration, environment: [:], catalogScanner: scanner)
        defer {
            scanner.release(configuration)
            Task { await service.shutdown() }
        }

        let first = Task { try await service.listLocalModels() }
        let firstScanStarted = await scanner.waitForInvocationCount(1)
        #expect(firstScanStarted)
        let second = Task { try await service.listLocalModels() }

        // Let the actor process the second request while the shared scan is held.
        try await Task.sleep(for: .milliseconds(25))
        let sameConfigScanCount = scanner.invocationCount()
        #expect(sameConfigScanCount == 1)
        // Release before awaiting either caller so RED failures cannot strand the fake.
        scanner.release(configuration)

        let firstModels = try await first.value
        let secondModels = try await second.value
        #expect(firstModels == secondModels)
        #expect(firstModels.map(\.id) == ["scan:managed"])
        #expect(scanner.maximumConcurrentScans() == 1)
    }

    @Test func cancellingOneCoalescedWaiterDoesNotCancelSharedScan() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("shared"))
        let scanner = HeldCatalogScanner()
        let service = DefaultMLXModelService(configuration: configuration, environment: [:], catalogScanner: scanner)
        defer {
            scanner.release(configuration)
            Task { await service.shutdown() }
        }

        let survivingWaiter = Task { try await service.listLocalModels() }
        let scanStarted = await scanner.waitForInvocationCount(1)
        #expect(scanStarted)
        let cancelledWaiter = Task { try await service.listLocalModels() }

        // Give the service actor time to attach the second caller to the held shared scan.
        try await Task.sleep(for: .milliseconds(25))
        cancelledWaiter.cancel()
        try await Task.sleep(for: .milliseconds(10))
        scanner.release(configuration)

        let survivingModels = try await survivingWaiter.value
        let cancelledResult = await cancelledWaiter.result
        if case .success = cancelledResult {
            Issue.record("A canceled waiter should receive cancellation rather than a scan result.")
        } else if case .failure(let error) = cancelledResult {
            #expect(error is CancellationError)
        }
        #expect(survivingModels.map(\.id) == ["scan:shared"])
        #expect(scanner.invocationCount() == 1)
        #expect(scanner.maximumConcurrentScans() == 1)
    }

    @Test func configurationChangeDrainsOldScanBeforeStartingLatestScan() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstConfiguration = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("first"))
        let latestConfiguration = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("latest"))
        let scanner = HeldCatalogScanner()
        let service = DefaultMLXModelService(configuration: firstConfiguration, environment: [:], catalogScanner: scanner)
        defer {
            scanner.release(firstConfiguration)
            scanner.release(latestConfiguration)
            Task { await service.shutdown() }
        }

        let staleRequest = Task { try await service.listLocalModels() }
        let firstScanStarted = await scanner.waitForInvocationCount(1)
        #expect(firstScanStarted)
        await service.configure(latestConfiguration)
        let latestRequest = Task { try await service.listLocalModels() }

        let oldScanWasCancelled = await scanner.waitForCancellation(of: firstConfiguration)
        #expect(oldScanWasCancelled)
        try await Task.sleep(for: .milliseconds(25))
        #expect(scanner.invocationCount() == 1)
        #expect(scanner.maximumConcurrentScans() == 1)

        // Release every possible scanner path before awaiting either task, even when RED
        // behavior never canceled the old scan or never started the latest scan.
        scanner.release(firstConfiguration)
        scanner.release(latestConfiguration)
        do {
            _ = try await staleRequest.value
            Issue.record("A scan for an obsolete configuration must not publish a result.")
        } catch is CancellationError {
            // The canceled scan is expected to drain before the latest scan starts.
        } catch {
            // A service-specific stale-scan error is also acceptable.
        }

        let latestScanStarted = await scanner.waitForInvocationCount(2)
        #expect(latestScanStarted)
        let latestModels = try await latestRequest.value
        #expect(latestModels.map(\.id) == ["scan:latest"])
        #expect(scanner.invocationCount() == 2)
        #expect(scanner.maximumConcurrentScans() == 1)
    }

    @Test func configurationRoundTripDoesNotReuseCancelledScanForLatestValue() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationA = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("round-trip-a"))
        let configurationB = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("round-trip-b"))
        let scanner = HeldCatalogScanner()
        let service = DefaultMLXModelService(configuration: configurationA, environment: [:], catalogScanner: scanner)
        defer {
            scanner.release(configurationA)
            scanner.release(configurationB)
            Task { await service.shutdown() }
        }

        let oldCaller = Task { try await service.listLocalModels() }
        let firstScanStarted = await scanner.waitForInvocationCount(1)
        #expect(firstScanStarted)

        await service.configure(configurationB)
        await service.configure(configurationA)
        let freshCaller = Task { try await service.listLocalModels() }
        let oldScanWasCancelled = await scanner.waitForCancellation(of: configurationA)
        #expect(oldScanWasCancelled)
        try await Task.sleep(for: .milliseconds(25))
        #expect(scanner.invocationCount() == 1)
        #expect(scanner.maximumConcurrentScans() == 1)

        // The fake uses the same path for both A scans; opening it releases the obsolete
        // scan first, after which the fresh A scan can enter and complete.
        scanner.release(configurationA)
        let oldResult = await oldCaller.result
        if case .success = oldResult {
            Issue.record("The caller waiting on the canceled first A scan must not publish it.")
        } else if case .failure(let error) = oldResult {
            #expect(error is CancellationError)
        }

        let freshModels = try await freshCaller.value
        #expect(freshModels.map(\.id) == ["scan:round-trip-a"])
        #expect(scanner.invocationCount() == 2)
        #expect(scanner.maximumConcurrentScans() == 1)
    }

    @Test func shutdownCancelsAndDrainsCatalogScanAndRejectsLaterRefreshes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MLXConfiguration(managedModelsDirectory: root.appendingPathComponent("shutdown"))
        let scanner = HeldCatalogScanner(releaseWhenCancelled: true)
        let service = DefaultMLXModelService(configuration: configuration, environment: [:], catalogScanner: scanner)
        defer {
            scanner.release(configuration)
            Task { await service.shutdown() }
        }

        let activeRequest = Task { try await service.listLocalModels() }
        let scanStarted = await scanner.waitForInvocationCount(1)
        #expect(scanStarted)
        let shutdownTask = Task { await service.shutdown() }
        let scanWasCancelled = await scanner.waitForCancellation(of: configuration)
        #expect(scanWasCancelled)
        // Always open the gate before awaiting shutdown or any service task. Baseline
        // behavior does not cancel the scanner, so waiting first would deadlock RED.
        scanner.release(configuration)
        await shutdownTask.value
        _ = await activeRequest.result

        let laterRequest = Task { try await service.listLocalModels() }
        _ = await laterRequest.result
        #expect(scanner.wasCancelled(configuration))
        #expect(scanner.invocationCount() == 1)
        #expect(scanner.activeScanCount() == 0)
    }
}

private final class HeldCatalogScanner: MLXModelCatalogScanning, @unchecked Sendable {
    private let condition = NSCondition()
    private let releaseWhenCancelled: Bool
    private var configurations: [String] = []
    private var activeCount = 0
    private var maxActiveCount = 0
    private var releasedPaths = Set<String>()
    private var cancellationByPath: [String: Bool] = [:]

    init(releaseWhenCancelled: Bool = false) {
        self.releaseWhenCancelled = releaseWhenCancelled
    }

    func scan(
        configuration: MLXConfiguration,
        environment: [String: String],
        cancellation: MLXCatalogScanCancellation
    ) throws -> [MLXModelRecord] {
        let path = configuration.managedModelsDirectory.path
        condition.lock()
        configurations.append(path)
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
        condition.broadcast()
        while !releasedPaths.contains(path) && !(releaseWhenCancelled && cancellation.isCancelled) {
            _ = condition.wait(until: Date.now.addingTimeInterval(0.01))
            if cancellation.isCancelled { cancellationByPath[path] = true }
        }
        activeCount -= 1
        if cancellation.isCancelled { cancellationByPath[path] = true }
        condition.broadcast()
        condition.unlock()

        try cancellation.throwIfCancelled()
        return [MLXModelRecord(
            id: "scan:\(URL(fileURLWithPath: path).lastPathComponent)",
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            path: URL(fileURLWithPath: path),
            source: .importedDirectory,
            diskBytes: 0,
            fileCount: 0
        )]
    }

    func invocationCount() -> Int {
        condition.lock(); defer { condition.unlock() }
        return configurations.count
    }

    func activeScanCount() -> Int {
        condition.lock(); defer { condition.unlock() }
        return activeCount
    }

    func maximumConcurrentScans() -> Int {
        condition.lock(); defer { condition.unlock() }
        return maxActiveCount
    }

    func wasCancelled(_ configuration: MLXConfiguration) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return cancellationByPath[configuration.managedModelsDirectory.path] == true
    }

    func release(_ configuration: MLXConfiguration) {
        condition.lock(); releasedPaths.insert(configuration.managedModelsDirectory.path); condition.broadcast(); condition.unlock()
    }

    func waitForInvocationCount(_ expected: Int) async -> Bool {
        let deadline = Date.now.addingTimeInterval(2)
        while invocationCount() < expected, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return invocationCount() >= expected
    }

    func waitForCancellation(of configuration: MLXConfiguration) async -> Bool {
        let deadline = Date.now.addingTimeInterval(2)
        while !wasCancelled(configuration), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return wasCancelled(configuration)
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MLXCatalogSingleFlight-\(UUID().uuidString)", isDirectory: true)
}
