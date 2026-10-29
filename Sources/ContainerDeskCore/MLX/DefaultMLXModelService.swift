import Foundation

public protocol MLXExecutableProcessFactory: Sendable {
    func launch(executableURL: URL, request: CommandRequest) throws -> ManagedProcessExecution
}

public struct DefaultMLXExecutableProcessFactory: MLXExecutableProcessFactory, Sendable {
    public init() {}
    public func launch(executableURL: URL, request: CommandRequest) throws -> ManagedProcessExecution {
        try ProcessExecutableClient(executableURL: executableURL).launch(request)
    }
}

/// Core implementation for local model inventory, explicit downloads, and app-owned loopback servers.
public actor DefaultMLXModelService: MLXModelService {
    private struct CatalogScan {
        let id: UUID
        let configuration: MLXConfiguration
        let cancellation: MLXCatalogScanCancellation
        let task: Task<[MLXModelRecord], Error>
    }

    private var configuration: MLXConfiguration
    private let environment: [String: String]
    private let capabilityProbe: any MLXCapabilityProbing
    private let processFactory: any MLXExecutableProcessFactory
    private let chatTransport: any MLXChatStreamingTransport
    private let catalogScanner: any MLXModelCatalogScanning
    private var catalogScan: CatalogScan?
    private var cachedCapability: MLXCapability?
    private var capabilityTask: Task<MLXCapability, Never>?
    private var servers: [UUID: ServerEntry] = [:]
    private var downloads: [UUID: ManagedProcessExecution] = [:]
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var downloadRepositoryIDs: [UUID: String] = [:]
    private var downloadingRepositories = Set<String>()
    private var isShuttingDown = false
    private var shutdownOperation: Task<Void, Never>?
    private var nextServerTerminalOrder: UInt64 = 0

    public init(
        configuration: MLXConfiguration = MLXConfiguration(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        capabilityProbe: any MLXCapabilityProbing = MLXToolchainDetector(),
        processFactory: any MLXExecutableProcessFactory = DefaultMLXExecutableProcessFactory(),
        chatTransport: any MLXChatStreamingTransport = MLXOpenAIChatTransport()
    ) {
        self.configuration = configuration
        self.environment = environment
        self.capabilityProbe = capabilityProbe
        self.processFactory = processFactory
        self.chatTransport = chatTransport
        self.catalogScanner = DefaultMLXModelCatalogScanner()
    }

    init(
        configuration: MLXConfiguration = MLXConfiguration(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        capabilityProbe: any MLXCapabilityProbing = MLXToolchainDetector(),
        processFactory: any MLXExecutableProcessFactory = DefaultMLXExecutableProcessFactory(),
        chatTransport: any MLXChatStreamingTransport = MLXOpenAIChatTransport(),
        catalogScanner: any MLXModelCatalogScanning
    ) {
        self.configuration = configuration
        self.environment = environment
        self.capabilityProbe = capabilityProbe
        self.processFactory = processFactory
        self.chatTransport = chatTransport
        self.catalogScanner = catalogScanner
    }

    public func configure(_ configuration: MLXConfiguration) async {
        guard !isShuttingDown else { return }
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        catalogScan?.cancellation.cancel()
        catalogScan?.task.cancel()
        cachedCapability = nil
        capabilityTask?.cancel()
        capabilityTask = nil
    }

    public func capability() async -> MLXCapability {
        guard !isShuttingDown else {
            return MLXCapability(available: false, reason: "The MLX service is shutting down.")
        }
        if let cachedCapability { return cachedCapability }
        if let capabilityTask {
            let result = await capabilityTask.value
            guard !isShuttingDown else {
                return MLXCapability(available: false, reason: "The MLX service is shutting down.")
            }
            return result
        }
        let config = configuration
        let environment = environment
        let probe = capabilityProbe
        let task = Task.detached(priority: .utility) { await probe.detect(configuration: config, environment: environment) }
        capabilityTask = task
        let result = await task.value
        guard !isShuttingDown else {
            return MLXCapability(available: false, reason: "The MLX service is shutting down.")
        }
        if configuration == config {
            cachedCapability = result
            capabilityTask = nil
        }
        return result
    }

    public func listLocalModels() async throws -> [MLXModelRecord] {
        while true {
            try Task.checkCancellation()
            guard !isShuttingDown else { throw MLXError.operationFailed("The MLX service is shutting down.") }
            let requestedConfiguration = configuration

            if let activeScan = catalogScan {
                if activeScan.configuration != requestedConfiguration || activeScan.cancellation.isCancelled {
                    activeScan.cancellation.cancel()
                    activeScan.task.cancel()
                    _ = await activeScan.task.result
                    if catalogScan?.id == activeScan.id { catalogScan = nil }
                    try Task.checkCancellation()
                    continue
                }

                let result = await activeScan.task.result
                if catalogScan?.id == activeScan.id { catalogScan = nil }
                try Task.checkCancellation()
                guard !isShuttingDown else { throw MLXError.operationFailed("The MLX service is shutting down.") }
                guard configuration == requestedConfiguration, !activeScan.cancellation.isCancelled else {
                    throw CancellationError()
                }
                return try result.get()
            }

            let id = UUID()
            let cancellation = MLXCatalogScanCancellation()
            let environment = environment
            let scanner = catalogScanner
            let task = Task.detached(priority: .utility) {
                try scanner.scan(configuration: requestedConfiguration, environment: environment, cancellation: cancellation)
            }
            let scan = CatalogScan(id: id, configuration: requestedConfiguration, cancellation: cancellation, task: task)
            catalogScan = scan

            let result = await task.result
            if catalogScan?.id == id { catalogScan = nil }
            try Task.checkCancellation()
            guard !isShuttingDown else { throw MLXError.operationFailed("The MLX service is shutting down.") }
            guard configuration == requestedConfiguration, !cancellation.isCancelled else {
                throw CancellationError()
            }
            return try result.get()
        }
    }

    public func validateModelDirectory(_ url: URL) async throws -> MLXModelRecord {
        try await MLXModelCatalog(configuration: configuration, environment: environment).validateModelDirectory(url)
    }

    public func forgetImportedModel(at url: URL) async {
        let path = url.standardizedFileURL.path
        configuration.importedModelDirectories.removeAll { $0.standardizedFileURL.path == path }
    }

    public func download(_ request: MLXModelDownloadRequest) async -> AsyncThrowingStream<MLXDownloadEvent, Error> {
        guard !isShuttingDown else {
            return Self.failedDownload(MLXError.operationFailed("The MLX service is shutting down."))
        }
        guard downloadingRepositories.insert(request.repositoryID).inserted else {
            return Self.failedDownload(MLXError.operationFailed("A download for this model is already in progress."))
        }
        let configuration = self.configuration
        let environment = self.environment
        let capability = await capability()
        guard !isShuttingDown else {
            downloadingRepositories.remove(request.repositoryID)
            return Self.failedDownload(MLXError.operationFailed("The MLX service is shutting down."))
        }
        guard !Task.isCancelled else {
            downloadingRepositories.remove(request.repositoryID)
            return Self.failedDownload(MLXError.operationFailed("Download cancelled."))
        }
        guard configuration == self.configuration else {
            downloadingRepositories.remove(request.repositoryID)
            return Self.failedDownload(MLXError.operationFailed("MLX settings changed during the download request."))
        }
        guard capability.available, let python = capability.pythonURL else {
            downloadingRepositories.remove(request.repositoryID)
            return Self.failedDownload(MLXError.toolchainUnavailable(capability.reason ?? "A Python interpreter from the mlx_lm environment is required for downloads."))
        }
        guard let destination = try? MLXModelCatalog.managedPath(for: request.repositoryID, root: configuration.managedModelsDirectory) else {
            downloadingRepositories.remove(request.repositoryID)
            return Self.failedDownload(MLXError.invalidRepositoryID)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let manifest = MLXModelCatalog.managedManifest(at: destination), manifest.repositoryID == request.repositoryID else {
                downloadingRepositories.remove(request.repositoryID)
                return Self.failedDownload(MLXError.operationFailed("The app-managed model destination already exists and is not owned by this download."))
            }
        }
        if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            downloadingRepositories.remove(request.repositoryID)
            return Self.failedDownload(MLXError.invalidModelDirectory)
        }
        guard !Task.isCancelled else {
            downloadingRepositories.remove(request.repositoryID)
            return Self.failedDownload(MLXError.operationFailed("Download cancelled."))
        }

        let catalog = MLXModelCatalog(configuration: configuration, environment: environment)
        let operationID = UUID()
        let (stream, continuation) = AsyncThrowingStream<MLXDownloadEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(operationID: operationID, request: request, python: python, configuration: configuration, catalog: catalog, continuation: continuation)
        }
        downloadTasks[operationID] = task
        downloadRepositoryIDs[operationID] = request.repositoryID
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cancelDownload(id: operationID) }
        }
        return stream
    }

    private func runDownload(
        operationID: UUID,
        request downloadRequest: MLXModelDownloadRequest,
        python: URL,
        configuration: MLXConfiguration,
        catalog: MLXModelCatalog,
        continuation: AsyncThrowingStream<MLXDownloadEvent, Error>.Continuation
    ) async {
        defer {
            downloads[operationID] = nil
            downloadTasks[operationID] = nil
            if let repositoryID = downloadRepositoryIDs.removeValue(forKey: operationID) { downloadingRepositories.remove(repositoryID) }
        }
        do {
            let destination = try MLXModelCatalog.managedPath(for: downloadRequest.repositoryID, root: configuration.managedModelsDirectory)
            if let existing = try? await catalog.validateModelDirectory(destination, source: .appManagedDownload, repositoryID: downloadRequest.repositoryID),
               let manifest = MLXModelCatalog.managedManifest(at: destination), manifest.repositoryID == downloadRequest.repositoryID, manifest.complete {
                continuation.yield(.completed(existing))
                continuation.finish()
                return
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: configuration.managedModelsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path),
               !MLXModelCatalog.isDirectChild(destination, of: configuration.managedModelsDirectory) {
                throw MLXError.invalidModelDirectory
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try MLXModelCatalog.writeManagedManifest(repositoryID: downloadRequest.repositoryID, complete: false, to: destination, root: configuration.managedModelsDirectory)
            let processRequest = CommandRequest(
                arguments: ["-c", Self.snapshotDownloadScript, downloadRequest.repositoryID, destination.path],
                environment: ["HF_HUB_OFFLINE": "0", "HF_HUB_DISABLE_TELEMETRY": "1"],
                redactions: [],
                captureLimit: 64 * 1024,
                suppressOutputEvents: false
            )
            try Task.checkCancellation()
            let execution = try processFactory.launch(executableURL: python, request: processRequest)
            downloads[operationID] = execution
            var commandResult: CommandResult?
            for try await event in execution.events {
                try Task.checkCancellation()
                switch event {
                case .standardOutput(let text), .standardError(let text):
                    let safe = processRequest.sanitizeOutput(text)
                    if !safe.isEmpty { continuation.yield(.output(String(safe.prefix(4_096)))) }
                case .completed(let result): commandResult = result
                }
            }
            downloads[operationID] = nil
            guard let commandResult, commandResult.succeeded else {
                let status = commandResult?.timedOut == true ? "timed out" : "failed"
                throw MLXError.operationFailed("Model download \(status). Any partial files were retained so the download can be retried.")
            }
            try Task.checkCancellation()
            let model = try await catalog.validateModelDirectory(destination, source: .appManagedDownload, repositoryID: downloadRequest.repositoryID)
            try MLXModelCatalog.writeManagedManifest(repositoryID: downloadRequest.repositoryID, complete: true, to: destination, root: configuration.managedModelsDirectory)
            continuation.yield(.completed(model))
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: MLXError.operationFailed("Download cancelled. Partial files were retained so it can be resumed."))
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func cancelDownload(id: UUID) async {
        downloadTasks[id]?.cancel()
        if let execution = downloads[id] { await execution.terminateAndWait() }
        if let task = downloadTasks[id] { await task.value }
    }

    public func startServer(modelID: String, options: MLXServerOptions) async throws -> MLXServerSession {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw MLXError.operationFailed("The MLX service is shutting down.") }
        let startingConfiguration = configuration
        let snapshot = try await listLocalModels()
        try Task.checkCancellation()
        guard !isShuttingDown else { throw MLXError.operationFailed("The MLX service is shutting down.") }
        guard configuration == startingConfiguration else { throw MLXError.operationFailed("MLX settings changed while preparing the server. Retry with the current settings.") }
        guard let model = snapshot.first(where: { $0.id == modelID }), model.isReady,
              FileManager.default.fileExists(atPath: model.path.appendingPathComponent("config.json").path) else {
            throw MLXError.modelNotFound
        }
        let capability = await capability()
        try Task.checkCancellation()
        guard !isShuttingDown else { throw MLXError.operationFailed("The MLX service is shutting down.") }
        guard configuration == startingConfiguration else { throw MLXError.operationFailed("MLX settings changed while checking the runtime. Retry with the current settings.") }
        guard capability.available, let executable = capability.executableURL else {
            throw MLXError.toolchainUnavailable(capability.reason ?? "mlx_lm is unavailable.")
        }
        guard !servers.values.contains(where: { $0.session.port == options.port && [.starting, .running, .stopping].contains($0.session.state) }) else {
            throw MLXError.serverAlreadyOwnsPort(options.port)
        }
        guard !servers.values.contains(where: { $0.session.modelID == model.id && [.starting, .running, .stopping].contains($0.session.state) }) else {
            throw MLXError.operationFailed("A local server for this model is already active.")
        }

        let id = UUID()
        let session = MLXServerSession(id: id, modelID: model.id, port: options.port, state: .starting)
        let request = CommandRequest(
            arguments: [
                "server", "--model", model.path.path,
                "--host", "127.0.0.1",
                "--port", String(options.port),
                "--max-tokens", String(options.maxTokens),
                "--temp", String(options.temperature),
                "--allowed-origins", "http://localhost,http://127.0.0.1",
            ],
            environment: [
                "HF_HUB_OFFLINE": "1",
                "HF_HUB_DISABLE_TELEMETRY": "1",
                "HF_TOKEN": "",
                "HUGGING_FACE_HUB_TOKEN": "",
            ],
            captureLimit: 64 * 1024,
            suppressOutputEvents: false
        )
        try Task.checkCancellation()
        guard !isShuttingDown else { throw MLXError.operationFailed("The MLX service is shutting down.") }
        let execution = try processFactory.launch(executableURL: executable, request: request)
        pruneInactiveServers(forModelID: model.id)
        servers[id] = ServerEntry(session: session, execution: execution)
        let events = execution.events
        let monitor = Task { [weak self] in
            do {
                for try await event in events {
                    await self?.handle(event, for: id, expectedPort: options.port)
                }
            } catch {
                await self?.handleProcessFailure(error, for: id)
            }
        }
        if var entry = servers[id] {
            entry.processTask = monitor
            servers[id] = entry
        }
        return session
    }

    public func stopServer(id: UUID) async throws {
        guard let entry = servers[id] else { throw MLXError.unknownServer }
        guard entry.session.state == .starting || entry.session.state == .running || entry.session.state == .stopping else { return }
        servers[id]?.stopRequested = true
        if entry.session.state != .stopping { updateState(id, state: .stopping, detail: nil) }
        servers[id]?.readinessTask?.cancel()
        let chats = servers[id]?.activeChatTasks.values.map { $0 } ?? []
        chats.forEach { $0.cancel() }
        for chat in chats { await chat.value }
        await entry.execution?.terminateAndWait()
        await entry.processTask?.value
        guard let current = servers[id], !Self.isTerminal(current.session.state) else { return }
        finalizeServer(id, state: .stopped, detail: "Stopped by ContainerDesk.")
    }

    public func serverEvents(id: UUID) async -> AsyncStream<MLXServerEvent> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<MLXServerEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        guard var entry = servers[id] else { continuation.finish(); return stream }
        continuation.yield(.state(entry.session))
        for output in entry.output { continuation.yield(.output(output)) }
        if Self.isTerminal(entry.session.state) {
            continuation.finish()
            return stream
        }
        entry.subscribers[subscriberID] = continuation
        servers[id] = entry
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID, from: id) }
        }
        return stream
    }

    public func ownedServers() async -> [MLXServerSession] {
        servers.values.map(\.session).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func trashManagedModel(id: String) async throws {
        let catalog = MLXModelCatalog(configuration: configuration, environment: environment)
        guard let model = await catalog.listLocalModels().first(where: { $0.id == id && $0.source == .appManagedDownload }),
              let repositoryID = model.repositoryID,
              MLXModelCatalog.isDirectChild(model.path, of: configuration.managedModelsDirectory),
              let manifest = MLXModelCatalog.managedManifest(at: model.path), manifest.complete, manifest.repositoryID == repositoryID,
              let canonicalRoot = try? configuration.managedModelsDirectory.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]),
              canonicalRoot.isDirectory == true,
              model.path.deletingLastPathComponent().standardizedFileURL.path == configuration.managedModelsDirectory.standardizedFileURL.path else {
            throw MLXError.invalidModelDirectory
        }
        guard !servers.values.contains(where: { $0.session.modelID == id && [.starting, .running, .stopping].contains($0.session.state) }) else {
            throw MLXError.operationFailed("Stop this model's local server before moving it to Trash.")
        }
        var trashedURL: NSURL?
        do { try FileManager.default.trashItem(at: model.path, resultingItemURL: &trashedURL) }
        catch { throw MLXError.operationFailed("Could not move the app-managed model to Trash.") }
    }

    public func chat(serverID: UUID, messages: [MLXChatMessage], options: MLXChatOptions) async -> AsyncThrowingStream<String, Error> {
        guard let entry = servers[serverID], entry.session.state == .running, entry.execution?.isLeaderRunning == true else {
            return Self.failedChat(MLXError.serverNotReady)
        }
        guard let payload = Self.chatPayload(messages: messages, options: options),
              let body = try? JSONEncoder().encode(payload), body.count <= 1_048_576,
              let url = URL(string: "http://127.0.0.1:\(entry.session.port)/v1/chat/completions") else {
            return Self.failedChat(MLXError.invalidChatRequest)
        }
        let serverID = entry.session.id
        let chatID = UUID()
        let upstream = chatTransport.stream(url: url, body: body)
        // The total response is capped below at 2 MiB; keep all chunks so a slow UI consumer never loses tokens.
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task { [weak self] in
            var outputBytes = 0
            do {
                for try await chunk in upstream {
                    try Task.checkCancellation()
                    outputBytes += chunk.utf8.count
                    guard outputBytes <= 2 * 1024 * 1024 else { throw MLXError.chatResponseTooLarge }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await self?.removeChat(chatID, from: serverID)
        }
        if var current = servers[serverID] {
            current.activeChatTasks[chatID] = task
            servers[serverID] = current
        } else {
            task.cancel()
            continuation.finish(throwing: MLXError.serverNotReady)
        }
        continuation.onTermination = { @Sendable [weak self] _ in
            task.cancel()
            Task { await self?.removeChat(chatID, from: serverID) }
        }
        return stream
    }

    public func stopAllOwnedServers() async {
        let ids = servers.values.filter { [.starting, .running, .stopping].contains($0.session.state) }.map { $0.session.id }
        for id in ids { try? await stopServer(id: id) }
    }

    public func shutdown() async {
        if let shutdownOperation {
            await shutdownOperation.value
            return
        }
        guard !isShuttingDown else { return }
        isShuttingDown = true
        capabilityTask?.cancel()
        capabilityTask = nil
        cachedCapability = nil

        let operation = Task { [weak self] in
            guard let self else { return }
            await self.performShutdown()
        }
        shutdownOperation = operation
        await operation.value
        shutdownOperation = nil
    }

    private func performShutdown() async {
        let activeScan = catalogScan
        if let activeScan {
            activeScan.cancellation.cancel()
            activeScan.task.cancel()
        }
        await stopAllOwnedServers()
        for id in Array(downloadTasks.keys) { await cancelDownload(id: id) }
        for id in Array(servers.keys) {
            let chats = servers[id]?.activeChatTasks.values.map { $0 } ?? []
            chats.forEach { $0.cancel() }
            for chat in chats { await chat.value }
        }
        for id in Array(servers.keys) {
            servers[id]?.readinessTask?.cancel()
            servers[id]?.subscribers.values.forEach { $0.finish() }
        }
        if let activeScan {
            _ = await activeScan.task.result
            if catalogScan?.id == activeScan.id { catalogScan = nil }
        }
        servers.removeAll()
    }

    private func handle(_ event: CommandEvent, for id: UUID, expectedPort: UInt16) async {
        switch event {
        case .standardOutput(let text), .standardError(let text):
            appendOutput(text, for: id)
            let combined = servers[id]?.output.joined() ?? ""
            let compact = combined.replacingOccurrences(of: " ", with: "")
            if servers[id]?.session.state == .starting,
               compact.localizedCaseInsensitiveContains("Startinghttpdat127.0.0.1onport\(expectedPort)") {
                updateState(id, state: .running, detail: "Listening on 127.0.0.1:\(expectedPort)")
            }
        case .completed(let result):
            guard let initialState = servers[id]?.session.state, !Self.isTerminal(initialState) else { return }
            if initialState != .stopping { updateState(id, state: .stopping, detail: nil) }
            servers[id]?.readinessTask?.cancel()
            await drainChats(for: id)
            if servers[id]?.stopRequested == true {
                finalizeServer(id, state: .stopped, detail: "Stopped by ContainerDesk.")
            } else if result.succeeded {
                finalizeServer(id, state: .stopped, detail: "Server exited.")
            } else {
                finalizeServer(id, state: .failed, detail: result.timedOut ? "Server startup timed out." : "mlx_lm server exited with status \(result.exitCode).")
            }
        }
    }

    private func handleProcessFailure(_ error: Error, for id: UUID) async {
        guard let initialState = servers[id]?.session.state, !Self.isTerminal(initialState) else { return }
        if initialState != .stopping { updateState(id, state: .stopping, detail: nil) }
        let execution = servers[id]?.execution
        await execution?.terminateAndWait()
        await drainChats(for: id)
        let state: MLXServerState = servers[id]?.stopRequested == true ? .stopped : .failed
        finalizeServer(id, state: state, detail: state == .stopped ? "Stopped by ContainerDesk." : "Could not start the local model server.")
    }

    private func appendOutput(_ text: String, for id: UUID) {
        guard var entry = servers[id] else { return }
        let safe = String(CommandRequest(arguments: []).sanitizeOutput(text).prefix(4_096))
        guard !safe.isEmpty else { return }
        entry.output.append(safe)
        var size = entry.output.reduce(0) { $0 + $1.utf8.count }
        while size > 64 * 1024, !entry.output.isEmpty { size -= entry.output.removeFirst().utf8.count }
        entry.subscribers.values.forEach { $0.yield(.output(safe)) }
        servers[id] = entry
    }

    private func updateState(_ id: UUID, state: MLXServerState, detail: String?) {
        guard var entry = servers[id] else { return }
        entry.session = MLXServerSession(id: id, modelID: entry.session.modelID, port: entry.session.port, state: state, detail: detail)
        entry.subscribers.values.forEach { $0.yield(.state(entry.session)) }
        servers[id] = entry
    }

    private func finalizeServer(_ id: UUID, state: MLXServerState, detail: String?) {
        guard var entry = servers[id], !Self.isTerminal(entry.session.state) else { return }
        entry.session = MLXServerSession(id: id, modelID: entry.session.modelID, port: entry.session.port, state: state, detail: detail)
        let finalSession = entry.session
        let subscribers = Array(entry.subscribers.values)
        entry.subscribers.removeAll()
        entry.execution = nil
        entry.processTask = nil
        entry.readinessTask = nil
        entry.activeChatTasks.removeAll()
        entry.stopRequested = false
        entry.terminalOrder = nextServerTerminalOrder
        nextServerTerminalOrder &+= 1
        servers[id] = entry

        subscribers.forEach {
            $0.yield(.state(finalSession))
            $0.finish()
        }
        pruneInactiveServersIfNeeded()
    }

    private func drainChats(for id: UUID) async {
        let chats = servers[id]?.activeChatTasks.values.map { $0 } ?? []
        chats.forEach { $0.cancel() }
        for chat in chats { await chat.value }
    }

    private func pruneInactiveServers(forModelID modelID: String) {
        let oldIDs = servers.values
            .filter { $0.session.modelID == modelID && Self.isTerminal($0.session.state) }
            .map { $0.session.id }
        for id in oldIDs { servers[id] = nil }
    }

    private func pruneInactiveServersIfNeeded() {
        let inactive = servers.values
            .filter { Self.isTerminal($0.session.state) }
            .sorted { ($0.terminalOrder ?? 0) < ($1.terminalOrder ?? 0) }
        for entry in inactive.dropLast(8) { servers[entry.session.id] = nil }
    }

    private static func isTerminal(_ state: MLXServerState) -> Bool {
        state == .stopped || state == .failed
    }

    private func removeSubscriber(_ subscriberID: UUID, from id: UUID) {
        servers[id]?.subscribers.removeValue(forKey: subscriberID)
    }

    private func removeChat(_ chatID: UUID, from id: UUID) {
        servers[id]?.activeChatTasks.removeValue(forKey: chatID)
    }

    private static func failedDownload(_ error: Error) -> AsyncThrowingStream<MLXDownloadEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    private static func failedChat(_ error: Error) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    private static let snapshotDownloadScript = "import sys; from huggingface_hub import snapshot_download; snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2])"

    private static func chatPayload(messages: [MLXChatMessage], options: MLXChatOptions) -> MLXOpenAIChatPayload? {
        guard !messages.isEmpty, messages.count <= 128,
              messages.last?.role == .user,
              messages.allSatisfy({ !$0.content.isEmpty }),
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= 512 * 1024 else { return nil }
        return MLXOpenAIChatPayload(messages: messages, maxTokens: options.maxTokens, temperature: options.temperature)
    }

    private struct ServerEntry {
        var session: MLXServerSession
        var execution: ManagedProcessExecution?
        var processTask: Task<Void, Never>?
        var readinessTask: Task<Void, Never>?
        var output: [String] = []
        var subscribers: [UUID: AsyncStream<MLXServerEvent>.Continuation] = [:]
        var activeChatTasks: [UUID: Task<Void, Never>] = [:]
        var terminalOrder: UInt64?
        var stopRequested = false

        init(session: MLXServerSession, execution: ManagedProcessExecution? = nil) {
            self.session = session
            self.execution = execution
        }
    }
}

private struct MLXOpenAIChatPayload: Encodable {
    let model = "default_model"
    let messages: [MLXChatMessage]
    let stream = true
    let maxTokens: Int
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
    }

    init(messages: [MLXChatMessage], maxTokens: Int, temperature: Double) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}
