import Foundation

public struct ContainerLogEntry: Identifiable, Equatable, Sendable {
    public let id: Int
    public let containerID: String
    /// Time received by ContainerDesk; the CLI does not provide source timestamps.
    public let receivedAt: Date
    public let message: String
    public let isStandardError: Bool
}

/// A bounded session buffer. Each source and pipe has its own partial-line assembler.
public struct ContainerLogBuffer: Sendable {
    public struct Revision: Equatable, Sendable {
        fileprivate let sessionID = UUID()
        fileprivate var mutation: UInt64 = 0
    }
    public var entries: [ContainerLogEntry] { storage[head...].map { $0! } }
    public private(set) var revision = Revision()
    public var count: Int { storage.count - head }
    private var storage: [ContainerLogEntry?] = []
    private var head = 0
    public private(set) var discardedCount = 0
    private struct Source: Hashable { let id: String; let stderr: Bool }
    private var partials: [Source: String] = [:]
    private var escapeStates: [Source: LogEscapeFilter] = [:]
    private var nextID = 0
    private var byteCount = 0
    private var partialByteCount = 0
    private let maxEntries: Int
    private let maxBytes: Int
    private let maxLineBytes: Int

    public init(maxEntries: Int = 20_000, maxBytes: Int = 4_000_000) {
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
        self.maxLineBytes = min(16_384, max(1, maxBytes))
    }

    public mutating func append(_ chunk: String, containerID: String, stderr: Bool = false, at date: Date = .now) {
        let key = Source(id: containerID, stderr: stderr)
        var escapes = escapeStates.removeValue(forKey: key) ?? LogEscapeFilter()
        var line = partials.removeValue(forKey: key) ?? ""
        var lineBytes = line.utf8.count
        partialByteCount -= lineBytes
        // Iterate scalars, not Characters: a grapheme can contain unbounded combining marks.
        // Flush oversized lines incrementally, before allocating a concatenated full line.
        for scalar in chunk.unicodeScalars {
            guard let scalar = escapes.visible(scalar) else { continue }
            if scalar == "\n" {
                appendLine(line, containerID: containerID, stderr: stderr, at: date)
                line = ""; lineBytes = 0
                continue
            }
            let count = scalar.utf8.count
            if lineBytes + count > maxLineBytes {
                if !line.isEmpty { appendLine(line, containerID: containerID, stderr: stderr, at: date) }
                line = ""; lineBytes = 0
            }
            guard count <= maxLineBytes else { continue }
            line.unicodeScalars.append(scalar)
            lineBytes += count
        }
        if !line.isEmpty { partials[key] = line; partialByteCount += lineBytes }
        if !escapes.isGround { escapeStates[key] = escapes }
        while escapeStates.count > maxEntries, let evicted = escapeStates.keys.first {
            escapeStates.removeValue(forKey: evicted)
            discardedCount += 1
        }
        trim()
    }

    public mutating func finish(containerID: String, at date: Date = .now) {
        for stderr in [false, true] {
            escapeStates.removeValue(forKey: Source(id: containerID, stderr: stderr))
            if let text = partials.removeValue(forKey: Source(id: containerID, stderr: stderr)) {
                partialByteCount -= text.utf8.count
                appendLine(text, containerID: containerID, stderr: stderr, at: date)
            }
        }
    }

    public mutating func finishAll(at date: Date = .now) {
        for id in Set(partials.keys.map(\.id) + escapeStates.keys.map(\.id)).sorted() { finish(containerID: id, at: date) }
    }

    private mutating func appendLine(_ text: String, containerID: String, stderr: Bool, at date: Date) {
        let message = text
        storage.append(ContainerLogEntry(id: nextID, containerID: containerID, receivedAt: date, message: message, isStandardError: stderr))
        nextID += 1
        revision.mutation &+= 1
        byteCount += message.utf8.count
        trim()
    }

    private mutating func trim() {
        while head < storage.count && (count > maxEntries || byteCount + partialByteCount > maxBytes) {
            byteCount -= storage[head]!.message.utf8.count
            storage[head] = nil // Release discarded text immediately, even before compaction.
            head += 1
            revision.mutation &+= 1
            discardedCount += 1
        }
        if head >= 1_024 && head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
        // Pending lines from many quiet sources must also fit in the session budget.
        while partialByteCount > maxBytes, let key = partials.keys.first, let text = partials.removeValue(forKey: key) {
            partialByteCount -= text.utf8.count
            discardedCount += 1
        }
    }

    public static func export(_ entries: [ContainerLogEntry]) -> String {
        entries.map { "\($0.receivedAt.ISO8601Format()) [\($0.containerID)]\($0.isStandardError ? " [stderr]" : "") \($0.message)" }.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }
}

/// Strip control strings before line assembly, including across chunks and line limits.
/// Payloads are discarded as they arrive; an unterminated OSC never grows a buffer.
private struct LogEscapeFilter: Sendable {
    private enum State: Sendable { case text, escape, intermediate, csi, string(osc: Bool), stringEscape(osc: Bool) }
    private var state = State.text
    var isGround: Bool { if case .text = state { return true }; return false }

    mutating func visible(_ scalar: UnicodeScalar) -> UnicodeScalar? {
        switch state {
        case .text:
            switch scalar.value {
            case 0x1B: state = .escape
            case 0x9B: state = .csi
            case 0x9D: state = .string(osc: true)
            case 0x90, 0x98, 0x9E, 0x9F: state = .string(osc: false)
            default:
                if scalar == "\n" || scalar == "\t" || scalar == "\u{200C}" || scalar == "\u{200D}" || !CharacterSet.controlCharacters.contains(scalar) { return scalar }
            }
        case .escape:
            switch scalar.value {
            case 0x1B: break
            case 0x5B: state = .csi
            case 0x5D: state = .string(osc: true)
            case 0x50, 0x58, 0x5E, 0x5F: state = .string(osc: false)
            case 0x20...0x2F: state = .intermediate
            default: state = .text
            }
        case .intermediate:
            if (0x30...0x7E).contains(scalar.value) { state = .text }
            else if scalar.value == 0x1B { state = .escape }
        case .csi:
            if (0x40...0x7E).contains(scalar.value) { state = .text }
            else if scalar.value == 0x1B { state = .escape }
        case .string(let osc), .stringEscape(let osc):
            let escaped: Bool
            if case .stringEscape = state { escaped = true } else { escaped = false }
            if scalar.value == 0x9C || (osc && scalar.value == 0x07) || (escaped && scalar == "\\") { state = .text }
            else if scalar.value == 0x1B { state = .stringEscape(osc: osc) }
            else { state = .string(osc: osc) }
        }
        return nil
    }
}
