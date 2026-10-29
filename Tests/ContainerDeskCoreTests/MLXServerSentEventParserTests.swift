import Foundation
import Testing
@testable import ContainerDeskCore

struct MLXServerSentEventParserTests {
    @Test func parsesOpenAIContentAcrossArbitraryByteBoundaries() throws {
        let line = Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hello 🌍\"}}]}\r\n\n".utf8)
        var parser = MLXServerSentEventParser()
        var events: [MLXParsedChatEvent] = []
        for byte in line { events += try parser.feed(Data([byte])) }
        #expect(events == [.content("Hello 🌍")])
        #expect(!parser.didFinish)
    }

    @Test func recognizesDoneAndIgnoresNonDataLines() throws {
        var parser = MLXServerSentEventParser()
        let events = try parser.feed(Data(": ping\nevent: message\ndata: [DONE]\n".utf8))
        #expect(events == [.done])
        #expect(parser.didFinish)
    }

    @Test func rejectsMalformedJSONAndOversizedSSELines() {
        var malformed = MLXServerSentEventParser()
        #expect(throws: MLXError.self) { try malformed.feed(Data("data: {broken}\n".utf8)) }

        var oversized = MLXServerSentEventParser(maximumLineBytes: 1_024)
        #expect(throws: MLXError.self) { try oversized.feed(Data(repeating: 0x41, count: 1_025)) }
    }

    @Test func ignoresUsageOnlyFramesAndParsesCRLF() throws {
        var parser = MLXServerSentEventParser()
        let usage = try parser.feed(Data("data: {\"choices\":[],\"usage\":{\"total_tokens\":2}}\r\n".utf8))
        let content = try parser.feed(Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n".utf8))
        #expect(usage.isEmpty)
        #expect(content == [.content("ok")])
    }
}
