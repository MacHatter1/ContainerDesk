import Foundation
import Testing
@testable import ContainerDeskCore

struct ContainerCPUUsageTests {
    @Test func convertsOneCoreUsageToAllocationPercentWithoutClamping() {
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: 150, allocatedCPUs: 2) == 75)
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: 200, allocatedCPUs: 2) == 100)
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: 250, allocatedCPUs: 2) == 125)
        #expect(ContainerCPUUsage.coreEquivalents(oneCorePercent: 250) == 2.5)
    }

    @Test func rejectsUnknownOrInvalidAllocationAndUsage() {
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: 100, allocatedCPUs: nil) == nil)
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: 100, allocatedCPUs: 0) == nil)
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: 100, allocatedCPUs: -1) == nil)

        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: nil, allocatedCPUs: 2) == nil)
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: -1, allocatedCPUs: 2) == nil)
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: .nan, allocatedCPUs: 2) == nil)
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: .infinity, allocatedCPUs: 2) == nil)
        #expect(ContainerCPUUsage.allocationPercent(oneCorePercent: -.infinity, allocatedCPUs: 2) == nil)
        #expect(ContainerCPUUsage.coreEquivalents(oneCorePercent: -1) == nil)
        #expect(ContainerCPUUsage.coreEquivalents(oneCorePercent: .nan) == nil)
        #expect(ContainerCPUUsage.coreEquivalents(oneCorePercent: .infinity) == nil)
    }

    @Test func cumulativeCounterCalculationUsesElapsedMonotonicTime() {
        // 1.5 CPU-seconds over two wall-clock seconds is 75% of one core.
        #expect(ContainerCPUUsage.oneCorePercent(
            previousUsageUsec: 2_000_000,
            currentUsageUsec: 3_500_000,
            elapsedNanoseconds: 2_000_000_000
        ) == 75)
    }

    @Test func counterResetOrNonAdvancingTimestampHasNoMeasurement() {
        #expect(ContainerCPUUsage.oneCorePercent(
            previousUsageUsec: 2_000_000,
            currentUsageUsec: 500_000,
            elapsedNanoseconds: 1_000_000_000
        ) == nil)
        #expect(ContainerCPUUsage.oneCorePercent(
            previousUsageUsec: 2_000_000,
            currentUsageUsec: 2_000_000,
            elapsedNanoseconds: 0
        ) == nil)
        #expect(ContainerCPUUsage.oneCorePercent(
            previousUsageUsec: -1,
            currentUsageUsec: 1,
            elapsedNanoseconds: 1_000_000_000
        ) == nil)
    }
}
