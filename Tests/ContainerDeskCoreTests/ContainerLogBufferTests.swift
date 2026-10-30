import ContainerDeskCore
import Foundation
import Testing

struct ContainerLogBufferTests {
    @Test func evictionAcrossManyCompactionsPreservesOrderIDsAndPublishedSnapshots() {
        var buffer = ContainerLogBuffer(maxEntries: 20, maxBytes: 1_000)
        buffer.append("original\n", containerID: "web")
        let published = buffer.entries
        for i in 0..<5_000 { buffer.append("line-\(i)\n", containerID: i.isMultiple(of: 2) ? "web" : "db") }
        #expect(buffer.count == 20)
        #expect(buffer.entries.map(\.message) == (4_980..<5_000).map { "line-\($0)" })
        #expect(buffer.entries.map(\.id) == Array(4_981...5_000))
        #expect(buffer.discardedCount == 4_981)
        #expect(published.map(\.message) == ["original"])
        var copy = buffer
        copy.append("copy only\n", containerID: "other")
        #expect(buffer.entries.last?.message == "line-4999")
        #expect(copy.entries.last?.message == "copy only")
    }

    @Test func stackHistoryStreamsLargeUnterminatedLinesWithinItsByteBudget() {
        var buffer = ContainerLogBuffer(maxEntries: 2_000, maxBytes: 120_000)
        for _ in 0..<256 {
            buffer.append(String(repeating: "x", count: 4_096), containerID: "web")
            #expect(buffer.entries.reduce(0) { $0 + $1.message.utf8.count } <= 120_000)
        }
        #expect(!buffer.entries.isEmpty, "Oversized partial lines should become visible incrementally")
        buffer.append("database ready\n", containerID: "db")
        buffer.finishAll()
        #expect(buffer.entries.contains { $0.containerID == "db" && $0.message == "database ready" })
        #expect(buffer.entries.reduce(0) { $0 + $1.message.utf8.count } <= 120_000)
        #expect(buffer.entries.count <= 2_000)
        #expect(buffer.discardedCount > 0)
    }

    @Test func combiningScalarsCannotBypassCompletedOrPartialLineLimits() {
        let chunk = "a" + String(repeating: "\u{0301}", count: 100_000)
        for terminated in [false, true] {
            var buffer = ContainerLogBuffer(maxEntries: 3, maxBytes: 100)
            buffer.append(chunk + (terminated ? "\n" : ""), containerID: "web")
            buffer.finish(containerID: "web")
            #expect(!buffer.entries.isEmpty)
            #expect(buffer.entries.reduce(0) { $0 + $1.message.utf8.count } <= 100)
        }
    }

    @Test func partialsAcrossManySourcesAndTinyBudgetsStayBounded() {
        var buffer = ContainerLogBuffer(maxBytes: 40)
        for index in 0..<100 { buffer.append(String(repeating: "x", count: 30), containerID: "source-\(index)") }
        buffer.finishAll()
        #expect(buffer.entries.reduce(0) { $0 + $1.message.utf8.count } <= 40)
        #expect(buffer.discardedCount > 0)
        var tiny = ContainerLogBuffer(maxBytes: 1)
        tiny.append("🌍e\u{0301}\n", containerID: "web")
        tiny.finishAll()
        #expect(tiny.entries.reduce(0) { $0 + $1.message.utf8.count } <= 1)
        #expect(!tiny.entries.contains { $0.message.contains("�") })
    }

    @Test func fragmentedLinesKeepTheirSourceAndPipe() {
        var buffer = ContainerLogBuffer()
        let date = Date(timeIntervalSince1970: 1_000)
        buffer.append("hel", containerID: "web", at: date)
        buffer.append("database ready\n", containerID: "db", at: date)
        buffer.append("warning", containerID: "web", stderr: true, at: date)
        buffer.append("lo 🌍\nnext", containerID: "web", at: date)
        buffer.finish(containerID: "web", at: date)
        #expect(buffer.entries.map(\.message) == ["database ready", "hello 🌍", "next", "warning"])
        #expect(buffer.entries.map(\.containerID) == ["db", "web", "web", "web"])
        #expect(buffer.entries.last?.isStandardError == true)
        #expect(Set(buffer.entries.map(\.id)).count == 4)
    }

    @Test func boundedBufferEvictsOldestLinesAndBoundsUnterminatedOutput() {
        var buffer = ContainerLogBuffer(maxEntries: 3, maxBytes: 100)
        buffer.append("one\ntwo\nthree\nfour\n", containerID: "web")
        #expect(buffer.entries.map(\.message) == ["two", "three", "four"])
        #expect(buffer.discardedCount == 1)
        buffer.append(String(repeating: "x", count: 100_000), containerID: "web")
        buffer.finish(containerID: "web")
        #expect(buffer.entries.count <= 3)
        #expect(buffer.entries.allSatisfy { $0.message.count < 150 })
        #expect(buffer.discardedCount > 1)
    }

    @Test func exportIncludesOnlySuppliedRangeAndRemovesTerminalEscapes() {
        var buffer = ContainerLogBuffer()
        let date = Date(timeIntervalSince1970: 1_000)
        buffer.append("hidden\n", containerID: "db", at: date)
        buffer.append("\u{1B}[31merror\u{1B}[0m\r\n", containerID: "web", stderr: true, at: date)
        let output = ContainerLogBuffer.export(Array(buffer.entries.suffix(1)))
        #expect(output.contains("[web] [stderr] error"))
        #expect(output.contains(date.ISO8601Format()))
        #expect(!output.contains("hidden"))
        #expect(!output.contains("\u{1B}"))
    }
}
