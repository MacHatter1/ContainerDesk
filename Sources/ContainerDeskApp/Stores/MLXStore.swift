import ContainerDeskCore
import Foundation
import Observation

@MainActor
@Observable
final class MLXStore {
    private(set) var capability = MLXCapability(available: false, reason: "Checking for MLX…")
    private(set) var models: [MLXModelRecord] = []
    private(set) var servers: [UUID: MLXServerSession] = [:]
    private(set) var serverOutput: [UUID: String] = [:]
    private(set) var downloadOutput = ""
    private(set) var downloadInProgress = false
    private(set) var downloadError: String?
    private(set) var modelError: String?
    private(set) var isShuttingDown = false
    private(set) var shutdownMessage: String?
    private(set) var lastRepositoryID: String
    private(set) var preferredPort: UInt16
    private(set) var chatErrors: [String: String] = [:]
    private(set) var conversations: [String: [MLXChatTurn]] = [:]

    let service: any MLXModelService
    private(set) var configuration: MLXConfiguration
    private let defaults: UserDefaults
    private var downloadTask: Task<Void, Never>?
    private var serverEventTasks: [UUID: Task<Void, Never>] = [:]
    private var serverEventTaskIDs: [UUID: UUID] = [:]
    private var chatTasks: [String: Task<Void, Never>] = [:]
    private var chatTaskIDs: [String: UUID] = [:]
    private var activeChatRequestIDs: [String: UUID] = [:]
    private var activeChatAssistantTurnIDs: [String: UUID] = [:]
    private var isConfigured = false
    private var configurationGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var serverStateRevision: UInt64 = 0
    private var serverRevisions: [UUID: UInt64] = [:]
    private var serverStartRevisions: [UUID: UInt64] = [:]

    private static let configurationKey = "containerDesk.mlx.configuration.v1"
    private static let outputLimit = 48_000
    private static let chatLimit = 96_000
    private static let chatTruncationMarker = "\n\n[Response truncated at 96 KB.]"
    private static let chatFailureMarker = "Generation failed before producing a response."
    private static let emptyChatMarker = "No response was generated."

    init(service: any MLXModelService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.configurationKey),
           let saved = try? JSONDecoder().decode(PersistedConfiguration.self, from: data) {
            configuration = MLXConfiguration(
                executableOverride: saved.executablePath.map { URL(fileURLWithPath: $0) },
                managedModelsDirectory: saved.managedModelsPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? MLXConfiguration.defaultManagedModelsDirectory,
                importedModelDirectories: saved.importedModelPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
        } else {
            configuration = MLXConfiguration()
        }
        lastRepositoryID = defaults.string(forKey: "containerDesk.mlx.lastRepositoryID") ?? ""
        let savedPort = defaults.integer(forKey: "containerDesk.mlx.preferredPort")
        preferredPort = (1024...65535).contains(savedPort) ? UInt16(savedPort) : 8080
        Task { await configureAndRefresh() }
    }

    var runningServers: [MLXServerSession] {
        servers.values.sorted {
            let order = $0.modelID.localizedStandardCompare($1.modelID)
            if order == .orderedSame { return $0.id.uuidString < $1.id.uuidString }
            return order == .orderedAscending
        }
    }

    func isChatStreaming(for serverID: UUID, sceneID: String) -> Bool { chatTasks[chatKey(serverID, sceneID)] != nil }

    func conversation(serverID: UUID, sceneID: String) -> [MLXChatTurn] { conversations[chatKey(serverID, sceneID), default: []] }
    func chatError(serverID: UUID, sceneID: String) -> String? { chatErrors[chatKey(serverID, sceneID)] }

    func configureAndRefresh() async {
        configurationGeneration &+= 1
        let generation = configurationGeneration
        isConfigured = false
        let requestedConfiguration = configuration
        await service.configure(requestedConfiguration)
        guard generation == configurationGeneration else {
            await service.configure(configuration)
            return
        }
        isConfigured = true
        await refresh(configurationGeneration: generation)
    }

    func refresh() async {
        guard isConfigured else { await configureAndRefresh(); return }
        await refresh(configurationGeneration: configurationGeneration)
    }

    private func refresh(configurationGeneration expectedConfiguration: UInt64) async {
        guard expectedConfiguration == configurationGeneration else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previouslyKnownModels = models
        async let capabilityTask = service.capability()
        async let modelsTask = service.listLocalModels()
        let updatedModels: [MLXModelRecord]?
        do {
            updatedModels = try await modelsTask
        } catch {
            guard generation == refreshGeneration, expectedConfiguration == configurationGeneration else { return }
            modelError = error.localizedDescription
            updatedModels = nil
        }
        guard generation == refreshGeneration, expectedConfiguration == configurationGeneration else { return }

        let updatedCapability = await capabilityTask
        guard generation == refreshGeneration, expectedConfiguration == configurationGeneration else { return }
        let serverRevisionBeforeFetch = serverStateRevision
        let sessions = await service.ownedServers()
        guard generation == refreshGeneration, expectedConfiguration == configurationGeneration else { return }
        capability = updatedCapability
        var refreshedServers = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let snapshotIDs = Set(refreshedServers.keys)
        for (id, revision) in serverRevisions where revision > serverRevisionBeforeFetch && snapshotIDs.contains(id) {
            if let eventUpdatedSession = servers[id] { refreshedServers[id] = eventUpdatedSession }
        }
        // Preserve a start initiated in this store while the service inventory was
        // suspended. Older sessions may emit events after removal; those events must
        // never make an ID absent from the authoritative inventory reappear.
        for (id, revision) in serverStartRevisions where revision > serverRevisionBeforeFetch {
            if let locallyStartedSession = servers[id] { refreshedServers[id] = locallyStartedSession }
        }

        // A model directory change can remove a model from the current catalog even though
        // its ContainerDesk-owned server is still using the model files it was launched with.
        // Keep that last known record available until the owned process stops so its controls
        // remain reachable (and its port stays excluded from external-service discovery).
        if let updatedModels {
            var modelsByID = Dictionary(uniqueKeysWithValues: updatedModels.map { ($0.id, $0) })
            let previouslyKnownByID = Dictionary(uniqueKeysWithValues: previouslyKnownModels.map { ($0.id, $0) })
            for session in refreshedServers.values where Self.ownsActiveSession(session) {
                if modelsByID[session.modelID] == nil, let model = previouslyKnownByID[session.modelID] {
                    modelsByID[model.id] = model
                }
            }
            models = modelsByID.values.sorted {
                if $0.displayName.localizedStandardCompare($1.displayName) == .orderedSame { return $0.id < $1.id }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            modelError = nil
        }

        let knownIDs = Set(refreshedServers.keys)
        let trackedIDs = Set(servers.keys)
            .union(serverOutput.keys)
            .union(serverEventTasks.keys)
            .union(serverRevisions.keys)
            .union(serverStartRevisions.keys)
        let staleIDs = trackedIDs.subtracting(knownIDs)
        servers = refreshedServers
        for id in staleIDs {
            cancelServerSubscription(id)
            serverOutput[id] = nil
            serverRevisions[id] = nil
            serverStartRevisions[id] = nil
            discardChatState(forServerID: id)
        }
        for session in refreshedServers.values where serverEventTasks[session.id] == nil && session.state != .stopped && session.state != .failed {
            subscribe(to: session)
        }
    }

    private static func ownsActiveSession(_ session: MLXServerSession) -> Bool {
        [.starting, .running, .stopping].contains(session.state)
    }

    func updateExecutableOverride(_ path: String?) async {
        configuration.executableOverride = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL }
        persistConfiguration()
        await configureAndRefresh()
    }

    func updateManagedModelsDirectory(_ url: URL) async {
        configuration = MLXConfiguration(
            executableOverride: configuration.executableOverride,
            managedModelsDirectory: url,
            importedModelDirectories: configuration.importedModelDirectories
        )
        persistConfiguration()
        await configureAndRefresh()
    }

    func setLastRepositoryID(_ value: String) {
        lastRepositoryID = value
        defaults.set(value, forKey: "containerDesk.mlx.lastRepositoryID")
    }

    func setPreferredPort(_ value: UInt16) {
        guard (1024...65535).contains(Int(value)) else { return }
        preferredPort = value
        defaults.set(Int(value), forKey: "containerDesk.mlx.preferredPort")
    }

    func importModel(at url: URL) async throws {
        let record = try await service.validateModelDirectory(url)
        guard record.source == .importedDirectory else { throw MLXError.invalidModelDirectory }
        if !configuration.importedModelDirectories.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            configuration = MLXConfiguration(
                executableOverride: configuration.executableOverride,
                managedModelsDirectory: configuration.managedModelsDirectory,
                importedModelDirectories: configuration.importedModelDirectories + [url.standardizedFileURL]
            )
            persistConfiguration()
        }
        await configureAndRefresh()
    }

    func forget(_ model: MLXModelRecord) async throws {
        guard model.source == .importedDirectory else { return }
        guard !isModelInUse(model.id) else { throw MLXError.operationFailed("Stop this model's local server before forgetting it.") }
        await service.forgetImportedModel(at: model.path)
        configuration = MLXConfiguration(
            executableOverride: configuration.executableOverride,
            managedModelsDirectory: configuration.managedModelsDirectory,
            importedModelDirectories: configuration.importedModelDirectories.filter { $0.standardizedFileURL != model.path.standardizedFileURL }
        )
        persistConfiguration()
        await configureAndRefresh()
    }

    func trash(_ model: MLXModelRecord) async throws {
        guard model.source == .appManagedDownload else { return }
        guard !isModelInUse(model.id) else { throw MLXError.operationFailed("Stop this model's local server before moving it to Trash.") }
        try await service.trashManagedModel(id: model.id)
        await refresh()
    }

    func download(repositoryID: String) {
        guard downloadTask == nil, !isShuttingDown else { return }
        do {
            let request = try MLXModelDownloadRequest(repositoryID: repositoryID)
            setLastRepositoryID(request.repositoryID)
            downloadOutput = "Preparing download…\n"
            downloadError = nil
            downloadInProgress = true
            downloadTask = Task {
                defer { downloadTask = nil; downloadInProgress = false }
                do {
                    let stream = await service.download(request)
                    for try await event in stream {
                        try Task.checkCancellation()
                        switch event {
                        case .output(let line): Self.appendBounded(line + "\n", to: &downloadOutput, limit: Self.outputLimit)
                        case .completed(let model):
                            Self.appendBounded("Download complete: \(model.displayName)\n", to: &downloadOutput, limit: Self.outputLimit)
                            await refresh()
                        }
                    }
                } catch is CancellationError {
                    Self.appendBounded("Download cancelled.\n", to: &downloadOutput, limit: Self.outputLimit)
                } catch {
                    downloadError = error.localizedDescription
                }
            }
        } catch {
            downloadError = error.localizedDescription
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    func startServer(for model: MLXModelRecord, port: UInt16, maxTokens: Int, temperature: Double) async throws {
        guard !isShuttingDown, capability.available, model.isReady else { throw MLXError.toolchainUnavailable(capability.reason ?? "MLX is unavailable.") }
        let options = try MLXServerOptions(port: port, maxTokens: maxTokens, temperature: temperature)
        let session = try await service.startServer(modelID: model.id, options: options)
        updateServerSession(session)
        serverStartRevisions[session.id] = serverStateRevision
        serverOutput[session.id] = ""
        subscribe(to: session)
        await refresh()
    }

    func stopServer(_ session: MLXServerSession) async throws {
        guard servers[session.id] != nil else { throw MLXError.unknownServer }
        cancelChats(serverID: session.id)
        cancelServerSubscription(session.id)
        do {
            try await service.stopServer(id: session.id)
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    func isModelInUse(_ modelID: String) -> Bool {
        servers.values.contains { $0.modelID == modelID && [.starting, .running, .stopping].contains($0.state) }
    }

    func cancelChat(serverID: UUID, sceneID: String) {
        let key = chatKey(serverID, sceneID)
        cancelChatTask(key: key, preservingHistory: true)
    }

    func cancelChats(forScene sceneID: String) {
        let prefix = sceneID + ":"
        let keys = Set(chatTasks.keys.filter { $0.hasPrefix(prefix) })
            .union(activeChatRequestIDs.keys.filter { $0.hasPrefix(prefix) })
            .union(activeChatAssistantTurnIDs.keys.filter { $0.hasPrefix(prefix) })
        for key in keys {
            cancelChatTask(key: key, preservingHistory: true)
        }
    }

    func discardChatState(forScene sceneID: String) {
        let prefix = sceneID + ":"
        let keys = Set(conversations.keys.filter { $0.hasPrefix(prefix) })
            .union(chatErrors.keys.filter { $0.hasPrefix(prefix) })
            .union(chatTasks.keys.filter { $0.hasPrefix(prefix) })
            .union(activeChatRequestIDs.keys.filter { $0.hasPrefix(prefix) })
            .union(activeChatAssistantTurnIDs.keys.filter { $0.hasPrefix(prefix) })
        for key in keys {
            cancelChatTask(key: key, preservingHistory: false)
            conversations[key] = nil
            chatErrors[key] = nil
        }
    }

    private func discardChatState(forServerID serverID: UUID) {
        cancelChats(serverID: serverID, preservingHistory: false)
        let suffix = ":" + serverID.uuidString
        for key in conversations.keys.filter({ $0.hasSuffix(suffix) }) { conversations[key] = nil }
        for key in chatErrors.keys.filter({ $0.hasSuffix(suffix) }) { chatErrors[key] = nil }
    }

    private func cancelChats(serverID: UUID, preservingHistory: Bool = true) {
        let suffix = ":" + serverID.uuidString
        let keys = Set(chatTasks.keys.filter { $0.hasSuffix(suffix) })
            .union(activeChatRequestIDs.keys.filter { $0.hasSuffix(suffix) })
            .union(activeChatAssistantTurnIDs.keys.filter { $0.hasSuffix(suffix) })
        for key in keys {
            cancelChatTask(key: key, preservingHistory: preservingHistory)
        }
    }

    private func cancelChatTask(key: String, preservingHistory: Bool) {
        if preservingHistory, let turnID = activeChatAssistantTurnIDs[key] {
            markChatStopped(turnID: turnID, key: key)
        }
        activeChatRequestIDs[key] = nil
        activeChatAssistantTurnIDs[key] = nil
        chatTasks[key]?.cancel()
        chatTasks[key] = nil
        chatTaskIDs[key] = nil
    }

    func clearChat(serverID: UUID, sceneID: String) {
        let key = chatKey(serverID, sceneID)
        cancelChat(serverID: serverID, sceneID: sceneID)
        chatErrors[key] = nil
        conversations[key] = nil
    }

    func sendChat(serverID: UUID, sceneID: String, text: String, maxTokens: Int, temperature: Double) async {
        let key = chatKey(serverID, sceneID)
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isShuttingDown, !prompt.isEmpty, servers[serverID]?.state == .running, chatTasks[key] == nil else { return }
        guard prompt.utf8.count <= Self.chatLimit / 2 else {
            chatErrors[key] = "That message is too long. Keep each message under 48 KB."
            return
        }
        conversations[key, default: []].append(MLXChatTurn(id: UUID(), role: .user, content: prompt))
        trimConversation(key)
        let messages = conversations[key, default: []]
            .filter { !$0.content.isEmpty }
            .map { MLXChatMessage(role: $0.role, content: $0.content) }
        let requestID = UUID()
        let assistantTurnID = UUID()
        conversations[key, default: []].append(MLXChatTurn(id: assistantTurnID, role: .assistant, content: ""))
        trimConversation(key)
        activeChatRequestIDs[key] = requestID
        activeChatAssistantTurnIDs[key] = assistantTurnID
        chatErrors[key] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.chatTaskIDs[key] == requestID {
                    self.chatTasks[key] = nil
                    self.chatTaskIDs[key] = nil
                }
                if self.activeChatRequestIDs[key] == requestID {
                    self.activeChatRequestIDs[key] = nil
                    self.activeChatAssistantTurnIDs[key] = nil
                }
            }
            do {
                let options = try MLXChatOptions(maxTokens: maxTokens, temperature: temperature)
                let stream = await self.service.chat(serverID: serverID, messages: messages, options: options)
                for try await token in stream {
                    try Task.checkCancellation()
                    guard self.activeChatRequestIDs[key] == requestID else { break }
                    guard self.appendChatText(token, to: assistantTurnID, key: key) else {
                        self.chatErrors[key] = "The response reached the 96 KB in-memory limit; remaining output was stopped."
                        break
                    }
                }
                if self.activeChatRequestIDs[key] == requestID,
                   self.chatTurnContent(for: assistantTurnID, key: key)?.isEmpty == true {
                    _ = self.appendChatText(Self.emptyChatMarker, to: assistantTurnID, key: key)
                    self.trimConversation(key)
                }
            } catch is CancellationError {
                self.markChatStopped(turnID: assistantTurnID, key: key)
            } catch {
                guard self.activeChatRequestIDs[key] == requestID else { return }
                if self.chatTurnContent(for: assistantTurnID, key: key)?.isEmpty == true {
                    _ = self.appendChatText(Self.chatFailureMarker, to: assistantTurnID, key: key)
                    self.trimConversation(key)
                }
                self.chatErrors[key] = error.localizedDescription
            }
        }
        chatTasks[key] = task
        chatTaskIDs[key] = requestID
        await task.value
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shutdownMessage = "Cancelling local model downloads and chat requests…"
        let pendingDownload = downloadTask
        let pendingChats = Array(chatTasks.values)
        pendingDownload?.cancel()
        for task in pendingChats { task.cancel() }
        if let pendingDownload { await pendingDownload.value }
        for task in pendingChats { await task.value }
        shutdownMessage = "Stopping ContainerDesk MLX servers…"
        for task in serverEventTasks.values { task.cancel() }
        serverEventTasks.removeAll()
        serverEventTaskIDs.removeAll()
        await service.stopAllOwnedServers()
        shutdownMessage = "Closing MLX services…"
        await service.shutdown()
        shutdownMessage = nil
    }

    private func subscribe(to session: MLXServerSession) {
        guard serverEventTasks[session.id] == nil else { return }
        let subscriptionID = UUID()
        serverEventTaskIDs[session.id] = subscriptionID
        serverEventTasks[session.id] = Task {
            defer {
                if serverEventTaskIDs[session.id] == subscriptionID {
                    serverEventTasks[session.id] = nil
                    serverEventTaskIDs[session.id] = nil
                }
            }
            let events = await service.serverEvents(id: session.id)
            for await event in events {
                guard !Task.isCancelled else { break }
                switch event {
                case .output(let text):
                    guard servers[session.id] != nil else { continue }
                    Self.appendBounded(text + "\n", to: &serverOutput[session.id, default: ""], limit: Self.outputLimit)
                case .state(let updated):
                    guard servers[session.id] != nil else { continue }
                    updateServerSession(updated)
                    if updated.state == .stopped || updated.state == .failed {
                        await refresh()
                        return
                    }
                }
            }
            if !Task.isCancelled {
                if serverEventTaskIDs[session.id] == subscriptionID {
                    serverEventTasks[session.id] = nil
                    serverEventTaskIDs[session.id] = nil
                }
                await refresh()
            }
        }
    }

    private func cancelServerSubscription(_ id: UUID) {
        serverEventTasks[id]?.cancel()
        serverEventTasks[id] = nil
        serverEventTaskIDs[id] = nil
    }

    private func persistConfiguration() {
        let value = PersistedConfiguration(
            executablePath: configuration.executableOverride?.path,
            managedModelsPath: configuration.managedModelsDirectory.path,
            importedModelPaths: configuration.importedModelDirectories.map(\.path)
        )
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.configurationKey) }
    }

    private func updateServerSession(_ session: MLXServerSession) {
        serverStateRevision &+= 1
        serverRevisions[session.id] = serverStateRevision
        servers[session.id] = session
    }

    private func appendChatText(_ text: String, to turnID: UUID, key: String) -> Bool {
        guard var turns = conversations[key], turns.contains(where: { $0.id == turnID }) else { return false }
        let markerBytes = Self.chatTruncationMarker.utf8.count
        let contentLimit = Self.chatLimit - markerBytes
        var currentBytes = turns.reduce(0) { $0 + $1.content.utf8.count }
        while currentBytes + text.utf8.count > contentLimit, turns.count > 2 {
            Self.removeOldestChatExchange(from: &turns, totalBytes: &currentBytes)
        }
        guard let activeIndex = turns.firstIndex(where: { $0.id == turnID }) else {
            conversations[key] = turns
            return false
        }
        let available = max(0, contentLimit - currentBytes)
        let incomingBytes = text.utf8
        if incomingBytes.count <= available {
            turns[activeIndex].content.append(text)
            conversations[key] = turns
            return true
        }
        var prefix = String(decoding: incomingBytes.prefix(available), as: UTF8.self)
        while prefix.utf8.count > available { prefix.removeLast() }
        turns[activeIndex].content.append(prefix)
        turns[activeIndex].content.append(Self.chatTruncationMarker)
        conversations[key] = turns
        return false
    }

    private func markChatStopped(turnID: UUID, key: String) {
        guard chatTurnContent(for: turnID, key: key)?.isEmpty == true else { return }
        _ = appendChatText("Generation stopped.", to: turnID, key: key)
        trimConversation(key)
    }

    private func chatTurnContent(for turnID: UUID, key: String) -> String? {
        conversations[key]?.first(where: { $0.id == turnID })?.content
    }

    private func trimConversation(_ key: String) {
        var turns = conversations[key, default: []]
        var totalBytes = turns.reduce(0) { $0 + $1.content.utf8.count }
        while turns.count > 40 || totalBytes > Self.chatLimit {
            guard turns.count > 2 else { break }
            Self.removeOldestChatExchange(from: &turns, totalBytes: &totalBytes)
        }
        conversations[key] = turns
    }

    private static func removeOldestChatExchange(from turns: inout [MLXChatTurn], totalBytes: inout Int) {
        guard turns.count > 2 else { return }
        let removalCount = turns[0].role == .user && turns[1].role == .assistant ? 2 : 1
        for _ in 0..<removalCount {
            totalBytes -= turns.removeFirst().content.utf8.count
        }
    }

    private func chatKey(_ serverID: UUID, _ sceneID: String) -> String { "\(sceneID):\(serverID.uuidString)" }

    private static func appendBounded(_ text: String, to destination: inout String, limit: Int) {
        destination.append(text)
        if destination.utf8.count > limit {
            destination = "…\n" + String(decoding: destination.utf8.suffix(limit - 4), as: UTF8.self)
        }
    }

    private struct PersistedConfiguration: Codable {
        let executablePath: String?
        let managedModelsPath: String?
        let importedModelPaths: [String]
    }
}

struct MLXChatTurn: Identifiable, Equatable {
    let id: UUID
    let role: MLXChatRole
    var content: String
}
