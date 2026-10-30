import Testing
import ContainerDeskCore
@testable import ContainerDeskApp

struct AdvancedCommandOutputTests {
    @Test(arguments: ["json", "yaml", "toml"])
    func structuredListsRedactOnlyAfterTheWholeDocumentArrives(_ format: String) {
        var output = AdvancedCommandOutput(section: .containers, commandID: "list", arguments: ["list", "--format", format])
        #expect(output.arguments == ["list", "--format", "json"])
        output.append(#"[{"id":"web","configuration":{"initProcess":{"environment":["DATABASE_URL=fixture-"#)
        #expect(output.text.isEmpty)
        output.append(#"private-value"]},"token":"other-private-value"}}]"#)
        #expect(output.text.isEmpty)
        output.finish(succeeded: true)
        #expect(output.text.contains("web"))
        #expect(output.text.contains("DATABASE_URL=••••"))
        #expect(!output.text.contains("private-value"))
    }

    @Test func malformedOversizedAndFailedDocumentsNeverExposePartialPayloads() {
        for (payload, succeeded, limit) in [(#"{"environment":{"DATABASE_URL":"fixture-secret"}}"#, true, 10), (#"{"environment":["DATABASE_URL=fixture-secret""#, true, 1_000), (#"{"environment":["DATABASE_URL=fixture-secret"]}"#, false, 1_000)] {
            var output = AdvancedCommandOutput(section: .containers, commandID: "list", arguments: ["list", "--format=json"], maxBytes: limit)
            output.append(payload)
            #expect(output.text.isEmpty)
            output.finish(succeeded: succeeded)
            #expect(!output.text.contains("fixture-secret"))
            #expect(output.text.contains("hidden"))
        }
    }

    @Test func environmentDictionariesAndInspectUseTheSameRedaction() {
        var output = AdvancedCommandOutput(section: .containers, commandID: "inspect", arguments: ["inspect", "--", "web"])
        output.append(#"{"environment":{"DATABASE_URL":"fixture-secret"},"env":["OTHER=value"]}"#)
        output.finish(succeeded: true)
        #expect(!output.text.contains("fixture-secret"))
        #expect(!output.text.contains("OTHER=value"))
    }

    @Test func tableAndQuietListsStillStreamOrdinaryOutput() {
        for args in [["list"], ["list", "--format", "table"], ["list", "--format", "json", "--quiet"]] {
            var output = AdvancedCommandOutput(section: .containers, commandID: "list", arguments: args)
            output.append("web\n")
            #expect(output.text == "web\n")
            #expect(output.arguments == args)
        }
    }
}
