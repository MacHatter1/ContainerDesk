import CoreFoundation
import Foundation

public struct ContainerStatsSample: Sendable, Equatable {
    public let id: String
    public let cpuUsageUsec: Int64
    public let memoryUsageBytes: Int64
    /// Monotonic sample time when provided by a native reader; CLI samples may omit it.
    public let sampledAtUptimeNanoseconds: UInt64?

    public init(id: String, cpuUsageUsec: Int64, memoryUsageBytes: Int64, sampledAtUptimeNanoseconds: UInt64? = nil) {
        self.id = id
        self.cpuUsageUsec = cpuUsageUsec
        self.memoryUsageBytes = memoryUsageBytes
        self.sampledAtUptimeNanoseconds = sampledAtUptimeNanoseconds
    }
}

/// Decodes only counters used in the container table; raw stats JSON is discarded.
public enum ContainerStatsJSONDecoder {
    public enum DecodeError: Error, LocalizedError {
        case unexpectedShape
        public var errorDescription: String? { "The container CLI returned unexpected stats JSON." }
    }

    public static func samples(from data: Data) throws -> [ContainerStatsSample] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DecodeError.unexpectedShape
        }
        return try root.map { value in
            guard let item = value as? [String: Any],
                  let id = item["id"] as? String,
                  let cpu = integer(item["cpuUsageUsec"]),
                  let memory = integer(item["memoryUsageBytes"]) else {
                throw DecodeError.unexpectedShape
            }
            return ContainerStatsSample(id: id, cpuUsageUsec: cpu, memoryUsageBytes: memory)
        }
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }
}
