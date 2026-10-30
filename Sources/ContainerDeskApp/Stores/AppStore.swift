import ContainerDeskCore
import Foundation
import Observation

@MainActor
@Observable
public final class AppStore {
    let cleanupStore = CleanupStore()
    let environmentProfiles: EnvironmentProfilesStore
    let managedStacks: ManagedStacksStore
    public private(set) var limitsOperationContainerID: String?
    public private(set) var operations: [OperationRecord] = []
    public private(set) var snapshots: [ContainerSection: ResourceSnapshot] = [:]
    public private(set) var resourceReadBackends: [ContainerSection: ResourceReadBackend] = [:]
    public private(set) var resourceReadFallbackReasons: [ContainerSection: String] = [:]
    public private(set) var containerMetrics: [String: ContainerMetric] = [:]
    public private(set) var containerMetricsError: String?
    public private(set) var containerMetricsUpdatedAt: Date?
    public private(set) var containerMetricsBackend: ResourceReadBackend?
    public private(set) var containerMetricsFallbackReason: String?
    public private(set) var statsTarget: String?
    public private(set) var statsError: String?
    public private(set) var selectedContainerMetric: ContainerMetric?
    public private(set) var systemVersionOutput: String?
    public private(set) var systemVersionError: String?
    public private(set) var runtimeStatusOutput: String?
    public private(set) var runtimeStatusError: String?
    public var runtimeVersionLabel: String? {
        guard let systemVersionOutput,
              let data = systemVersionOutput.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let entry = entries.first(where: { ($0["appName"] as? String)?.localizedCaseInsensitiveContains("container") == true }) ?? entries.first,
              let version = entry["version"] as? String, !version.isEmpty else { return nil }
        return "Apple container \(version)"
    }
    public var runtimeStatusSummary: RuntimeStatusSummary? {
        guard runtimeStatusError == nil, let runtimeStatusOutput else { return nil }
        return RuntimeStatusDecoder.decode(runtimeStatusOutput)
    }
    public var runtimeIsConnected: Bool { runtimeStatusSummary?.state == .running }
    public var runtimeConnectionLabel: String {
        if runtimeStatusError != nil { return "Runtime unavailable" }
        guard let summary = runtimeStatusSummary else { return "Checking runtime" }
        return switch summary.state {
        case .running: "Runtime connected"
        case .stopped: "Runtime stopped"
        case .unknown: "Runtime status unknown"
        }
    }
    public var runtimeStateLabel: String {
        if runtimeStatusError != nil { return "Unavailable" }
        guard let summary = runtimeStatusSummary else { return "Checking…" }
        return switch summary.state {
        case .running: "Running"
        case .stopped: "Stopped"
        case .unknown: summary.rawState?.capitalized ?? "Unknown"
        }
    }
    public private(set) var cliCapabilities: [ContainerSection: CLIFeatureAvailability] = [:]
    public var cliPath: String? {
        didSet {
            defaults.set(cliPath, forKey: Self.cliPathKey)
            if let cliPath, cliPath.isEmpty { self.cliPath = nil; return }
            client = ProcessContainerClient(resolver: ExecutableResolver(overridePath: cliPath))
            resourceReader = ContainerResourceReader(cli: client, nativeAllowed: cliPath == nil)
            clientEpoch += 1
            managedStacks.setRuntime(cliPath: cliPath)
            cleanupStore.invalidate()
            for section in listSections { refreshGenerations[section, default: 0] += 1 }
            refreshingSections.removeAll()
            lastResourceRefreshAt.removeAll()
            for section in ContainerSection.allCases {
                cliCapabilities[section] = .unknown
                snapshots[section] = ResourceSnapshot()
            }
            resourceReadBackends.removeAll()
            resourceReadFallbackReasons.removeAll()
            systemVersionOutput = nil
            systemVersionError = nil
            runtimeStatusOutput = nil
            runtimeStatusError = nil
            lastCapabilitiesRefresh = nil
            healthPollingGeneration += 1
            healthTask?.cancel()
            healthTask = nil
            capabilitiesPollingGeneration += 1
            capabilitiesTask?.cancel()
            capabilitiesTask = nil
            statsError = nil
            selectedContainerMetric = nil
            previousStatsBackend = nil
            containerMetricsGeneration += 1
            containerMetricsTask?.cancel()
            containerMetricsTask = nil
            containerMetrics = [:]
            containerMetricsError = nil
            containerMetricsUpdatedAt = nil
            containerMetricsBackend = nil
            containerMetricsFallbackReason = nil
            containerMetricsShouldUseCLICadence = false
            previousCPUUsage.removeAll(keepingCapacity: true)
            cancelVisibleResourceTasks()
            if !activeWindowIDs.isEmpty {
                startCapabilitiesPollingIfNeeded()
                startHealthPollingIfNeeded()
                updateVisibleResourcePolling()
                updateContainerMetricsPolling()
            }
        }
    }

    public private(set) var client: any ContainerClient

    @ObservationIgnored private var resourceReader: ContainerResourceReader?
    @ObservationIgnored private var limitsService: ContainerLimitsService?
    @ObservationIgnored private var limitsPlanEpochs: [UUID: Int] = [:]
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var capabilitiesTask: Task<Void, Never>?
    @ObservationIgnored private var containerMetricsTask: Task<Void, Never>?
    @ObservationIgnored private var resourcePollingTasks: [ContainerSection: Task<Void, Never>] = [:]
    @ObservationIgnored private var resourcePollingTokens: [ContainerSection: UUID] = [:]
    @ObservationIgnored private var refreshingSections = Set<ContainerSection>()
    @ObservationIgnored private var lastResourceRefreshAt: [ContainerSection: Date] = [:]
    @ObservationIgnored private var refreshGenerations: [ContainerSection: Int] = [:]
    @ObservationIgnored private var clientEpoch = 0
    @ObservationIgnored private var healthPollingGeneration = 0
    @ObservationIgnored private var capabilitiesPollingGeneration = 0
    @ObservationIgnored private var activeWindowIDs = Set<String>()
    @ObservationIgnored private var visibleSectionsByWindow: [String: ContainerSection] = [:]
    @ObservationIgnored private var statsTargetsByWindow: [String: String] = [:]
    @ObservationIgnored private var statsTargetWindowOrder: [String] = []
    @ObservationIgnored private var containerMetricsGeneration = 0
    @ObservationIgnored private var previousCPUUsage: [String: (usageUsec: Int64, sampledAtUptimeNanoseconds: UInt64)] = [:]
    @ObservationIgnored private var previousStatsBackend: ResourceReadBackend?
    @ObservationIgnored private var containerMetricsShouldUseCLICadence = false
    @ObservationIgnored private var operationCancellers: [UUID: @Sendable () -> Void] = [:]
    @ObservationIgnored private var retryRequests: [UUID: CommandRequest] = [:]
    @ObservationIgnored private var lastCapabilitiesRefresh: Date?
    private let defaults: UserDefaults
    /// Visible resources poll every three seconds; this limits list reads to roughly every twelve seconds.
    private let resourceRefreshFreshnessInterval: TimeInterval = 12
    private static let cliPathKey = "containerDesk.cliPath"
    private static let legacyStatsWindowID = "__containerDesk_legacy_stats_target__"
    private let listSections: [ContainerSection] = [.containers, .images, .volumes, .networks, .registries, .machines]

    public init(client: (any ContainerClient)? = nil, defaults: UserDefaults = .standard, stackRepository: ManagedStackRepository = .init()) {
        self.environmentProfiles = EnvironmentProfilesStore()
        self.defaults = defaults
        let savedPath = defaults.string(forKey: Self.cliPathKey)
        self.managedStacks = ManagedStacksStore(repository: stackRepository, cliPath: savedPath)
        self.cliPath = savedPath
        let initialClient = client ?? ProcessContainerClient(resolver: ExecutableResolver(overridePath: savedPath))
        self.client = initialClient
        self.resourceReader = ContainerResourceReader(cli: initialClient, nativeAllowed: savedPath == nil)
        for section in ContainerSection.allCases { snapshots[section] = ResourceSnapshot() }
        for section in ContainerSection.allCases { cliCapabilities[section] = .unknown }
    }

    /// Runs an operation and records metadata only. Process output is returned to the caller, never retained in history.
    @discardableResult
    public func execute(_ request: CommandRequest, title: String) async throws -> CommandResult {
        try await execute(request, title: title, using: client)
    }

    /// Retains full recreation inputs inside Core; the sheet receives only non-secret review fields.
    public func prepareContainerLimits(id: String) async throws -> ContainerLimitsPlan {
        guard cliPath == nil, limitsOperationContainerID == nil else {
            throw ContainerLimitsIssue.unsupportedCLI
        }
        let epoch = clientEpoch
        let service: ContainerLimitsService
        if let limitsService { service = limitsService }
        else {
            service = ContainerLimitsService(client: client)
            limitsService = service
        }
        let plan = try await service.prepare(id: id)
        guard !Task.isCancelled, cliPath == nil, clientEpoch == epoch else {
            await service.discard(planID: plan.id)
            throw ContainerLimitsIssue.staleReview
        }
        limitsPlanEpochs[plan.id] = epoch
        return plan
    }

    public func discardContainerLimitsPlan(id: UUID) async {
        limitsPlanEpochs[id] = nil
        await limitsService?.discard(planID: id)
    }

    /// Recreation is one non-retryable, non-cancellable transaction; Core owns its recovery path.
    public func applyContainerLimits(
        _ plan: ContainerLimitsPlan,
        limits: ContainerResourceLimits,
        onProgress: @escaping @Sendable (ContainerLimitsProgress) async -> Void
    ) async -> ContainerLimitsApplyResult {
        guard cliPath == nil, let service = limitsService,
              limitsPlanEpochs.removeValue(forKey: plan.id) == clientEpoch,
              limitsOperationContainerID == nil else {
            return .unchanged(reason: .staleReview)
        }
        limitsOperationContainerID = plan.containerID
        defer { limitsOperationContainerID = nil }
        let description = "Recreate \(plan.containerID) · CPU \(plan.currentLimits.cpus) → \(limits.cpus) · memory \(plan.currentLimits.memoryBytes / 1_048_576) → \(limits.memoryBytes / 1_048_576) MiB"
        var record = OperationRecord(title: "Edit Limits: \(plan.containerID)", commandPreview: description, canRetry: false, canCancel: false)
        operations.insert(record, at: 0)
        trimHistory()
        let result = await service.apply(plan, limits: limits, onProgress: onProgress)
        record.finishedAt = .now
        switch result {
        case .updated:
            record.state = .succeeded
        case .unchanged(let reason), .rolledBack(_, let reason), .recoveryNeeded(_, let reason):
            record.state = .failed
            record.error = reason.localizedDescription
        }
        updateOperation(record)
        previousCPUUsage[plan.containerID] = nil
        containerMetrics[plan.containerID] = nil
        await refresh(.containers, force: true)
        return result
    }

    /// Binds a reviewed operation to the client that produced its inventory.
    @discardableResult
    public func execute(_ request: CommandRequest, title: String, using requestClient: any ContainerClient, allowRetry: Bool = true, allowCancellation: Bool = true) async throws -> CommandResult {
        let canRetry = allowRetry && request.isSafeToRetry
        var record = OperationRecord(title: title, commandPreview: request.preview, canRetry: canRetry, canCancel: allowCancellation)
        operations.insert(record, at: 0)
        if canRetry { retryRequests[record.id] = request }
        trimHistory()
        do {
            let task = Task { try await requestClient.run(request) }
            if allowCancellation { operationCancellers[record.id] = { task.cancel() } }
            let result = try await task.value
            operationCancellers[record.id] = nil
            let wasCancelled = operations.first(where: { $0.id == record.id })?.state == .cancelled
            record.finishedAt = .now
            record.exitCode = result.exitCode
            if wasCancelled {
                record.state = .cancelled
                record.error = "Cancelled by user."
            } else {
                record.state = result.succeeded ? .succeeded : .failed
                if !result.succeeded { record.error = "Command failed with exit code \(result.exitCode)." }
            }
            updateOperation(record)
            guard result.succeeded else { throw CommandFailure(result: result, request: request) }
            retryRequests[record.id] = nil
            return result
        } catch {
            operationCancellers[record.id] = nil
            let wasCancelled = operations.first(where: { $0.id == record.id })?.state == .cancelled
            if record.state == .running && !wasCancelled {
                record.finishedAt = .now
                record.state = .failed
                record.error = error is CommandFailure ? "Command failed with exit code \(record.exitCode ?? -1)." : "Could not start or complete the command."
                updateOperation(record)
                if !canRetry { retryRequests[record.id] = nil }
            }
            if wasCancelled { retryRequests[record.id] = nil }
            trimHistory()
            throw error
        }
    }

    /// Starts a streamed operation while retaining only activity metadata and progress text transiently at the caller.
    public func stream(_ request: CommandRequest, title: String) -> AsyncThrowingStream<CommandEvent, Error> {
        streamWithID(request, title: title).events
    }

    public func streamWithID(_ request: CommandRequest, title: String) -> (operationID: UUID, events: AsyncThrowingStream<CommandEvent, Error>) {
        let requestClient = client
        let record = OperationRecord(title: title, commandPreview: request.preview, canRetry: request.isSafeToRetry)
        operations.insert(record, at: 0)
        if request.isSafeToRetry { retryRequests[record.id] = request }
        trimHistory()
        let events = AsyncThrowingStream<CommandEvent, Error>(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    var relayOverflowed = false
                    var sawCompletion = false
                    for try await event in requestClient.stream(request) {
                        if case .completed(let result) = event {
                            sawCompletion = true
                            var final = operations.first(where: { $0.id == record.id }) ?? record
                            final.finishedAt = .now
                            final.exitCode = result.exitCode
                            if final.state == .cancelled {
                                final.error = "Cancelled by user."
                            } else {
                                final.state = result.succeeded ? .succeeded : .failed
                                if !result.succeeded { final.error = "Command failed with exit code \(result.exitCode)." }
                            }
                            if result.succeeded || final.state == .cancelled || !request.isSafeToRetry { retryRequests[record.id] = nil }
                            updateOperation(final)
                            operationCancellers[record.id] = nil
                            trimHistory()
                        }
                        if case .dropped = continuation.yield(event) {
                            relayOverflowed = true
                            withUnsafeCurrentTask { $0?.cancel() }
                            var failed = operations.first(where: { $0.id == record.id }) ?? record
                            failed.finishedAt = .now
                            failed.state = .failed
                            failed.canRetry = false
                            failed.error = ContainerClientError.outputBufferExceeded.localizedDescription
                            updateOperation(failed)
                            operationCancellers[record.id] = nil
                            retryRequests[record.id] = nil
                            trimHistory()
                            continuation.finish(throwing: ContainerClientError.outputBufferExceeded)
                            break
                        }
                    }
                    if !relayOverflowed {
                        if !sawCompletion,
                           var unfinished = operations.first(where: { $0.id == record.id }),
                           unfinished.state == .running {
                            unfinished.finishedAt = .now
                            unfinished.state = .failed
                            unfinished.error = "Command stream ended before completion."
                            updateOperation(unfinished)
                        }
                        operationCancellers[record.id] = nil
                        trimHistory()
                        continuation.finish()
                    }
                } catch {
                    let wasCancelled = operations.first(where: { $0.id == record.id })?.state == .cancelled
                    if !wasCancelled {
                        var failed = operations.first(where: { $0.id == record.id }) ?? record
                        failed.finishedAt = .now; failed.state = .failed; failed.error = request.redact(error.localizedDescription)
                        updateOperation(failed)
                    }
                    operationCancellers[record.id] = nil
                    if wasCancelled || !request.isSafeToRetry { retryRequests[record.id] = nil }
                    trimHistory()
                    continuation.finish(throwing: error)
                }
            }
            operationCancellers[record.id] = { task.cancel() }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return (record.id, events)
    }

    public func cancelOperation(_ id: UUID) {
        guard operations.first(where: { $0.id == id })?.canCancel == true else { return }
        operationCancellers[id]?()
        guard var record = operations.first(where: { $0.id == id }), record.state == .running else { return }
        record.state = .cancelled
        record.finishedAt = .now
        record.error = "Cancelled by user."
        updateOperation(record)
    }

    @discardableResult
    public func retryOperation(_ id: UUID) async throws -> CommandResult {
        guard let request = retryRequests[id], request.isSafeToRetry,
              let original = operations.first(where: { $0.id == id }), original.state == .failed else {
            throw DNSAdminError.command("This operation cannot be safely retried.")
        }
        return try await execute(request, title: "Retry: \(original.title)")
    }

    /// A read-only refresh; sensitive JSON stays transient and is reduced to curated identifiers and labels.
    public func refresh(_ section: ContainerSection, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        guard listArguments(for: section) != nil else { return }
        // A fresh snapshot is already suitable for navigation and the next visible poll.
        // Forced/manual callers still bypass this age check.
        if !force,
           let lastRefresh = lastResourceRefreshAt[section],
           snapshots[section]?.state == .loaded,
           Date.now.timeIntervalSince(lastRefresh) < resourceRefreshFreshnessInterval {
            return
        }
        // A read already in progress satisfies concurrent navigation/poll/manual callers.
        if refreshingSections.contains(section) { return }
        refreshingSections.insert(section)
        let generation = (refreshGenerations[section] ?? 0) + 1
        refreshGenerations[section] = generation
        let epoch = clientEpoch
        let reader = resourceReader ?? ContainerResourceReader(cli: client, nativeAllowed: cliPath == nil)
        defer {
            if refreshGenerations[section] == generation { refreshingSections.remove(section) }
        }
        let initialSnapshot = snapshots[section] ?? ResourceSnapshot()
        if initialSnapshot.fetchedAt == nil, initialSnapshot.state != .loading {
            var loadingSnapshot = initialSnapshot
            loadingSnapshot.state = .loading
            snapshots[section] = loadingSnapshot
        }
        do {
            let result = try await reader.list(section)
            guard !Task.isCancelled, clientEpoch == epoch, refreshGenerations[section] == generation else { return }
            let refreshedAt = Date.now
            lastResourceRefreshAt[section] = refreshedAt
            let currentSnapshot = snapshots[section] ?? ResourceSnapshot()
            // Keep the observation graph quiet when a successful poll returns identical data.
            // The private refresh clock still advances, so later polls remain cadence based.
            if currentSnapshot.items != result.value || currentSnapshot.state != .loaded {
                snapshots[section] = ResourceSnapshot(items: result.value, fetchedAt: refreshedAt, state: .loaded)
            }
            if resourceReadBackends[section] != result.backend {
                resourceReadBackends[section] = result.backend
            }
            if resourceReadFallbackReasons[section] != result.fallbackReason {
                resourceReadFallbackReasons[section] = result.fallbackReason
            }
            if section == .containers { updateContainerMetricsPolling() }
        } catch {
            if !Task.isCancelled, clientEpoch == epoch, refreshGenerations[section] == generation {
                lastResourceRefreshAt[section] = nil
                resourceReadFallbackReasons[section] = nil
                setFailure(for: section, message: error.localizedDescription)
            }
        }
    }

    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for section in listSections { group.addTask { await self.refresh(section, force: true) } }
        }
        await refreshSystemVersion()
        if lastCapabilitiesRefresh.map({ Date.now.timeIntervalSince($0) >= 60 }) ?? true { await refreshCapabilities() }
    }

    /// Reads a curated, redacted container inspection through the native API when verified, with CLI fallback.
    public func inspectContainer(id: String) async throws -> ResourceReadResult<SanitizedContainerInspection> {
        let epoch = clientEpoch
        let reader = resourceReader ?? ContainerResourceReader(cli: client, nativeAllowed: cliPath == nil)
        let result = try await reader.inspectContainer(id: id)
        try Task.checkCancellation()
        guard clientEpoch == epoch else { throw CancellationError() }
        return result
    }

    private func updateVisibleResourcePolling() {
        guard pollingTask != nil else { return }
        let selectedSections = activeWindowIDs.compactMap { visibleSectionsByWindow[$0] }
        // A Stacks window consumes the same snapshots as the resource browsers. Keep those
        // existing polling tasks alive; Set deduplicates them when another window shows a source.
        let visibleSections = Set(selectedSections.flatMap { section -> [ContainerSection] in
            if section == .stacks { return [.containers, .images, .volumes, .networks] }
            return listSections.contains(section) ? [section] : []
        })
        for (section, task) in Array(resourcePollingTasks) where !visibleSections.contains(section) {
            task.cancel()
            resourcePollingTasks[section] = nil
            resourcePollingTokens[section] = nil
        }
        for section in visibleSections where resourcePollingTasks[section] == nil {
            let token = UUID()
            resourcePollingTokens[section] = token
            resourcePollingTasks[section] = Task { [weak self] in
                guard let self else { return }
                await refresh(section)
                if resourcePollingTokens[section] == token {
                    resourcePollingTasks[section] = nil
                    resourcePollingTokens[section] = nil
                }
            }
        }
    }

    private func cancelVisibleResourceTasks() {
        for task in resourcePollingTasks.values { task.cancel() }
        resourcePollingTasks.removeAll(keepingCapacity: false)
        resourcePollingTokens.removeAll(keepingCapacity: false)
    }

    /// Uses help-only invocations to discover installed command/plugin support without changing runtime state.
    public func refreshCapabilities() async {
        let epoch = clientEpoch
        let requestClient = client
        guard !Task.isCancelled else { return }
        do {
            let root = try await requestClient.run(CommandRequest(arguments: ["--help"], captureLimit: 256_000, suppressOutputEvents: true, timeout: .seconds(15)))
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            guard root.succeeded else {
                for section in ContainerSection.allCases { cliCapabilities[section] = .unavailable("Could not read CLI help.") }
                lastCapabilitiesRefresh = .now
                return
            }
            let help = root.standardOutput.lowercased()
            let groups: [(ContainerSection, String)] = [
                (.containers, "container subcommands:"), (.images, "image subcommands:"),
                (.volumes, "volume subcommands:"), (.machines, "machine subcommands:"),
            ]
            for (section, marker) in groups {
                cliCapabilities[section] = help.contains(marker) ? .available : .unavailable("This CLI version does not list this command group.")
            }
            cliCapabilities[.builds] = help.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("build ") || $0.trimmingCharacters(in: .whitespaces) == "build" } ? .available : .unavailable("The build command is not listed by this CLI.")
            cliCapabilities[.networks] = help.contains("network") ? .available : .unavailable("The network commands are not listed by this CLI.")
            cliCapabilities[.registries] = help.contains("registry") ? .available : .unavailable("The registry commands are not listed by this CLI.")
            cliCapabilities[.system] = help.contains("system") ? .available : .unavailable("The system commands are not listed by this CLI.")
            cliCapabilities[.cleanup] = help.contains("container subcommands:") ? .available : .unavailable("The container commands are not listed by this CLI.")
            await checkPlugin(section: .compose, arguments: ["compose", "--help"], client: requestClient, epoch: epoch)
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            await checkPlugin(section: .kubernetes, arguments: ["k8s", "--help"], client: requestClient, epoch: epoch)
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            cliCapabilities[.activity] = .available
            lastCapabilitiesRefresh = .now
        } catch {
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            for section in ContainerSection.allCases { cliCapabilities[section] = .unavailable(error.localizedDescription) }
            lastCapabilitiesRefresh = .now
        }
    }

    public func capability(for section: ContainerSection) -> CLIFeatureAvailability {
        cliCapabilities[section] ?? .unknown
    }

    private func checkPlugin(section: ContainerSection, arguments: [String], client requestClient: any ContainerClient, epoch: Int) async {
        let subcommand = arguments.first ?? ""
        do {
            let result = try await requestClient.run(CommandRequest(arguments: arguments, captureLimit: 128_000, suppressOutputEvents: true, timeout: .seconds(15)))
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            let includesCommand = CLIPluginHelpDecoder.isAvailable(plugin: subcommand, succeeded: result.succeeded, output: result.standardOutput)
            cliCapabilities[section] = includesCommand ? .available : .unavailable("The CLI command group is not installed or did not return help.")
        } catch { if !Task.isCancelled, clientEpoch == epoch { cliCapabilities[section] = .unavailable(error.localizedDescription) } }
    }

    public func refreshSystemVersion() async {
        let epoch = clientEpoch
        let requestClient = client
        guard !Task.isCancelled else { return }
        do {
            let result = try await requestClient.run(CommandRequest(arguments: ["system", "version", "--format", "json"], suppressOutputEvents: true, timeout: .seconds(20)))
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            guard result.succeeded else {
                systemVersionOutput = nil
                systemVersionError = "CLI command failed with status \(result.exitCode)."
                // Keep checking health independently; a failed version lookup does not
                // prove that the runtime itself is unavailable.
                await refreshRuntimeStatus(using: requestClient, epoch: epoch)
                return
            }
            systemVersionOutput = result.standardOutput
            systemVersionError = nil
        } catch {
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            systemVersionOutput = nil
            systemVersionError = error.localizedDescription
        }
        await refreshRuntimeStatus(using: requestClient, epoch: epoch)
    }

    private func refreshRuntimeStatus(using requestClient: any ContainerClient, epoch: Int) async {
        guard !Task.isCancelled else { return }
        do {
            let result = try await requestClient.run(CommandRequest(arguments: ["system", "status"], suppressOutputEvents: true, timeout: .seconds(20)))
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            guard result.succeeded else {
                runtimeStatusOutput = nil
                runtimeStatusError = "CLI command failed with status \(result.exitCode)."
                return
            }
            runtimeStatusOutput = result.standardOutput
            runtimeStatusError = nil
        } catch {
            guard !Task.isCancelled, clientEpoch == epoch else { return }
            runtimeStatusOutput = nil
            runtimeStatusError = error.localizedDescription
        }
    }

    /// The only elevation path exposed by the app: fixed container DNS create/delete commands.
    public func executePrivilegedDNS(_ action: DNSAdminAction) async throws -> String {
        try action.validate()
        guard let executable = ExecutableResolver(overridePath: cliPath).resolve() else { throw ContainerClientError.executableNotFound }
        let appleScript = #"""
        on run argv
            set shellCommand to quoted form of (item 1 of argv)
            repeat with argIndex from 2 to count of argv
                set shellCommand to shellCommand & " " & quoted form of (item argIndex of argv)
            end repeat
            return do shell script shellCommand with administrator privileges
        end run
        """#
        let commandArguments = ["/usr/bin/env", "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", executable.path] + action.arguments
        var record = OperationRecord(title: action.activityTitle, commandPreview: "container \(action.arguments.joined(separator: " ")) (administrator)", canRetry: false, canCancel: false)
        operations.insert(record, at: 0)
        trimHistory()
        do {
            let output = try await runAdminScript(script: appleScript, arguments: commandArguments)
            record.finishedAt = .now
            record.state = .succeeded
            updateOperation(record)
            return output
        } catch {
            record.finishedAt = .now
            record.state = .failed
            record.error = error.localizedDescription
            updateOperation(record)
            throw error
        }
    }

    public func setWindowActive(_ sceneID: String, active: Bool) {
        if active { activeWindowIDs.insert(sceneID) }
        else { activeWindowIDs.remove(sceneID) }
        if activeWindowIDs.isEmpty { stopPolling() }
        else { startPolling() }
        updateVisibleResourcePolling()
        updateSelectedStatsTarget()
    }

    /// Tracks each window's selected section so table-wide metrics only run while Containers is visible.
    public func setVisibleSection(_ section: ContainerSection?, for sceneID: String) {
        visibleSectionsByWindow[sceneID] = section
        updateVisibleResourcePolling()
        updateSelectedStatsTarget()
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            var iterationStart = ContinuousClock.now
            updateVisibleResourcePolling()
            while !Task.isCancelled {
                await sleepUntilNextPoll(startedAt: iterationStart, interval: .seconds(3))
                guard !Task.isCancelled else { break }
                iterationStart = ContinuousClock.now
                updateVisibleResourcePolling()
            }
        }
        startHealthPollingIfNeeded()
        startCapabilitiesPollingIfNeeded()
        updateContainerMetricsPolling()
    }

    private func startHealthPollingIfNeeded() {
        guard healthTask == nil else { return }
        healthPollingGeneration += 1
        let generation = healthPollingGeneration
        healthTask = Task { [weak self] in
            guard let self else { return }
            await refreshSystemVersion()
            while !Task.isCancelled, generation == healthPollingGeneration {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { break }
                guard !Task.isCancelled, generation == healthPollingGeneration else { break }
                await refreshSystemVersion()
            }
            if generation == healthPollingGeneration { healthTask = nil }
        }
    }

    private func startCapabilitiesPollingIfNeeded() {
        guard capabilitiesTask == nil else { return }
        capabilitiesPollingGeneration += 1
        let generation = capabilitiesPollingGeneration
        capabilitiesTask = Task { [weak self] in
            guard let self else { return }
            if lastCapabilitiesRefresh.map({ Date.now.timeIntervalSince($0) >= 60 }) ?? true { await refreshCapabilities() }
            while !Task.isCancelled, generation == capabilitiesPollingGeneration {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { break }
                guard !Task.isCancelled, generation == capabilitiesPollingGeneration else { break }
                await refreshCapabilities()
            }
            if generation == capabilitiesPollingGeneration { capabilitiesTask = nil }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        cancelVisibleResourceTasks()
        healthTask?.cancel()
        healthTask = nil
        healthPollingGeneration += 1
        capabilitiesTask?.cancel()
        capabilitiesTask = nil
        capabilitiesPollingGeneration += 1
        selectedContainerMetric = nil
        containerMetricsTask?.cancel()
        containerMetricsTask = nil
        containerMetricsGeneration += 1
    }

    public func setStatsTarget(_ id: String?) {
        setStatsTarget(id, forWindow: Self.legacyStatsWindowID)
    }

    public func setStatsTarget(_ id: String?, forWindow windowID: String) {
        if let id {
            statsTargetsByWindow[windowID] = id
            statsTargetWindowOrder.removeAll { $0 == windowID }
            statsTargetWindowOrder.insert(windowID, at: 0)
        } else {
            statsTargetsByWindow[windowID] = nil
            statsTargetWindowOrder.removeAll { $0 == windowID }
        }
        updateSelectedStatsTarget()
    }

    public func clearStatsTarget(_ id: String, forWindow windowID: String) {
        guard statsTargetsByWindow[windowID] == id else { return }
        setStatsTarget(nil, forWindow: windowID)
    }

    private func updateSelectedStatsTarget() {
        let nextWindow = statsTargetWindowOrder.first {
            activeWindowIDs.contains($0) && visibleSectionsByWindow[$0] == .containers
        }
        let nextTarget = nextWindow.flatMap { statsTargetsByWindow[$0] }
        if statsTarget != nextTarget {
            statsTarget = nextTarget
            statsError = nil
            selectedContainerMetric = nextTarget.flatMap { containerMetrics[$0] }
        }
        updateContainerMetricsPolling()
    }

    private var isContainerSectionVisible: Bool {
        activeWindowIDs.contains {
            let section = visibleSectionsByWindow[$0]
            return section == .containers || section == .stacks
        }
    }

    private func updateContainerMetricsPolling() {
        let hasContainerSnapshot = snapshots[.containers]?.fetchedAt != nil
        let shouldPoll = pollingTask != nil && isContainerSectionVisible && hasContainerSnapshot
        guard shouldPoll else {
            containerMetricsTask?.cancel()
            containerMetricsTask = nil
            containerMetricsGeneration += 1
            previousCPUUsage.removeAll(keepingCapacity: true)
            return
        }
        guard containerMetricsTask == nil else { return }
        containerMetricsGeneration += 1
        let generation = containerMetricsGeneration
        containerMetricsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == containerMetricsGeneration {
                let iterationStart = ContinuousClock.now
                await refreshContainerMetrics(generation: generation)
                let activeBackend = containerMetricsBackend ?? resourceReadBackends[.containers]
                let interval: Duration = activeBackend == .nativeAPI && !containerMetricsShouldUseCLICadence ? .seconds(1) : .seconds(3)
                await sleepUntilNextPoll(startedAt: iterationStart, interval: interval)
            }
            if generation == containerMetricsGeneration { containerMetricsTask = nil }
        }
    }

    private func refreshContainerMetrics(generation: Int) async {
        let epoch = clientEpoch
        let reader = resourceReader ?? ContainerResourceReader(cli: client, nativeAllowed: cliPath == nil)
        let runningIDs = (snapshots[.containers]?.items ?? []).compactMap { item -> String? in
            (item.state ?? "").localizedCaseInsensitiveContains("running") ? item.id : nil
        }
        let requestedIDs = Array(Set(runningIDs)).sorted()
        guard !requestedIDs.isEmpty else {
            containerMetrics = [:]
            containerMetricsUpdatedAt = .now
            selectedContainerMetric = nil
            statsError = statsTarget == nil ? nil : "This container is stopped or absent from the latest list."
            return
        }
        do {
            let result = try await reader.stats(ids: requestedIDs)
            guard !Task.isCancelled, generation == containerMetricsGeneration, clientEpoch == epoch else { return }
            if let previousStatsBackend, previousStatsBackend != result.backend {
                previousCPUUsage.removeAll(keepingCapacity: true)
            }
            previousStatsBackend = result.backend
            containerMetricsShouldUseCLICadence = false
            let currentUptime = DispatchTime.now().uptimeNanoseconds
            var metrics: [String: ContainerMetric] = [:]
            var currentCPU: [String: (usageUsec: Int64, sampledAtUptimeNanoseconds: UInt64)] = [:]
            for sample in result.value {
                let sampledAt = sample.sampledAtUptimeNanoseconds ?? currentUptime
                let previous = previousCPUUsage[sample.id]
                let cpuPercent: Double?
                if let previous, sampledAt > previous.sampledAtUptimeNanoseconds {
                    cpuPercent = ContainerCPUUsage.oneCorePercent(
                        previousUsageUsec: previous.usageUsec,
                        currentUsageUsec: sample.cpuUsageUsec,
                        elapsedNanoseconds: sampledAt - previous.sampledAtUptimeNanoseconds
                    )
                } else { cpuPercent = nil }
                metrics[sample.id] = ContainerMetric(cpuPercent: cpuPercent, memoryUsageBytes: sample.memoryUsageBytes)
                currentCPU[sample.id] = (sample.cpuUsageUsec, sampledAt)
            }
            previousCPUUsage = currentCPU
            containerMetrics = metrics
            containerMetricsBackend = result.backend
            containerMetricsFallbackReason = result.fallbackReason
            containerMetricsError = result.failures.values.first
            containerMetricsUpdatedAt = .now
            if let statsTarget {
                selectedContainerMetric = metrics[statsTarget]
                if let failure = result.failures[statsTarget] { statsError = failure }
                else if !runningIDs.contains(statsTarget) { statsError = "This container is stopped or absent from the latest list." }
                else if runningIDs.contains(statsTarget), metrics[statsTarget] == nil { statsError = "No live stats were returned for this container." }
                else { statsError = nil }
            } else {
                selectedContainerMetric = nil
                statsError = nil
            }
            if !result.failures.isEmpty { await refresh(.containers, force: true) }
        } catch {
            if !Task.isCancelled, generation == containerMetricsGeneration, clientEpoch == epoch {
                failContainerMetrics(error.localizedDescription)
                await refresh(.containers, force: true)
            }
        }
    }

    private func failContainerMetrics(_ message: String) {
        containerMetrics = [:]
        containerMetricsError = message
        containerMetricsUpdatedAt = nil
        containerMetricsBackend = nil
        containerMetricsFallbackReason = nil
        selectedContainerMetric = nil
        statsError = statsTarget == nil ? nil : message
        previousCPUUsage.removeAll(keepingCapacity: true)
        previousStatsBackend = nil
        containerMetricsShouldUseCLICadence = true
    }

    private func sleepUntilNextPoll(startedAt: ContinuousClock.Instant, interval: Duration) async {
        let remaining = interval - startedAt.duration(to: .now)
        guard remaining > .zero else { return }
        do { try await Task.sleep(for: remaining) }
        catch { }
    }

    private func listArguments(for section: ContainerSection) -> [String]? {
        switch section {
        case .containers: ["list", "--all", "--format", "json"]
        case .images: ["image", "list", "--format", "json", "--verbose"]
        case .volumes: ["volume", "list", "--format", "json"]
        case .networks: ["network", "list", "--format", "json"]
        case .registries: ["registry", "list", "--format", "json"]
        case .machines: ["machine", "list", "--format", "json"]
        case .stacks, .builds, .compose, .kubernetes, .system, .cleanup, .activity, .mlxModels: nil
        }
    }

    private func setFailure(for section: ContainerSection, message: String) {
        var snapshot = snapshots[section] ?? ResourceSnapshot()
        snapshot.state = .failed(message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Could not load resources.")
        snapshots[section] = snapshot
    }

    private func updateOperation(_ record: OperationRecord) {
        guard let index = operations.firstIndex(where: { $0.id == record.id }) else { return }
        operations[index] = record
        trimHistory()
    }

    private func trimHistory() {
        let activeIDs = Set(operations.compactMap { record in
            record.state == .running || operationCancellers[record.id] != nil ? record.id : nil
        })
        let completedLimit = max(0, 250 - activeIDs.count)
        var completedCount = 0
        operations = operations.filter { record in
            if activeIDs.contains(record.id) { return true }
            guard completedCount < completedLimit else { return false }
            completedCount += 1
            return true
        }

        let retained = Set(operations.map(\.id))
        operationCancellers = operationCancellers.filter { retained.contains($0.key) }
        retryRequests = retryRequests.filter { id, request in
            guard retained.contains(id), request.isSafeToRetry,
                  let record = operations.first(where: { $0.id == id }), record.canRetry else { return false }
            return record.state == .running || record.state == .failed
        }
    }
}

private func runAdminScript(script: String, arguments: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() }
        catch { continuation.resume(throwing: DNSAdminError.launch(error.localizedDescription)); return }
        let group = DispatchGroup()
        let output = BoundedOutput(limit: 64_000)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                guard let data = try? pipe.fileHandleForReading.read(upToCount: 4_096), !data.isEmpty else { break }
                output.append(data)
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); group.leave() }
        group.notify(queue: .global(qos: .utility)) {
            let text = output.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                continuation.resume(throwing: DNSAdminError.command(text.isEmpty ? "The administrator command failed or was cancelled." : text))
                return
            }
            continuation.resume(returning: text)
        }
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    init(limit: Int) { self.limit = limit }
    func append(_ incoming: Data) {
        lock.lock(); defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(incoming.prefix(limit - data.count))
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct CommandFailure: LocalizedError {
    let message: String
    init(result: CommandResult, request: CommandRequest) {
        let raw = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.standardOutput : result.standardError
        let safe = request.sanitizeOutput(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Command failed with exit code \(result.exitCode)."
        message = safe.isEmpty ? fallback : safe + (result.outputTruncated ? "\n(Output truncated.)" : "")
    }
    var errorDescription: String? { message }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
