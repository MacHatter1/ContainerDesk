import ContainerDeskCore
import Foundation
import Observation

@MainActor @Observable
final class ResourceActionOperation {
    struct Review: Identifiable {
        let id = UUID()
        let kind: ResourceActionKind
        let section: ContainerSection
        let resources: [ResourceSummary]
        let runtime: AppStore.ReviewedRuntime
        let archiveURL: URL?

        init(kind: ResourceActionKind, section: ContainerSection, resources: [ResourceSummary], runtime: AppStore.ReviewedRuntime, archiveURL: URL? = nil) {
            self.kind = kind
            self.section = section
            self.resources = resources
            self.runtime = runtime
            self.archiveURL = archiveURL
        }

        var title: String {
            switch kind {
            case .start: "Start Container"
            case .stop: "Stop Container"
            case .restart: "Restart Container"
            case .stopAll: "Stop All Containers"
            case .delete: "Delete \(resourceType)"
            case .load: "Load Image Archive"
            case .save: "Save Image Archive"
            default: "Resource Action"
            }
        }

        var progressMessage: String {
            switch kind {
            case .start: "Starting \(targetLabel)…"
            case .stop: "Stopping \(targetLabel)…"
            case .restart: "Restarting \(targetLabel)…"
            case .stopAll: "Stopping \(resources.count) containers…"
            case .delete: "Deleting \(targetLabel)…"
            case .load: "Loading \(archiveURL?.lastPathComponent ?? "image archive")…"
            case .save: "Saving \(targetLabel)…"
            default: "Working…"
            }
        }

        var confirmationTitle: String {
            kind == .stopAll ? "Stop \(resources.count) Containers?" : "\(title)?"
        }

        var confirmationMessage: String {
            switch kind {
            case .stop: "Stop \(targetLabel)? Running work will be interrupted. Its data remains available."
            case .restart: "Stop and then start \(targetLabel)? Running work in this container will be interrupted."
            case .stopAll: "Stop these \(resources.count) containers: \(resources.map(Self.label).joined(separator: ", "))? Running work will be interrupted. Their data remains available."
            case .delete:
                switch section {
                case .containers: "Delete \(targetLabel)? Its writable layer will be permanently deleted."
                case .volumes: "Delete \(targetLabel)? All data in this volume will be permanently deleted."
                case .images: "Delete the local image \(targetLabel)? Containers that need it may require downloading it again."
                case .networks: "Delete \(targetLabel)? This network configuration will be removed."
                case .machines: "Delete \(targetLabel)? This machine will be permanently deleted. This cannot be undone."
                default: "Delete \(targetLabel)?"
                }
            default: "\(title): \(targetLabel)."
            }
        }

        var requiresConfirmation: Bool { [.stop, .restart, .delete, .stopAll].contains(kind) }

        fileprivate var resourceType: String {
            switch section {
            case .containers: "Container"
            case .images: "Image"
            case .volumes: "Volume"
            case .networks: "Network"
            case .machines: "Machine"
            default: "Resource"
            }
        }

        fileprivate var targetLabel: String { resources.first.map(Self.label) ?? "this resource" }
        private static func label(_ resource: ResourceSummary) -> String {
            resource.title == resource.id ? "“\(resource.id)”" : "“\(resource.title)” (\(resource.id))"
        }

        fileprivate func commands() throws -> [[String]] {
            let invalid = FeatureCommandError(message: "This action has no valid reviewed scope. Review the resource and try again.")
            switch kind {
            case .load:
                guard section == .images, resources.isEmpty, let archiveURL, archiveURL.isFileURL else { throw invalid }
                return [["image", "load", "--input", archiveURL.path]]
            case .stopAll:
                guard section == .containers, !resources.isEmpty,
                      Set(resources.map(\.id)).count == resources.count,
                      resources.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.state?.lowercased() == "running" }) else { throw invalid }
                return [["stop", "--"] + resources.map(\.id)]
            case .start, .stop, .restart, .delete, .save:
                guard resources.count == 1, let target = resources.first,
                      !target.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid }
                let positional = ["--", target.id]
                switch kind {
                case .start, .stop, .restart:
                    guard section == .containers else { throw invalid }
                    return kind == .restart ? [["stop"] + positional, ["start"] + positional] : [[kind.rawValue] + positional]
                case .delete:
                    guard ResourceActionRouting.supportsDelete(section) else { throw invalid }
                    // Routing owns the supported section prefixes; retain the exact reviewed ID.
                    let routed = try ResourceActionRouting.deletionArguments(section: section, target: target.id)
                    return [Array(routed.dropLast()) + [target.id]]
                case .save:
                    guard section == .images, let archiveURL, archiveURL.isFileURL else { throw invalid }
                    let platform = target.details.platform.map { ["--platform", $0] } ?? []
                    return [["image", "save"] + platform + ["--output", archiveURL.path] + positional]
                default: throw invalid
                }
            default: throw invalid
            }
        }
    }

    private(set) var activeReview: Review?
    private(set) var notice: FeatureNotice?
    private(set) var failure: String?
    var isRunning: Bool { activeReview != nil }

    func perform(_ review: Review, using store: AppStore) async {
        guard !isRunning else { return }
        activeReview = review
        clearResult()
        defer { activeReview = nil }
        var attemptedMutation = false
        var completedPhases = 0
        let scopedURL = [.load, .save].contains(review.kind) ? review.archiveURL : nil
        let hasAccess = scopedURL?.startAccessingSecurityScopedResource() ?? false
        defer { if hasAccess { scopedURL?.stopAccessingSecurityScopedResource() } }

        do {
            let commands = try review.commands()
            for arguments in commands {
                try Task.checkCancellation()
                do {
                    let result = try await store.execute(CommandRequest(arguments: arguments), title: review.title, reviewedRuntime: review.runtime)
                    attemptedMutation = true
                    guard result.succeeded else { throw FeatureCommandError(result: result) }
                    completedPhases += 1
                } catch {
                    // Runtime and limits guards reject before the CLI is called.
                    if !(error is RuntimeOperationError) { attemptedMutation = true }
                    throw error
                }
            }
            await store.refresh(review.section, force: true)
            notice = successNotice(for: review)
        } catch {
            var message = error.localizedDescription
            if review.kind == .restart && completedPhases == 1 {
                message = "\(review.targetLabel) was stopped, but could not be started. \(message)"
            } else if review.kind == .stopAll && attemptedMutation {
                message = "Some containers may already have stopped. \(message)"
            }
            failure = message
            if attemptedMutation { await store.refresh(review.section, force: true) }
        }
    }

    func clearResult() {
        notice = nil
        failure = nil
    }

    private func successNotice(for review: Review) -> FeatureNotice {
        let action: String
        switch review.kind {
        case .start: action = "Started"
        case .stop, .stopAll: action = "Stopped"
        case .restart: action = "Restarted"
        case .delete: action = "Deleted"
        case .load: action = "Loaded"
        case .save: action = "Saved"
        default: action = "Completed"
        }
        let subject: String
        switch review.kind {
        case .stopAll: subject = "\(review.resources.count) containers"
        case .load: subject = "“\(review.archiveURL?.lastPathComponent ?? "image archive")”"
        default: subject = review.targetLabel
        }
        let title = review.kind == .stopAll ? "Containers Stopped" : [.load, .save].contains(review.kind) ? "Image Archive \(action)" : "\(review.resourceType) \(action)"
        return FeatureNotice(title: title, message: "\(action) \(subject).")
    }
}
