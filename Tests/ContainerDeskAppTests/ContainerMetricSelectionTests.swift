@testable import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct ContainerMetricSelectionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func sample(_ seconds: Double, cpu: Double? = 80, memory: Int64? = 4_194_304) -> ContainerHistorySample {
        .init(date: start.addingTimeInterval(seconds), metric: .init(cpuPercent: cpu, memoryUsageBytes: memory), cpuLimit: 2, memoryLimit: 8_388_608)
    }

    @Test func cursorUsesRawHistoryRatherThanDownsampledPlotAndPreservesUnits() {
        let samples = [sample(0), sample(1, cpu: 20), sample(2)]
        // The middle sample is intentionally absent from the displayed series.
        let latest = ContainerMetricSeries.build(samples: [samples[0], samples[2]], events: [], metric: .cpu(normalized: false)).points.last
        let cpu = ContainerMetricSelection(metric: .cpu(normalized: true), samples: samples, latest: latest, selectedDate: start.addingTimeInterval(1.1))
        #expect(cpu.isSelected && cpu.date == start.addingTimeInterval(1))
        #expect(cpu.value == 10)
        let memory = ContainerMetricSelection(metric: .memory, samples: samples, latest: nil, selectedDate: start.addingTimeInterval(1.1))
        #expect(memory.value == 4)
    }

    @Test func gapKeepsCursorTimeWithoutInventingAValueAndClearingRestoresLatest() {
        let samples = [sample(0), sample(60, cpu: 40)]
        let latest = ContainerMetricSeries.build(samples: samples, events: [], metric: .cpu(normalized: false)).points.last
        let gap = ContainerMetricSelection(metric: .cpu(normalized: false), samples: samples, latest: latest, selectedDate: start.addingTimeInterval(30))
        #expect(gap.date == start.addingTimeInterval(30) && gap.value == nil && gap.isSelected)
        let cleared = ContainerMetricSelection(metric: .cpu(normalized: false), samples: samples, latest: latest, selectedDate: nil)
        #expect(!cleared.isSelected && cleared.date == start.addingTimeInterval(60) && cleared.value == 40)
    }

    @Test func invalidMissingAndNegativeValuesFollowTheSeriesPolicy() {
        for value in [Double.nan, .infinity, -.infinity] {
            let selection = ContainerMetricSelection(metric: .cpu(normalized: false), samples: [sample(0, cpu: value)], latest: nil, selectedDate: start)
            #expect(selection.value == nil)
        }
        #expect(ContainerMetricSelection(metric: .cpu(normalized: false), samples: [sample(0, cpu: -10)], latest: nil, selectedDate: start).value == 0)
        #expect(ContainerMetricSelection(metric: .memory, samples: [sample(0, memory: nil)], latest: nil, selectedDate: start).value == nil)
        #expect(ContainerMetricSelection(metric: .memory, samples: [], latest: nil, selectedDate: nil).value == nil)
    }
}
