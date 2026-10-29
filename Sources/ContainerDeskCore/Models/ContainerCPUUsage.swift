import Foundation

/// Conversions for CPU usage reported as a percentage of one fully utilized core.
public enum ContainerCPUUsage {
    /// Converts a one-core percentage to a percentage of the configured CPU allocation.
    ///
    /// Values above 100 are retained so callers can show over-allocation or sampling variance.
    public static func allocationPercent(oneCorePercent: Double?, allocatedCPUs: Int?) -> Double? {
        guard let oneCorePercent,
              oneCorePercent.isFinite,
              oneCorePercent >= 0,
              let allocatedCPUs,
              allocatedCPUs > 0 else {
            return nil
        }
        return oneCorePercent / Double(allocatedCPUs)
    }

    /// Returns the number of fully utilized core equivalents represented by a one-core percentage.
    public static func coreEquivalents(oneCorePercent: Double?) -> Double? {
        guard let oneCorePercent,
              oneCorePercent.isFinite,
              oneCorePercent >= 0 else {
            return nil
        }
        return oneCorePercent / 100
    }

    /// Calculates a one-core percentage from two cumulative CPU-time samples.
    /// A counter decrease is treated as a reset and yields no measurement.
    public static func oneCorePercent(
        previousUsageUsec: Int64,
        currentUsageUsec: Int64,
        elapsedNanoseconds: UInt64
    ) -> Double? {
        guard previousUsageUsec >= 0,
              currentUsageUsec >= previousUsageUsec,
              elapsedNanoseconds > 0 else {
            return nil
        }

        let cpuDeltaSeconds = Double(currentUsageUsec - previousUsageUsec) / 1_000_000
        let elapsedSeconds = Double(elapsedNanoseconds) / 1_000_000_000
        let percentage = cpuDeltaSeconds / elapsedSeconds * 100
        return percentage.isFinite ? percentage : nil
    }
}
