import Foundation
import Testing
@testable import ContainerDeskCore

struct BoundedTextTests {
    @Test func repeatedCombiningScalarsAndOversizedChunksCannotBypassTheByteLimit() {
        var text = "e"
        for _ in 0..<100 {
            BoundedText.append(String(repeating: "\u{301}", count: 2_048), to: &text, maxBytes: 1_025)
            #expect(text.utf8.count <= 1_025)
            #expect(!text.contains("\u{FFFD}"))
        }
        BoundedText.append(String(repeating: "🙂", count: 50_000), to: &text, maxBytes: 1_025)
        #expect(text.utf8.count == 1_024)
        #expect(!text.contains("\u{FFFD}"))
    }

    @Test func suffixPreservesScalarBoundariesAndTheLatestOutput() {
        var text = "old🙂"
        BoundedText.append("new", to: &text, maxBytes: 7)
        #expect(text == "🙂new")
        BoundedText.append("!", to: &text, maxBytes: 7)
        #expect(text == "new!")
        BoundedText.append("next", to: &text, maxBytes: 0)
        #expect(text.isEmpty)
        BoundedText.append("🙂", to: &text, maxBytes: 1)
        #expect(text.isEmpty)
    }
}
