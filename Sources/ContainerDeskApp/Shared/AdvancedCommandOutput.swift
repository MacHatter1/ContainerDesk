import ContainerDeskCore
import Foundation

/// Sensitive documents are never streamed into visible view state before complete redaction.
struct AdvancedCommandOutput {
    let arguments: [String]
    let requiresDocument: Bool
    private(set) var text = ""
    private var document = ""
    private var documentBytes = 0
    private var truncated = false
    private let maxBytes: Int

    init(section: ContainerSection, commandID: String, arguments: [String], maxBytes: Int = 1_000_000) {
        var arguments = arguments
        let formatIndex = arguments.firstIndex(of: "--format").flatMap { arguments.indices.contains($0 + 1) ? $0 + 1 : nil }
        let inlineFormat = arguments.firstIndex { $0.hasPrefix("--format=") }
        let format = formatIndex.map { arguments[$0] } ?? inlineFormat.map { String(arguments[$0].dropFirst(9)) } ?? "table"
        let structuredList = section == .containers && commandID == "list" && format != "table" && !arguments.contains("--quiet")
        requiresDocument = commandID == "inspect" || structuredList
        // Parse one format safely rather than rendering unredacted YAML/TOML along a different path.
        if structuredList {
            if let formatIndex { arguments[formatIndex] = "json" }
            if let inlineFormat { arguments[inlineFormat] = "--format=json" }
        }
        self.arguments = arguments
        self.maxBytes = max(1, maxBytes)
    }

    mutating func append(_ chunk: String) {
        if requiresDocument {
            guard !truncated, chunk.utf8.count <= maxBytes - documentBytes else {
                truncated = true
                document = ""
                return
            }
            document += chunk
            documentBytes += chunk.utf8.count
        } else {
            text += chunk
            let limit = min(150_000, maxBytes)
            if text.utf8.count > limit {
                // Keep only complete Unicode scalars at the tail of transient output.
                text = String(decoding: text.utf8.suffix(limit), as: UTF8.self)
                while text.utf8.count > limit { text.removeFirst() }
            }
        }
    }

    mutating func finish(succeeded: Bool) {
        guard requiresDocument else { return }
        defer { document = ""; documentBytes = 0 }
        guard succeeded, !truncated else {
            text = "Command output was hidden because it failed or exceeded the safe document size."
            return
        }
        text = InspectRedactor.redact(document)
    }
}
