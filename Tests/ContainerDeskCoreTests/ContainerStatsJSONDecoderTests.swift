import Foundation
import Testing
@testable import ContainerDeskCore

struct ContainerStatsJSONDecoderTests {
    @Test func decodesOnlyUsageCounters() throws {
        let fixture = #"[{"id":"fixture-container","cpuUsageUsec":125000,"memoryUsageBytes":4096,"memoryLimitBytes":8192,"numProcesses":3}]"#
        #expect(try ContainerStatsJSONDecoder.samples(from: Data(fixture.utf8)) == [
            ContainerStatsSample(id: "fixture-container", cpuUsageUsec: 125000, memoryUsageBytes: 4096)
        ])
    }

    @Test func rejectsIncompleteStatsInsteadOfShowingZero() {
        #expect(throws: ContainerStatsJSONDecoder.DecodeError.self) {
            try ContainerStatsJSONDecoder.samples(from: Data(#"[{"id":"fixture-container","memoryUsageBytes":4096}]"#.utf8))
        }
        #expect(throws: ContainerStatsJSONDecoder.DecodeError.self) {
            try ContainerStatsJSONDecoder.samples(from: Data(#"{"notStats":[]}"#.utf8))
        }
    }
}
