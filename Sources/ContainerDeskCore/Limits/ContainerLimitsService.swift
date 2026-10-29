import ContainerAPIClient
import ContainerResource
import ContainerPersistence
import ContainerRuntimeClient
import Containerization
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation

public struct ContainerResourceLimits: Sendable, Equatable, Codable {
    public let cpus: Int
    public let memoryBytes: UInt64

    public init(cpus: Int, memoryBytes: UInt64) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }
}

public struct ContainerLimitsPlan: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let containerID: String
    public let imageReference: String
    public let wasRunning: Bool
    public let currentLimits: ContainerResourceLimits
    public let maximumCPUs: Int
    public let maximumMemoryBytes: UInt64

    fileprivate init(
        id: UUID,
        containerID: String,
        imageReference: String,
        wasRunning: Bool,
        currentLimits: ContainerResourceLimits,
        maximumCPUs: Int,
        maximumMemoryBytes: UInt64
    ) {
        self.id = id
        self.containerID = containerID
        self.imageReference = imageReference
        self.wasRunning = wasRunning
        self.currentLimits = currentLimits
        self.maximumCPUs = maximumCPUs
        self.maximumMemoryBytes = maximumMemoryBytes
    }
}

public enum ContainerLimitsProgress: Sendable, Equatable {
    case validating
    case backingUp
    case stopping
    case replacing
    case starting
    case verifying
    case rollingBack
}

public enum ContainerLimitsIssue: String, Sendable, Equatable, Codable, LocalizedError {
    case unsupportedCLI
    case unsupportedContainer
    case invalidLimits
    case staleReview
    case backupFailed
    case stopFailed
    case replacementFailed
    case verificationFailed
    case rollbackFailed
    case noChange

    public var errorDescription: String? {
        switch self {
        case .unsupportedCLI: "Edit limits requires the default Apple container CLI and API server version 1.5.0."
        case .unsupportedContainer: "This container configuration cannot be safely recreated with its current filesystem and settings."
        case .invalidLimits: "Choose CPU and memory limits within the supported range."
        case .staleReview: "The container changed after this review. Review its current settings again."
        case .backupFailed: "A verified recovery copy could not be created. The original container was kept."
        case .stopFailed: "The original container could not be stopped and verified safely."
        case .replacementFailed: "The replacement could not be created. The original settings were restored when possible."
        case .verificationFailed: "The replacement did not pass post-change verification."
        case .rollbackFailed: "Automatic restoration did not complete. The recovery copy was retained."
        case .noChange: "The selected limits are already active."
        }
    }
}

public enum ContainerLimitsApplyResult: Sendable, Equatable {
    case unchanged(reason: ContainerLimitsIssue)
    case updated(recoveryURL: URL)
    case rolledBack(recoveryURL: URL, reason: ContainerLimitsIssue)
    case recoveryNeeded(recoveryURL: URL, reason: ContainerLimitsIssue)
}

/// A stop/recreate operation that keeps the existing writable filesystem as a verified recovery copy.
/// The pinned Apple container 1.5.0 API has no in-place CPU/memory update endpoint.
public actor ContainerLimitsService {
    private let runtime: any ContainerLimitsRuntime
    private let recoveryRoot: URL
    private var prepared: [UUID: PreparedLimitsChange] = [:]
    private var applyingContainerIDs: Set<String> = []

    public init(client: any ContainerClient = ProcessContainerClient(), recoveryDirectory: URL? = nil) {
        self.runtime = AppleContainerLimitsRuntime(cli: client)
        self.recoveryRoot = recoveryDirectory ?? Self.defaultRecoveryDirectory()
    }

    init(runtime: any ContainerLimitsRuntime, recoveryDirectory: URL) {
        self.runtime = runtime
        self.recoveryRoot = recoveryDirectory
    }

    public func prepare(id: String) async throws -> ContainerLimitsPlan {
        guard !applyingContainerIDs.contains(id) else { throw ContainerLimitsIssue.staleReview }
        guard let state = try await runtime.inspect(id: id) else { throw ContainerLimitsIssue.unsupportedContainer }
        try Self.validateConfiguration(state, recoveryRoot: recoveryRoot)
        let wasRunning: Bool
        switch state.snapshot.status {
        case .running: wasRunning = true
        case .stopped: wasRunning = false
        case .stopping, .unknown: throw ContainerLimitsIssue.unsupportedContainer
        }
        let resources = state.snapshot.configuration.resources
        let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
        guard hostCPUs > 0, resources.cpuOverhead >= 0, resources.cpuOverhead < hostCPUs,
              resources.cpus > 0, resources.memoryInBytes > 0 else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
        let maxCPUs = hostCPUs - resources.cpuOverhead
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let guestOverhead = 128 * Self.mebibyte
        let maxMemory = physicalMemory > guestOverhead
            ? (physicalMemory - guestOverhead) / Self.mebibyte * Self.mebibyte
            : 0
        guard maxCPUs >= 1, maxMemory >= Self.minimumMemoryBytes else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
        let plan = ContainerLimitsPlan(
            id: UUID(),
            containerID: id,
            imageReference: state.snapshot.configuration.image.reference,
            wasRunning: wasRunning,
            currentLimits: ContainerResourceLimits(cpus: resources.cpus, memoryBytes: resources.memoryInBytes),
            maximumCPUs: maxCPUs,
            maximumMemoryBytes: maxMemory
        )
        if prepared.count >= 16 { prepared.removeAll(keepingCapacity: true) }
        prepared[plan.id] = PreparedLimitsChange(plan: plan, state: state, configDigest: Self.digest(state.snapshot.configuration))
        return plan
    }

    /// Discards the opaque, in-memory full configuration associated with a dismissed review.
    public func discard(planID: UUID) {
        prepared.removeValue(forKey: planID)
    }

    public func apply(
        _ plan: ContainerLimitsPlan,
        limits: ContainerResourceLimits,
        onProgress: @escaping @Sendable (ContainerLimitsProgress) async -> Void = { _ in }
    ) async -> ContainerLimitsApplyResult {
        guard let change = prepared.removeValue(forKey: plan.id), change.plan == plan,
              !applyingContainerIDs.contains(plan.containerID) else {
            return .unchanged(reason: .staleReview)
        }
        applyingContainerIDs.insert(plan.containerID)
        defer { applyingContainerIDs.remove(plan.containerID) }

        await onProgress(.validating)
        guard Self.valid(limits, plan: plan) else { return .unchanged(reason: .invalidLimits) }
        guard limits != plan.currentLimits else { return .unchanged(reason: .noChange) }

        let initImageReference: String
        let neverStarted: Bool
        do {
            guard let fresh = try await runtime.inspect(id: plan.containerID),
                  fresh.snapshot.status == (plan.wasRunning ? .running : .stopped),
                  Self.matches(change, fresh: fresh) else { return .unchanged(reason: .staleReview) }
            try Self.validateConfiguration(fresh, recoveryRoot: recoveryRoot)
            neverStarted = Self.isNeverStarted(fresh)
            initImageReference = try await runtime.preflightCreate(platform: fresh.snapshot.platform)
        } catch {
            return .unchanged(reason: (error as? ContainerLimitsIssue) ?? .unsupportedContainer)
        }

        if neverStarted {
            return await applyNeverStarted(change, limits: limits, initImageReference: initImageReference, onProgress: onProgress)
        }

        let sessionURL: URL
        do {
            sessionURL = try Self.createRecoverySession(root: recoveryRoot)
        } catch {
            return .unchanged(reason: .backupFailed)
        }
        let recovery = RecoveryFiles(directory: sessionURL)
        var oldContainerDeleted = false
        var replacementCreated = false
        var backup: RecoveryInputs?
        var newConfiguration: ContainerConfiguration?

        do {
            if plan.wasRunning {
                await onProgress(.stopping)
                guard let beforeStop = try await runtime.inspect(id: plan.containerID),
                      beforeStop.snapshot.status == .running, Self.matches(change, fresh: beforeStop) else {
                    throw ContainerLimitsIssue.staleReview
                }
                try await runtime.stop(id: plan.containerID)
                guard let stopped = try await runtime.inspect(id: plan.containerID) else { throw ContainerLimitsIssue.stopFailed }
                guard stopped.snapshot.status == .stopped, Self.matches(change, fresh: stopped) else {
                    throw ContainerLimitsIssue.stopFailed
                }
            }

            await onProgress(.backingUp)
            guard let stoppedState = try await runtime.inspect(id: plan.containerID) else { throw ContainerLimitsIssue.staleReview }
            guard stoppedState.snapshot.status == .stopped, Self.matches(change, fresh: stoppedState) else {
                throw ContainerLimitsIssue.staleReview
            }
            try Self.validateConfiguration(stoppedState, recoveryRoot: recoveryRoot)
            do {
                backup = try Self.writeVerifiedBackup(stoppedState: stoppedState, files: recovery)
            } catch {
                throw ContainerLimitsIssue.backupFailed
            }
            guard let backup else { throw ContainerLimitsIssue.backupFailed }

            // The original identity and stopped state are checked again immediately before the exact delete.
            guard let beforeDelete = try await runtime.inspect(id: plan.containerID) else { throw ContainerLimitsIssue.staleReview }
            guard beforeDelete.snapshot.status == .stopped, Self.matches(change, fresh: beforeDelete) else {
                throw ContainerLimitsIssue.staleReview
            }
            try Self.validateConfiguration(beforeDelete, recoveryRoot: recoveryRoot)
            guard let rootfsFingerprint = backup.rootfsFingerprint,
                  try Self.fileDigest(URL(fileURLWithPath: beforeDelete.rootFilesystem.source)) == rootfsFingerprint,
                  try Self.fileDigest(URL(fileURLWithPath: beforeDelete.initialFilesystem.source)) == backup.initfsFingerprint,
                  try Self.fileDigest(beforeDelete.kernel.path) == backup.kernelFingerprint else {
                throw ContainerLimitsIssue.staleReview
            }
            guard try await runtime.preflightCreate(platform: stoppedState.snapshot.platform) == initImageReference else {
                throw ContainerLimitsIssue.staleReview
            }

            await onProgress(.replacing)
            let newConfigurationValue = Self.configuration(
                stoppedState.snapshot.configuration,
                limits: limits,
                creationDate: Self.nextCreationDate(after: stoppedState.snapshot.configuration.creationDate)
            )
            newConfiguration = newConfigurationValue
            do {
                try await runtime.delete(id: plan.containerID)
                oldContainerDeleted = true
            } catch {
                do {
                    if try await runtime.inspect(id: plan.containerID) == nil { oldContainerDeleted = true }
                } catch {
                    // The delete outcome is ambiguous. Preserve backup and enter recovery flow.
                    oldContainerDeleted = true
                }
                throw error
            }
            guard try await runtime.inspect(id: plan.containerID) == nil else {
                throw ContainerLimitsIssue.verificationFailed
            }
            guard !FileManager.default.fileExists(atPath: stoppedState.bundlePath.path) else {
                throw ContainerLimitsIssue.verificationFailed
            }

            var rootfsOverride = stoppedState.rootFilesystem
            rootfsOverride.source = stoppedState.bundlePath.appendingPathComponent("rootfs.ext4").path
            let options = ContainerCreateOptions(autoRemove: false, rootFsOverride: rootfsOverride)
            try await runtime.create(configuration: newConfigurationValue, options: options, kernel: backup.kernel, initImage: initImageReference)
            replacementCreated = true

            // Use the exact old init filesystem/kernel. The create API resolves defaults first, so patch
            // only the brand-new cold runtime configuration before its first bootstrap.
            guard let created = try await runtime.inspect(id: plan.containerID),
                  created.snapshot.status == .stopped,
                  Self.digest(created.snapshot.configuration) == Self.digest(newConfigurationValue),
                  created.bundlePath.standardizedFileURL == stoppedState.bundlePath.standardizedFileURL else {
                throw ContainerLimitsIssue.verificationFailed
            }
            try Self.copyVerified(recovery.rootfs, to: stoppedState.bundlePath.appendingPathComponent("rootfs.ext4"))
            let coldRuntimeConfiguration = RuntimeConfiguration(
                path: stoppedState.bundlePath,
                initialFilesystem: backup.initialFilesystem,
                kernel: backup.kernel,
                containerConfiguration: newConfigurationValue,
                containerRootFilesystem: nil,
                options: options,
                runtimeData: stoppedState.runtimeConfiguration.runtimeData
            )
            try await runtime.replaceColdRuntimeConfiguration(coldRuntimeConfiguration)
            guard let afterCreate = try await runtime.inspect(id: plan.containerID) else { throw ContainerLimitsIssue.verificationFailed }
            guard afterCreate.snapshot.status == .stopped,
                  Self.digest(afterCreate.snapshot.configuration) == Self.digest(newConfigurationValue) else {
                throw ContainerLimitsIssue.verificationFailed
            }

            if plan.wasRunning {
                await onProgress(.starting)
                try await runtime.start(id: plan.containerID)
            }
            await onProgress(.verifying)
            guard let final = try await runtime.inspect(id: plan.containerID) else { throw ContainerLimitsIssue.verificationFailed }
            let expectedStatus: RuntimeStatus = plan.wasRunning ? .running : .stopped
            guard final.snapshot.status == expectedStatus,
                  Self.digest(final.snapshot.configuration) == Self.digest(newConfigurationValue) else {
                throw ContainerLimitsIssue.verificationFailed
            }
            return .updated(recoveryURL: sessionURL)
        } catch {
            let issue = (error as? ContainerLimitsIssue) ?? .replacementFailed
            guard oldContainerDeleted else {
                if plan.wasRunning {
                    await onProgress(.rollingBack)
                    do {
                        guard let current = try await runtime.inspect(id: plan.containerID), Self.matches(change, fresh: current) else {
                            return .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed)
                        }
                        if current.snapshot.status == .stopped {
                            try await runtime.start(id: plan.containerID)
                            guard let restored = try await runtime.inspect(id: plan.containerID) else {
                                return .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed)
                            }
                            guard restored.snapshot.status == .running, Self.matches(change, fresh: restored) else {
                                return .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed)
                            }
                        } else if current.snapshot.status != .running {
                            return .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed)
                        }
                    } catch {
                        return .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed)
                    }
                }
                try? FileManager.default.removeItem(at: sessionURL)
                if FileManager.default.fileExists(atPath: sessionURL.path) {
                    return .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed)
                }
                return .unchanged(reason: issue)
            }

            await onProgress(.rollingBack)
            guard let backup else { return .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed) }
            let rollbackSucceeded = await rollback(
                change: change,
                limits: plan.currentLimits,
                recovery: recovery,
                backup: backup,
                replacementLimits: limits,
                replacementConfiguration: newConfiguration,
                replacementCreated: replacementCreated,
                initImageReference: initImageReference
            )
            return rollbackSucceeded
                ? .rolledBack(recoveryURL: sessionURL, reason: issue)
                : .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed)
        }
    }

    /// Recreates a never-bootstrapped container from its cold runtime configuration. No writable
    /// root filesystem exists in this state, so there is no container data to copy or discard.
    /// This path deliberately never starts the container.
    private func applyNeverStarted(
        _ change: PreparedLimitsChange,
        limits: ContainerResourceLimits,
        initImageReference: String,
        onProgress: @escaping @Sendable (ContainerLimitsProgress) async -> Void
    ) async -> ContainerLimitsApplyResult {
        let plan = change.plan
        let sessionURL: URL
        do {
            sessionURL = try Self.createRecoverySession(root: recoveryRoot)
        } catch {
            return .unchanged(reason: .backupFailed)
        }
        let files = RecoveryFiles(directory: sessionURL)
        var oldContainerDeleted = false
        var replacementConfiguration: ContainerConfiguration?
        var backup: RecoveryInputs?

        do {
            await onProgress(.backingUp)
            guard let original = try await runtime.inspect(id: plan.containerID),
                  original.snapshot.status == .stopped, Self.matches(change, fresh: original),
                  Self.isNeverStarted(original) else { throw ContainerLimitsIssue.staleReview }
            try Self.validateConfiguration(original, recoveryRoot: recoveryRoot)
            backup = try Self.writeVerifiedBackup(stoppedState: original, files: files, includeRootFilesystem: false)
            guard let backup else { throw ContainerLimitsIssue.backupFailed }

            guard let beforeDelete = try await runtime.inspect(id: plan.containerID),
                  beforeDelete.snapshot.status == .stopped, Self.matches(change, fresh: beforeDelete),
                  Self.isNeverStarted(beforeDelete),
                  try Self.fileDigest(URL(fileURLWithPath: beforeDelete.initialFilesystem.source)) == backup.initfsFingerprint,
                  try Self.fileDigest(beforeDelete.kernel.path) == backup.kernelFingerprint else {
                throw ContainerLimitsIssue.staleReview
            }
            try Self.validateConfiguration(beforeDelete, recoveryRoot: recoveryRoot)
            guard try await runtime.preflightCreate(platform: original.snapshot.platform) == initImageReference else {
                throw ContainerLimitsIssue.staleReview
            }

            let updatedConfiguration = Self.configuration(
                original.snapshot.configuration,
                limits: limits,
                creationDate: Self.nextCreationDate(after: original.snapshot.configuration.creationDate)
            )
            replacementConfiguration = updatedConfiguration
            await onProgress(.replacing)
            do {
                try await runtime.delete(id: plan.containerID)
                oldContainerDeleted = true
            } catch {
                do {
                    if try await runtime.inspect(id: plan.containerID) == nil { oldContainerDeleted = true }
                } catch {
                    oldContainerDeleted = true
                }
                throw error
            }
            guard try await runtime.inspect(id: plan.containerID) == nil,
                  !FileManager.default.fileExists(atPath: original.bundlePath.path) else {
                throw ContainerLimitsIssue.verificationFailed
            }

            let options = original.options ?? ContainerCreateOptions(autoRemove: false)
            try await runtime.create(configuration: updatedConfiguration, options: options, kernel: backup.kernel, initImage: initImageReference)
            guard let created = try await runtime.inspect(id: plan.containerID),
                  created.snapshot.status == .stopped,
                  Self.digest(created.snapshot.configuration) == Self.digest(updatedConfiguration),
                  created.bundlePath.standardizedFileURL == original.bundlePath.standardizedFileURL,
                  Self.isNeverStarted(created) else { throw ContainerLimitsIssue.verificationFailed }

            let coldConfiguration = RuntimeConfiguration(
                path: original.bundlePath,
                initialFilesystem: backup.initialFilesystem,
                kernel: backup.kernel,
                containerConfiguration: updatedConfiguration,
                containerRootFilesystem: original.runtimeConfiguration.containerRootFilesystem,
                options: original.options,
                runtimeData: original.runtimeConfiguration.runtimeData
            )
            try await runtime.replaceColdRuntimeConfiguration(coldConfiguration)
            guard let final = try await runtime.inspect(id: plan.containerID),
                  final.snapshot.status == .stopped,
                  Self.digest(final.snapshot.configuration) == Self.digest(updatedConfiguration),
                  Self.isNeverStarted(final) else { throw ContainerLimitsIssue.verificationFailed }
            await onProgress(.verifying)
            return .updated(recoveryURL: sessionURL)
        } catch {
            let issue = (error as? ContainerLimitsIssue) ?? .replacementFailed
            guard oldContainerDeleted, let backup else {
                try? FileManager.default.removeItem(at: sessionURL)
                return .unchanged(reason: issue)
            }
            await onProgress(.rollingBack)
            let restored = await rollbackNeverStarted(
                change: change,
                backup: backup,
                replacementConfiguration: replacementConfiguration,
                initImageReference: initImageReference
            )
            return restored
                ? .rolledBack(recoveryURL: sessionURL, reason: issue)
                : .recoveryNeeded(recoveryURL: sessionURL, reason: .rollbackFailed)
        }
    }

    private func rollbackNeverStarted(
        change: PreparedLimitsChange,
        backup: RecoveryInputs,
        replacementConfiguration: ContainerConfiguration?,
        initImageReference: String
    ) async -> Bool {
        let id = change.plan.containerID
        do {
            if let current = try await runtime.inspect(id: id) {
                guard let replacementConfiguration,
                      Self.digest(current.snapshot.configuration) == Self.digest(replacementConfiguration),
                      current.snapshot.status == .stopped, Self.isNeverStarted(current) else { return false }
                try await runtime.delete(id: id)
                guard try await runtime.inspect(id: id) == nil,
                      !FileManager.default.fileExists(atPath: change.state.bundlePath.path) else { return false }
            }
            let original = change.state
            guard Self.isNeverStarted(original) else { return false }
            var restoredConfiguration = Self.configuration(
                original.snapshot.configuration,
                limits: change.plan.currentLimits,
                creationDate: Self.nextCreationDate(after: original.snapshot.configuration.creationDate)
            )
            // Preserve all original settings; only creationDate changes as required by the CLI identity.
            restoredConfiguration.labels = original.snapshot.configuration.labels
            let options = original.options ?? ContainerCreateOptions(autoRemove: false)
            try await runtime.create(configuration: restoredConfiguration, options: options, kernel: backup.kernel, initImage: initImageReference)
            guard let created = try await runtime.inspect(id: id),
                  created.snapshot.status == .stopped,
                  Self.digest(created.snapshot.configuration) == Self.digest(restoredConfiguration),
                  Self.isNeverStarted(created) else { return false }
            let coldConfiguration = RuntimeConfiguration(
                path: original.bundlePath,
                initialFilesystem: backup.initialFilesystem,
                kernel: backup.kernel,
                containerConfiguration: restoredConfiguration,
                containerRootFilesystem: original.runtimeConfiguration.containerRootFilesystem,
                options: original.options,
                runtimeData: original.runtimeConfiguration.runtimeData
            )
            try await runtime.replaceColdRuntimeConfiguration(coldConfiguration)
            guard let final = try await runtime.inspect(id: id),
                  final.snapshot.status == .stopped,
                  Self.digest(final.snapshot.configuration) == Self.digest(restoredConfiguration),
                  Self.isNeverStarted(final) else { return false }
            return true
        } catch {
            return false
        }
    }

    private func rollback(
        change: PreparedLimitsChange,
        limits: ContainerResourceLimits,
        recovery: RecoveryFiles,
        backup: RecoveryInputs,
        replacementLimits: ContainerResourceLimits,
        replacementConfiguration: ContainerConfiguration?,
        replacementCreated: Bool,
        initImageReference: String?
    ) async -> Bool {
        let id = change.plan.containerID
        do {
            if let current = try await runtime.inspect(id: id) {
                guard let replacementConfiguration,
                      (replacementCreated || current.snapshot.configuration.creationDate != change.state.snapshot.configuration.creationDate),
                      Self.digest(current.snapshot.configuration) == Self.digest(replacementConfiguration),
                      current.snapshot.status == .stopped || current.snapshot.status == .running else { return false }
                if current.snapshot.status == .running {
                    try await runtime.stop(id: id)
                    guard let stopped = try await runtime.inspect(id: id), stopped.snapshot.status == .stopped,
                          Self.digest(stopped.snapshot.configuration) == Self.digest(replacementConfiguration) else { return false }
                }
                try await runtime.delete(id: id)
                guard try await runtime.inspect(id: id) == nil,
                      !FileManager.default.fileExists(atPath: change.state.bundlePath.path) else { return false }
            }
            guard !FileManager.default.fileExists(atPath: change.state.bundlePath.path) else { return false }
            let originalConfiguration = Self.configuration(
                change.state.snapshot.configuration,
                limits: limits,
                creationDate: Self.nextCreationDate(after: change.state.snapshot.configuration.creationDate)
            )
            var rootfsOverride = change.state.rootFilesystem
            rootfsOverride.source = change.state.bundlePath.appendingPathComponent("rootfs.ext4").path
            let options = ContainerCreateOptions(autoRemove: false, rootFsOverride: rootfsOverride)
            guard let initImageReference else { return false }
            try await runtime.create(configuration: originalConfiguration, options: options, kernel: backup.kernel, initImage: initImageReference)
            guard let created = try await runtime.inspect(id: id),
                  created.snapshot.status == .stopped,
                  Self.digest(created.snapshot.configuration) == Self.digest(originalConfiguration),
                  created.bundlePath.standardizedFileURL == change.state.bundlePath.standardizedFileURL else { return false }
            try Self.copyVerified(recovery.rootfs, to: change.state.bundlePath.appendingPathComponent("rootfs.ext4"))
            let runtimeConfiguration = RuntimeConfiguration(
                path: change.state.bundlePath,
                initialFilesystem: backup.initialFilesystem,
                kernel: backup.kernel,
                containerConfiguration: originalConfiguration,
                containerRootFilesystem: nil,
                options: options,
                runtimeData: change.state.runtimeConfiguration.runtimeData
            )
            try await runtime.replaceColdRuntimeConfiguration(runtimeConfiguration)
            if change.plan.wasRunning {
                try await runtime.start(id: id)
            }
            guard let restored = try await runtime.inspect(id: id),
                  restored.snapshot.status == (change.plan.wasRunning ? .running : .stopped),
                  Self.digest(restored.snapshot.configuration) == Self.digest(originalConfiguration) else { return false }
            return true
        } catch {
            return false
        }
    }

    private static func configuration(_ original: ContainerConfiguration, limits: ContainerResourceLimits, creationDate: Date?) -> ContainerConfiguration {
        var configuration = original
        configuration.resources.cpus = limits.cpus
        configuration.resources.memoryInBytes = limits.memoryBytes
        if let creationDate { configuration.creationDate = creationDate }
        return configuration
    }

    private static func valid(_ limits: ContainerResourceLimits, plan: ContainerLimitsPlan) -> Bool {
        limits.cpus >= 1 && limits.cpus <= plan.maximumCPUs
            && limits.memoryBytes >= minimumMemoryBytes
            && limits.memoryBytes <= plan.maximumMemoryBytes
            && limits.memoryBytes.isMultiple(of: mebibyte)
    }

    private static func nextCreationDate(after date: Date) -> Date {
        Date(timeIntervalSince1970: max(Date().timeIntervalSince1970, date.timeIntervalSince1970 + 1))
    }

    private static func matches(_ change: PreparedLimitsChange, fresh: ContainerLimitsRuntimeState) -> Bool {
        fresh.snapshot.id == change.plan.containerID
            && fresh.snapshot.configuration.creationDate == change.state.snapshot.configuration.creationDate
            && digest(fresh.snapshot.configuration) == change.configDigest
            && digest(fresh.runtimeConfiguration.containerConfiguration) == change.configDigest
            && fresh.bundlePath.standardizedFileURL == change.state.bundlePath.standardizedFileURL
            && runtimeFingerprint(fresh) == runtimeFingerprint(change.state)
    }

    private static func runtimeFingerprint(_ state: ContainerLimitsRuntimeState) -> String {
        [
            digest(state.runtimeConfiguration),
            digest(state.rootFilesystem),
            digest(state.initialFilesystem),
            digest(state.kernel),
            digest(state.options),
        ].joined(separator: ":")
    }

    private static func validateConfiguration(_ state: ContainerLimitsRuntimeState, recoveryRoot: URL) throws {
        let config = state.snapshot.configuration
        guard config.id == state.snapshot.id,
              state.snapshot.status == .running || state.snapshot.status == .stopped,
              config.runtimeHandler == "container-runtime-linux",
              !config.readOnly,
              state.options?.autoRemove != true,
              state.runtimeConfiguration.runtimeData == nil,
              digest(state.runtimeConfiguration.containerConfiguration) == digest(config),
              state.kernel.platform.os == .linux else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
        let expectedBundleRootFS = state.bundlePath.appendingPathComponent("rootfs.ext4").standardizedFileURL
        let rootFSPath = URL(fileURLWithPath: state.rootFilesystem.source).standardizedFileURL
        if isNeverStarted(state) {
            guard let imageRootfs = state.runtimeConfiguration.containerRootFilesystem,
                  rootFSPath == URL(fileURLWithPath: imageRootfs.source).standardizedFileURL else {
                throw ContainerLimitsIssue.unsupportedContainer
            }
            guard !isWithin(rootFSPath, root: state.bundlePath),
                  (try? rootFSPath.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw ContainerLimitsIssue.unsupportedContainer
            }
            try validateFilesystem(imageRootfs, root: state.appRoot, mustBeWritable: false)
        } else {
            try validateFilesystem(state.rootFilesystem, root: state.appRoot, mustBeWritable: true)
            guard rootFSPath == expectedBundleRootFS else {
                throw ContainerLimitsIssue.unsupportedContainer
            }
        }
        try validateFilesystem(state.initialFilesystem, root: state.appRoot, mustBeWritable: false, recoveryRoot: recoveryRoot)
        try validateManagedOrRecoveryFile(state.kernel.path, appRoot: state.appRoot, recoveryRoot: recoveryRoot)
        if let override = state.options?.rootFsOverride {
            guard case .block(let format, _, _) = override.type,
                  format == "ext4", override.destination == "/",
                  URL(fileURLWithPath: override.source).standardizedFileURL == state.bundlePath.appendingPathComponent("rootfs.ext4").standardizedFileURL else {
                throw ContainerLimitsIssue.unsupportedContainer
            }
        }
        for mount in config.mounts {
            switch mount.type {
            case .tmpfs:
                throw ContainerLimitsIssue.unsupportedContainer
            case .virtiofs:
                try validateFile(URL(fileURLWithPath: mount.source), root: state.appRoot, allowExternal: true)
            case .block(let format, _, _):
                guard format == "ext4" else { throw ContainerLimitsIssue.unsupportedContainer }
                try validateFile(URL(fileURLWithPath: mount.source), root: state.appRoot, allowExternal: true)
            case .volume(_, let format, _, _):
                guard format == "ext4" else { throw ContainerLimitsIssue.unsupportedContainer }
                try validateFile(URL(fileURLWithPath: mount.source), root: state.appRoot, allowExternal: true)
            @unknown default:
                throw ContainerLimitsIssue.unsupportedContainer
            }
        }
    }

    /// Apple Container 1.5 creates the bundle and cold runtime configuration before bootstrap,
    /// but only bootstrap writes rootfs.json and the writable bundle/rootfs.ext4. Require all of
    /// those signals together so a damaged previously booted container is never treated as empty.
    private static func isNeverStarted(_ state: ContainerLimitsRuntimeState) -> Bool {
        let fm = FileManager.default
        let rootfsMetadata = state.bundlePath.appendingPathComponent("rootfs.json")
        let writableRootfs = state.bundlePath.appendingPathComponent("rootfs.ext4")
        let imageRootfs = state.runtimeConfiguration.containerRootFilesystem
        guard state.snapshot.status == .stopped,
              state.snapshot.startedDate == nil,
              state.options?.rootFsOverride == nil,
              let imageRootfs,
              case .block(let format, _, _) = imageRootfs.type,
              format == "ext4", imageRootfs.destination == "/",
              !hasSymbolicLinkComponent(rootfsMetadata),
              !hasSymbolicLinkComponent(writableRootfs),
              !fm.fileExists(atPath: rootfsMetadata.path),
              !fm.fileExists(atPath: writableRootfs.path) else { return false }
        return true
    }

    private static func validateFilesystem(_ filesystem: Filesystem, root: URL, mustBeWritable: Bool, recoveryRoot: URL? = nil) throws {
        guard case .block(let format, _, _) = filesystem.type,
              format == "ext4",
              !mustBeWritable || !filesystem.options.contains("ro") else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
        let source = URL(fileURLWithPath: filesystem.source)
        let isRecovery = recoveryRoot.map { isWithin(source, root: $0) } ?? false
        try validateFile(source, root: root, allowExternal: isRecovery)
        if recoveryRoot != nil, !isWithin(source, root: root), !isRecovery {
            throw ContainerLimitsIssue.unsupportedContainer
        }
    }

    private static func validateFile(_ url: URL, root: URL, allowExternal: Bool = false) throws {
        guard url.isFileURL else { throw ContainerLimitsIssue.unsupportedContainer }
        // Foundation standardization can rewrite /private/tmp to the /tmp symlink.
        // Inspect the supplied components before any alias rewriting.
        let path = url
        guard allowExternal || isWithin(path, root: root) else { throw ContainerLimitsIssue.unsupportedContainer }
        guard !hasSymbolicLinkComponent(path),
              let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
              values.isRegularFile == true || values.isDirectory == true else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
    }

    private static func validateManagedOrRecoveryFile(_ url: URL, appRoot: URL, recoveryRoot: URL) throws {
        let standardized = url
        guard isWithin(standardized, root: appRoot) || isWithin(standardized, root: recoveryRoot),
              !hasSymbolicLinkComponent(standardized),
              let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func hasSymbolicLinkComponent(_ url: URL) -> Bool {
        var cursor = url
        while cursor.path != "/" {
            if isSymbolicLink(cursor) { return true }
            cursor.deleteLastPathComponent()
        }
        return false
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path == root.standardizedFileURL.path || url.standardizedFileURL.path.hasPrefix(rootPath)
    }

    private static func digest<T: Encodable>(_ value: T?) -> String {
        guard let value else { return "missing" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func createRecoverySession(root: URL) throws -> URL {
        let fm = FileManager.default
        guard root.isFileURL, !hasSymbolicLinkComponent(root) else { throw ContainerLimitsIssue.backupFailed }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !hasSymbolicLinkComponent(root) else { throw ContainerLimitsIssue.backupFailed }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard !hasSymbolicLinkComponent(directory) else { throw ContainerLimitsIssue.backupFailed }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try syncDirectory(root)
        return directory
    }

    private static func writeVerifiedBackup(
        stoppedState: ContainerLimitsRuntimeState,
        files: RecoveryFiles,
        includeRootFilesystem: Bool = true
    ) throws -> RecoveryInputs {
        let rootfsSource = URL(fileURLWithPath: stoppedState.rootFilesystem.source)
        let initSource = URL(fileURLWithPath: stoppedState.initialFilesystem.source)
        let kernelSource = stoppedState.kernel.path
        if includeRootFilesystem { try copyVerified(rootfsSource, to: files.rootfs) }
        try copyVerified(initSource, to: files.initfs)
        try copyVerified(kernelSource, to: files.kernel)
        var backupKernel = stoppedState.kernel
        backupKernel.path = files.kernel
        var backupInitialFilesystem = stoppedState.initialFilesystem
        backupInitialFilesystem.source = files.initfs.path
        let manifest = RecoveryManifest(
            containerID: stoppedState.snapshot.id,
            createdAt: stoppedState.snapshot.configuration.creationDate,
            configuration: stoppedState.snapshot.configuration,
            kernel: backupKernel,
            initialFilesystem: backupInitialFilesystem,
            options: stoppedState.options,
            rootfsFingerprint: includeRootFilesystem ? try fileDigest(files.rootfs) : nil,
            initfsFingerprint: try fileDigest(files.initfs),
            kernelFingerprint: try fileDigest(files.kernel)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard FileManager.default.createFile(atPath: files.metadata.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ContainerLimitsIssue.backupFailed
        }
        let metadataHandle = try FileHandle(forWritingTo: files.metadata)
        try metadataHandle.write(contentsOf: data)
        try metadataHandle.synchronize()
        try metadataHandle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.metadata.path)
        try syncFile(files.metadata)
        try syncDirectory(files.directory)
        return RecoveryInputs(
            kernel: backupKernel,
            initialFilesystem: backupInitialFilesystem,
            rootfsFingerprint: manifest.rootfsFingerprint,
            initfsFingerprint: manifest.initfsFingerprint,
            kernelFingerprint: manifest.kernelFingerprint
        )
    }

    private static func copyVerified(_ source: URL, to destination: URL) throws {
        guard !isSymbolicLink(source),
              let values = try? source.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { throw ContainerLimitsIssue.backupFailed }
        // Require a copy-on-write clone so sparse disk holes never expand into a full disk copy.
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw ContainerLimitsIssue.backupFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try syncFile(destination)
        guard try fileDigest(source) == fileDigest(destination) else { throw ContainerLimitsIssue.backupFailed }
    }

    static func fileDigest(_ url: URL) throws -> String {
        try ContainerDiskFingerprint.digest(of: url)
    }

    private static func syncFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw ContainerLimitsIssue.backupFailed }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw ContainerLimitsIssue.backupFailed }
    }

    private static var minimumMemoryBytes: UInt64 { 200 * mebibyte }
    private static var mebibyte: UInt64 { 1_048_576 }

    private static func defaultRecoveryDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("ContainerDesk/LimitsRecovery", isDirectory: true)
    }
}

private struct PreparedLimitsChange: Sendable {
    let plan: ContainerLimitsPlan
    let state: ContainerLimitsRuntimeState
    let configDigest: String
}

private struct RecoveryFiles: Sendable {
    let directory: URL
    var rootfs: URL { directory.appendingPathComponent("rootfs.ext4") }
    var initfs: URL { directory.appendingPathComponent("initfs.ext4") }
    var kernel: URL { directory.appendingPathComponent("kernel.bin") }
    var metadata: URL { directory.appendingPathComponent("recovery.json") }
}

private struct RecoveryManifest: Codable, Sendable {
    let containerID: String
    let createdAt: Date
    let configuration: ContainerConfiguration
    let kernel: Kernel
    let initialFilesystem: Filesystem
    let options: ContainerCreateOptions?
    let rootfsFingerprint: String?
    let initfsFingerprint: String
    let kernelFingerprint: String
}

struct ContainerLimitsRuntimeState: Sendable {
    let snapshot: ContainerSnapshot
    let runtimeConfiguration: RuntimeConfiguration
    let appRoot: URL
    let bundlePath: URL
    let kernel: Kernel
    let initialFilesystem: Filesystem
    let rootFilesystem: Filesystem
    let options: ContainerCreateOptions?
}

private struct RecoveryInputs: Sendable {
    let kernel: Kernel
    let initialFilesystem: Filesystem
    let rootfsFingerprint: String?
    let initfsFingerprint: String
    let kernelFingerprint: String
}

protocol ContainerLimitsRuntime: Sendable {
    func inspect(id: String) async throws -> ContainerLimitsRuntimeState?
    func stop(id: String) async throws
    func delete(id: String) async throws
    func preflightCreate(platform: ContainerizationOCI.Platform) async throws -> String
    func create(configuration: ContainerConfiguration, options: ContainerCreateOptions, kernel: Kernel, initImage: String) async throws
    func replaceColdRuntimeConfiguration(_ configuration: RuntimeConfiguration) async throws
    func start(id: String) async throws
}

private struct AppleContainerLimitsRuntime: ContainerLimitsRuntime {
    private let cli: any ContainerClient
    private let api = ContainerAPIClient.ContainerClient()

    init(cli: any ContainerClient) { self.cli = cli }

    func inspect(id: String) async throws -> ContainerLimitsRuntimeState? {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        guard health.apiServerVersion == "1.5.0",
              let processClient = cli as? ProcessContainerClient,
              processClient.resolver.overridePath == nil,
              try await cliVersion() == "1.5.0" else {
            throw ContainerLimitsIssue.unsupportedCLI
        }
        let snapshots = try await api.list(filters: ContainerListFilters(ids: [id]))
        guard let snapshot = snapshots.first else { return nil }
        let root = health.appRoot.standardizedFileURL
        let bundlePath = root.appendingPathComponent("containers", isDirectory: true).appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard Self.isWithin(bundlePath, root: root.appendingPathComponent("containers", isDirectory: true)),
              !Self.hasSymbolicLinkComponent(root), !Self.hasSymbolicLinkComponent(bundlePath) else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
        let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)
        guard let storedConfig = runtimeConfig.containerConfiguration else { throw ContainerLimitsIssue.unsupportedContainer }
        let bundle = ContainerResource.Bundle(path: bundlePath)
        let configURL = bundlePath.appendingPathComponent("config.json")
        let rootfsURL = bundlePath.appendingPathComponent("rootfs.json")
        let kernelURL = bundlePath.appendingPathComponent("kernel.json")
        let initfsURL = bundlePath.appendingPathComponent("initfs.ext4")
        let config = FileManager.default.fileExists(atPath: configURL.path) ? try bundle.configuration : storedConfig
        guard Self.digest(config) == Self.digest(snapshot.configuration),
              Self.digest(storedConfig) == Self.digest(snapshot.configuration) else {
            throw ContainerLimitsIssue.unsupportedContainer
        }
        let rootFilesystem = FileManager.default.fileExists(atPath: rootfsURL.path)
            ? try bundle.containerRootfs
            : runtimeConfig.options?.rootFsOverride ?? runtimeConfig.containerRootFilesystem ?? Filesystem()
        let kernelExists = FileManager.default.fileExists(atPath: kernelURL.path)
        let initfsExists = FileManager.default.fileExists(atPath: initfsURL.path)
        let kernel = kernelExists ? try bundle.kernel : runtimeConfig.kernel
        let initialFilesystem = initfsExists ? bundle.initialFilesystem : runtimeConfig.initialFilesystem
        let options: ContainerCreateOptions?
        let optionsURL = bundlePath.appendingPathComponent("options.json")
        if FileManager.default.fileExists(atPath: optionsURL.path) {
            options = try bundle.load(filename: "options.json")
        } else {
            options = runtimeConfig.options
        }
        return ContainerLimitsRuntimeState(
            snapshot: snapshot,
            runtimeConfiguration: runtimeConfig,
            appRoot: root,
            bundlePath: bundlePath,
            kernel: kernel,
            initialFilesystem: initialFilesystem,
            rootFilesystem: rootFilesystem,
            options: options
        )
    }

    func stop(id: String) async throws { try await api.stop(id: id) }
    func delete(id: String) async throws { try await api.delete(id: id, force: false) }

    func preflightCreate(platform: ContainerizationOCI.Platform) async throws -> String {
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        guard health.apiServerVersion == "1.5.0" else { throw ContainerLimitsIssue.unsupportedCLI }
        let appRoot = health.appRoot.path(percentEncoded: false)
        let installRoot = health.installRoot.path(percentEncoded: false)
        let systemConfig = try await ConfigurationLoader.load(configurationFiles: [
            ConfigurationLoader.configurationFile(in: .init(appRoot), of: .appRoot),
            ConfigurationLoader.configurationFile(in: .init(installRoot), of: .installRoot),
        ])
        let initImage = try await ClientImage.get(reference: systemConfig.vminit.image, containerSystemConfig: systemConfig)
        // This is a local lookup only. Require the configured default image and target platform
        // to be present before create's unconditional fetch.
        _ = try await initImage.config(for: platform)
        return systemConfig.vminit.image
    }

    func create(configuration: ContainerConfiguration, options: ContainerCreateOptions, kernel: Kernel, initImage: String) async throws {
        try await api.create(configuration: configuration, options: options, kernel: kernel, initImage: initImage)
    }

    func replaceColdRuntimeConfiguration(_ configuration: RuntimeConfiguration) async throws {
        let path = configuration.runtimeConfigurationPath
        let parent = path.deletingLastPathComponent()
        guard !Self.hasSymbolicLinkComponent(path), !Self.hasSymbolicLinkComponent(parent) else { throw ContainerLimitsIssue.replacementFailed }
        let temporary = parent.appendingPathComponent("runtime-configuration-\(UUID().uuidString).tmp")
        guard let expectedConfig = configuration.containerConfiguration else {
            throw ContainerLimitsIssue.replacementFailed
        }
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        guard health.apiServerVersion == "1.5.0",
              configuration.path.standardizedFileURL == health.appRoot.appendingPathComponent("containers", isDirectory: true)
                .appendingPathComponent(expectedConfig.id, isDirectory: true).standardizedFileURL else {
            throw ContainerLimitsIssue.staleReview
        }
        let snapshots = try await api.list(filters: ContainerListFilters(ids: [expectedConfig.id]))
        guard let current = snapshots.first, current.status == .stopped,
              Self.digest(current.configuration) == Self.digest(expectedConfig),
              current.configuration.id == expectedConfig.id else {
            throw ContainerLimitsIssue.staleReview
        }
        let existing = try RuntimeConfiguration.readRuntimeConfiguration(from: configuration.path)
        guard Self.digest(existing.containerConfiguration) == Self.digest(expectedConfig) else {
            throw ContainerLimitsIssue.staleReview
        }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ContainerLimitsIssue.replacementFailed
        }
        do {
            let data = try JSONEncoder().encode(configuration)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: path.path) {
                _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: path)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try Self.syncDirectory(parent)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func start(id: String) async throws {
        var dynamicEnv: [String: String] = [:]
        if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
        }
        let process = try await api.bootstrap(id: id, stdio: [], dynamicEnv: dynamicEnv)
        try await process.start()
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw ContainerLimitsIssue.replacementFailed }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw ContainerLimitsIssue.replacementFailed }
    }

    private func cliVersion() async throws -> String? {
        let result = try await cli.run(CommandRequest(arguments: ["system", "version", "--format", "json"], captureLimit: 128_000, suppressOutputEvents: true, timeout: .seconds(10)))
        guard result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first(where: { ($0["appName"] as? String)?.localizedCaseInsensitiveContains("container") == true }),
              let version = row["version"] as? String else { return nil }
        return version
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func hasSymbolicLinkComponent(_ url: URL) -> Bool {
        var cursor = url.standardizedFileURL
        while cursor.path != "/" {
            if isSymbolicLink(cursor) { return true }
            cursor.deleteLastPathComponent()
        }
        return false
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let root = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(root)
    }
}
