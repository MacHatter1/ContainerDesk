import ContainerDeskCore
import Foundation
import Observation

@MainActor @Observable
final class KubernetesOperationStore {
    private(set) var isRunning = false
    private(set) var output = ""
    private(set) var error: String?
    private(set) var operationID: UUID?
    private(set) var owner: UUID?
    @ObservationIgnored private var task: Task<Bool, Never>?
    @ObservationIgnored private weak var appStore: AppStore?

    func run(_ request: CommandRequest, title: String, store: AppStore, owner: UUID) async -> Bool {
        guard !isRunning, !Task.isCancelled else { return false }
        isRunning = true
        output = ""
        error = nil
        self.owner = owner
        appStore = store
        let operation = store.streamWithID(request, title: title)
        operationID = operation.operationID
        let worker = Task { @MainActor in
            var success = false
            var completed = false
            defer { isRunning = false; operationID = nil; self.owner = nil; task = nil }
            do {
                for try await event in operation.events {
                    try Task.checkCancellation()
                    switch event {
                    case .standardOutput(let text), .standardError(let text): BoundedText.append(text, to: &output)
                    case .completed(let result):
                        completed = true
                        success = result.succeeded
                        if !success { error = result.failureDescription }
                    }
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if Task.isCancelled { store.cancelOperation(operation.operationID) }
            await operation.waitForCompletion()
            if Task.isCancelled || store.operations.first(where: { $0.id == operation.operationID })?.state == .cancelled { return false }
            if !completed, error == nil { error = "The command stream ended before completion." }
            return completed && success
        }
        task = worker
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    func cancel(owner: UUID) {
        guard self.owner == owner, let operationID else { return }
        appStore?.cancelOperation(operationID)
        task?.cancel()
    }

    func clearOutput() { guard !isRunning else { return }; output = ""; error = nil }
}
