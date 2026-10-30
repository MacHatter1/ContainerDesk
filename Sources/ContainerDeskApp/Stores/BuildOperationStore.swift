import ContainerDeskCore
import Foundation
import Observation

@MainActor @Observable
final class BuildOperationStore {
    private(set) var isRunning = false
    private(set) var output = ""
    private(set) var error: String?
    private(set) var operationID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var appStore: AppStore?

    func start(_ request: CommandRequest, title: String, store: AppStore, onCompletion: @escaping @MainActor (Bool) async -> Void = { _ in }) {
        guard !isRunning else { return }
        isRunning = true
        output = ""
        error = nil
        appStore = store
        let operation = store.streamWithID(request, title: title)
        operationID = operation.operationID
        task = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            var sawCompletion = false
            do {
                for try await event in operation.events {
                    try Task.checkCancellation()
                    switch event {
                    case .standardOutput(let chunk), .standardError(let chunk): append(chunk)
                    case .completed(let result):
                        sawCompletion = true
                        succeeded = result.succeeded
                        if !succeeded { error = result.failureDescription }
                    }
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if Task.isCancelled { store.cancelOperation(operation.operationID) }
            await operation.waitForCompletion()
            let cancelled = Task.isCancelled || store.operations.first(where: { $0.id == operation.operationID })?.state == .cancelled
            if cancelled { succeeded = false; error = nil }
            else if !sawCompletion, error == nil { error = "The command stream ended before completion." }
            isRunning = false
            operationID = nil
            task = nil
            await onCompletion(succeeded)
        }
    }

    func cancel() {
        guard let operationID else { return }
        appStore?.cancelOperation(operationID)
        task?.cancel()
    }

    private func append(_ chunk: String) {
        output += chunk
        let limit = 150_000
        if output.utf8.count > limit {
            output = String(decoding: output.utf8.suffix(limit), as: UTF8.self)
            while output.utf8.count > limit { output.removeFirst() }
        }
    }
}
