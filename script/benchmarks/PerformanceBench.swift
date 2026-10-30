import Foundation

nonisolated(unsafe) private var checksum = 0

@inline(never) private func measure(_ body: () -> Int) -> [Double] {
    checksum &+= body()
    return (0..<7).map { _ in
        let start = ContinuousClock.now
        checksum &+= body()
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

@main @MainActor enum PerformanceBench {
    static func main() throws {
        var results: [[String: Any]] = []
        for count in [100, 500, 1_000, 2_000] {
            let containers = (0..<count).map { ResourceSummary(id: "id\($0)", title: String(format: "service%05d-api", $0), state: "running") }
            results.append(["name": "stack_rebuild_\(count)", "milliseconds": measure { StackWorkspaceCatalog.build(containers: containers).count }])
        }
        let containers = (0..<1_000).map { ResourceSummary(id: "id\($0)", title: String(format: "service%05d-api", $0), state: "running") }
        var tick = 0
        #if OPTIMIZED_PIPELINE
        var cache = StackWorkspaceCache()
        _ = cache.workspaces(containers: containers)
        #endif
        results.append(["name": "stack_metric_tick_5_reads_1000", "milliseconds": measure {
            tick += 1
            let metrics = ["id0": ContainerMetric(cpuPercent: Double(tick), memoryUsageBytes: 1_024)]
            var result = 0
            for _ in 0..<5 {
                #if OPTIMIZED_PIPELINE
                let rows = cache.workspaces(containers: containers, metrics: metrics)
                #else
                let rows = StackWorkspaceCatalog.build(containers: containers, metrics: metrics)
                #endif
                result += rows.count
            }
            return result
        }])
        for capacity in [1_000, 20_000] {
            var buffer = ContainerLogBuffer(maxEntries: capacity)
            buffer.append(String(repeating: "initial line\n", count: capacity), containerID: "web")
            var published = buffer.entries
            let chunk = String(repeating: "steady state log line 1234567890\n", count: 1_000)
            results.append(["name": "log_append_1000_capacity_\(capacity)", "milliseconds": measure {
                buffer.append(chunk, containerID: "web")
                published = buffer.entries
                return published.count + (published.last?.id ?? 0)
            }])
        }
        var buffer = ContainerLogBuffer()
        buffer.append(String(repeating: "request processed successfully; response=200 latency=25ms\n", count: 20_000), containerID: "app0", at: Date(timeIntervalSince1970: 1_000))
        let entries = buffer.entries
        let sources = Set((0..<100).map { "app\($0)" })
        #if OPTIMIZED_PIPELINE
        let projection = ContainerLogProjection()
        let snapshot = ContainerLogSnapshot(entries: entries)
        #endif
        for query in ["timeout", "response"] {
            results.append(["name": "log_filter_5_reads_\(query)", "milliseconds": measure {
                var count = 0
                for _ in 0..<5 {
                    #if OPTIMIZED_PIPELINE
                    count += projection.rows(in: snapshot, matching: .init(sources: sources, query: query)).count
                    #else
                    count += entries.filter { sources.contains($0.containerID) && $0.message.localizedCaseInsensitiveContains(query) }.count
                    #endif
                }
                return count
            }])
            // Model a new 150 ms publication: the first read must filter, while
            // console/count/scroll/export reuse that result within the same update.
            results.append(["name": "log_publish_5_reads_\(query)", "milliseconds": measure {
                #if OPTIMIZED_PIPELINE
                let publication = ContainerLogSnapshot(entries: entries)
                #endif
                var count = 0
                for _ in 0..<5 {
                    #if OPTIMIZED_PIPELINE
                    count += projection.rows(in: publication, matching: .init(sources: sources, query: query)).count
                    #else
                    count += entries.filter { sources.contains($0.containerID) && $0.message.localizedCaseInsensitiveContains(query) }.count
                    #endif
                }
                return count
            }])
        }
        var queryRevision = 0
        results.append(["name": "log_filter_changed_query", "milliseconds": measure {
            queryRevision += 1
            let query = "timeout-\(queryRevision)"
            #if OPTIMIZED_PIPELINE
            return projection.rows(in: snapshot, matching: .init(sources: sources, query: query)).count
            #else
            return entries.filter { sources.contains($0.containerID) && $0.message.localizedCaseInsensitiveContains(query) }.count
            #endif
        }])
        let data = try JSONSerialization.data(withJSONObject: ["results": results, "checksum": checksum], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
