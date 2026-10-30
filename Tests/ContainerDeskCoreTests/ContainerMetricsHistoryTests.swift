import ContainerDeskCore
import Foundation
import Testing

struct ContainerMetricsHistoryTests {
    private let start = Date(timeIntervalSince1970: 10_000)
    private func container(_ state: String = "running", cpus: Int = 2, memory: Int64 = 1_000) -> ResourceSummary {
        ResourceSummary(id: "web", title: "Web", state: state, details: ResourceDetails(cpuCount: cpus, memoryLimitBytes: memory))
    }

    @Test func retainsOnlyHourOfRealSamplesWithHistoricalLimits() {
        var history = ContainerMetricsHistory()
        history.observe([container()], at: start)
        history.append(["web": ContainerMetric(cpuPercent: 100, memoryUsageBytes: 500)], containers: [container()], at: start)
        history.append([:], containers: [container()], at: start.addingTimeInterval(10))
        #expect(history.samples["web"]?.count == 1)
        #expect(history.samples["web"]?.first?.cpuOfLimit == 50)
        #expect(history.samples["web"]?.first?.memoryOfLimit == 50)
        history.append(["web": ContainerMetric(cpuPercent: 100, memoryUsageBytes: 500)], containers: [container(cpus: 4)], at: start.addingTimeInterval(900))
        #expect(history.samples["web"]?.last?.cpuOfLimit == 25)
        history.append(["web": ContainerMetric(cpuPercent: nil)], containers: [container()], at: start.addingTimeInterval(3_601))
        #expect(history.samples["web"]?.count == 2)
        #expect(history.samples["web"]?.first?.date == start.addingTimeInterval(900))
        #expect(history.samples["web"]?.last?.metric.cpuPercent == nil)
    }

    @Test func detectsExitsRestartsAndLimitsWithoutInitialFalseEvents() {
        var history = ContainerMetricsHistory()
        #expect(history.observe([container()], at: start).isEmpty)
        let exit = history.observe([container("stopped")], at: start.addingTimeInterval(1))
        #expect(exit.count == 1)
        #expect(exit.first?.kind == .exit)
        #expect(exit.first?.unexpected == true)
        let restart = history.observe([container(cpus: 4)], at: start.addingTimeInterval(2))
        #expect(Set(restart.map(\.kind.rawValue)) == ["Restart", "Limit change"])
        #expect(history.observe([container(cpus: 4)], at: start.addingTimeInterval(3)).isEmpty)
        let stopped = history.observe([], expectedExits: ["web"], at: start.addingTimeInterval(4))
        #expect(stopped.first?.unexpected == false)
    }

    @Test func fastAppRestartIsRecordedOnceAndHistoryIsBounded() {
        var history = ContainerMetricsHistory()
        history.observe([container()], at: start)
        history.recordRestart("web", at: start.addingTimeInterval(1))
        history.observe([container("stopped")], expectedExits: ["web"], at: start.addingTimeInterval(2))
        history.observe([container()], at: start.addingTimeInterval(3))
        #expect(history.events.filter { $0.kind == .restart }.count == 1)
        history.prune(at: start.addingTimeInterval(3_604))
        #expect(history.events.isEmpty)
    }

    @Test func appRestartDoesNotSuppressLaterExternalRestarts() {
        var history = ContainerMetricsHistory()
        history.observe([container()], at: start)
        history.recordRestart("web", at: start.addingTimeInterval(1))
        history.observe([container()], at: start.addingTimeInterval(2))
        history.observe([container("stopped")], at: start.addingTimeInterval(3))
        history.observe([container()], at: start.addingTimeInterval(4))
        #expect(history.events.filter { $0.kind == .restart }.count == 2)
    }

    @Test func hoverSelectsNearestSampleAndDoesNotInventValuesInGaps() {
        var history = ContainerMetricsHistory()
        history.append(["web": ContainerMetric(cpuPercent: 20, memoryUsageBytes: 100)], containers: [container()], at: start)
        history.append(["web": ContainerMetric(cpuPercent: 80, memoryUsageBytes: 400)], containers: [container()], at: start.addingTimeInterval(3))
        let samples = history.samples["web"] ?? []
        let selected = ContainerMetricsHistory.nearestSample(to: start.addingTimeInterval(2), in: samples)
        #expect(selected?.metric.cpuPercent == 80)
        #expect(selected?.metric.memoryUsageBytes == 400)
        #expect(selected?.date == start.addingTimeInterval(3))
        #expect(ContainerMetricsHistory.nearestSample(to: start.addingTimeInterval(30), in: samples) == nil)
        #expect(ContainerMetricsHistory.nearestSample(to: start, in: []) == nil)
    }
}
