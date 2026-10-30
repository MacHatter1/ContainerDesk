import ContainerDeskCore
import Foundation
import Observation

@MainActor @Observable
final class UnifiedLogsStore {
    private(set) var snapshot: ContainerLogSnapshot
    @ObservationIgnored private let sessionID: UUID
    var entries: [ContainerLogEntry] { snapshot.entries }
    private(set) var errors: [String: String] = [:]
    private(set) var streamingIDs = Set<String>()
    private(set) var discardedCount = 0
    private(set) var pendingCount = 0
    private(set) var isPaused = false
    @ObservationIgnored private var buffer = ContainerLogBuffer()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var openedIDs = Set<String>()

    init() {
        let id = UUID()
        sessionID = id
        snapshot = ContainerLogSnapshot(entries: [], sessionID: id)
    }

    func configure(ids: Set<String>, client: any ContainerClient) {
        for id in Array(tasks.keys) where !ids.contains(id) { stop(id) }
        for id in ids where tasks[id] == nil { start(id, client: client) }
    }

    func retry(id: String, client: any ContainerClient) {
        stop(id)
        start(id, client: client)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { publish() }
    }

    func stop() {
        for id in Array(tasks.keys) { stop(id) }
        publishTask?.cancel()
        publishTask = nil
        if !isPaused { publish() }
    }

    private func stop(_ id: String) {
        generations[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
        streamingIDs.remove(id)
        errors[id] = nil
        buffer.finish(containerID: id)
    }

    private func start(_ id: String, client: any ContainerClient) {
        let generation = UUID()
        generations[id] = generation
        errors[id] = nil
        streamingIDs.insert(id)
        // Resume an already opened source at its current end, without replaying the tail.
        let tail = openedIDs.contains(id) ? "0" : "200"
        tasks[id] = Task { [weak self] in
            do {
                let request = CommandRequest(arguments: ["logs", "--follow", "-n", tail, "--", id], captureLimit: 0)
                for try await event in client.stream(request) {
                    guard !Task.isCancelled, let self, self.generations[id] == generation else { break }
                    switch event {
                    case .standardOutput(let chunk): self.receive(chunk, id: id, stderr: false)
                    case .standardError(let chunk): self.receive(chunk, id: id, stderr: true)
                    case .completed(let result):
                        if !result.succeeded { self.errors[id] = "Log stream ended with exit code \(result.exitCode)." }
                    }
                }
            } catch {
                if !Task.isCancelled, self?.generations[id] == generation { self?.errors[id] = error.localizedDescription }
            }
            guard let self, self.generations[id] == generation else { return }
            if self.errors[id] == nil { self.errors[id] = "Log stream ended. Reconnect to continue collecting." }
            self.buffer.finish(containerID: id)
            self.streamingIDs.remove(id)
            self.tasks[id] = nil
            self.schedulePublish()
        }
    }

    private func receive(_ chunk: String, id: String, stderr: Bool) {
        if !stderr { openedIDs.insert(id) }
        buffer.append(chunk, containerID: id, stderr: stderr)
        schedulePublish()
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.publishTask = nil
            if self.isPaused {
                let lastID = self.entries.last?.id ?? -1
                self.pendingCount = self.buffer.entries.filter { $0.id > lastID }.count
            } else { self.publish() }
        }
    }

    private func publish() {
        snapshot = ContainerLogSnapshot(entries: buffer.entries, sessionID: sessionID)
        discardedCount = buffer.discardedCount
        pendingCount = 0
    }
}
