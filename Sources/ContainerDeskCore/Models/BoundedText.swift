import Foundation

/// Retains a UTF-8 tail without splitting a scalar or allocating a full concatenated stream.
public enum BoundedText {
    public static func append(_ chunk: String, to text: inout String, maxBytes: Int = 150_000) {
        let limit = max(0, maxBytes)
        guard limit > 0 else { text = ""; return }
        let incomingBytes = chunk.utf8.count
        if incomingBytes >= limit {
            text = suffix(chunk, maxBytes: limit)
        } else {
            text = suffix(text, maxBytes: limit - incomingBytes) + chunk
        }
    }

    private static func suffix(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let bytes = text.utf8.suffix(maxBytes).drop { $0 & 0xC0 == 0x80 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
