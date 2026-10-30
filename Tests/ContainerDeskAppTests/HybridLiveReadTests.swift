import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct HybridLiveReadTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTAINERDESK_LIVE_READ_CHECK"] == "1"))
    func nativeReadsMatchCLIAndAppStorePublishesLiveMetrics() async throws {
        let cli = ProcessContainerClient()
        let reader = ContainerResourceReader(cli: cli)
        let sections: [ContainerSection] = [.containers, .images, .volumes, .networks, .registries, .machines]
        let nativeSections: Set<ContainerSection> = [.containers, .volumes, .networks]
        var results: [ContainerSection: ResourceReadResult<[ResourceSummary]>] = [:]

        for section in sections {
            results[section] = try await reader.list(section)
        }

        for section in sections {
            let result = try #require(results[section], "Missing read result for \(section.title).")
            let expectedBackend: ResourceReadBackend = nativeSections.contains(section) ? .nativeAPI : .cli
            #expect(result.backend == expectedBackend, "\(section.title) used an unexpected read backend.")
        }
        let nativeListItemCount = nativeSections.compactMap { results[$0]?.value.count }.reduce(0, +)
        let cliListItemCount = sections.filter { !nativeSections.contains($0) }.compactMap { results[$0]?.value.count }.reduce(0, +)

        var parityCount = 0
        var inspectionRedactionPassed = false
        for section in nativeSections {
            guard let native = results[section] else { continue }
            let request = CommandRequest(arguments: Self.listArguments(for: section), captureLimit: 2_000_000, suppressOutputEvents: true, timeout: .seconds(30))
            let cliResult = try await cli.run(request)
            #expect(cliResult.succeeded, "The direct CLI parity read failed for \(section.title).")
            guard cliResult.succeeded else { continue }
            let cliItems = try ResourceJSONDecoder.summaries(from: Data(cliResult.standardOutput.utf8), section: section)
            let idsMatch = Set(native.value.map(\.id)) == Set(cliItems.map(\.id))
            if idsMatch { parityCount += 1 }
            #expect(idsMatch, "Native and CLI \(section.title.lowercased()) IDs differ (native count \(native.value.count), CLI count \(cliItems.count)); identifiers are omitted.")
        }

        let containers = try #require(results[.containers]?.value)
        let runningIDs = containers.filter { ($0.state ?? "").localizedCaseInsensitiveContains("running") }.map(\.id)
        #expect(!runningIDs.isEmpty, "The live check requires at least one running container.")
        let stats = try await reader.stats(ids: runningIDs)
        #expect(stats.backend == .nativeAPI, "Live stats did not use the native API.")
        #expect(!stats.value.isEmpty, "The native API returned no running-container stats.")

        if let first = containers.first {
            let inspection = try await reader.inspectContainer(id: first.id)
            #expect(inspection.backend == .nativeAPI, "Container inspection did not use the native API.")
            inspectionRedactionPassed = !Self.hasUnredactedSensitiveContent(inspection.value.json)
            #expect(inspectionRedactionPassed, "The native inspection included an unredacted sensitive field.")
        } else {
            Issue.record("The live check requires a container for inspection.")
        }

        let store = AppStore()
        let sceneID = "hybrid-live-read-check"
        let start = DispatchTime.now().uptimeNanoseconds
        var firstListMilliseconds: Double?
        var firstMemoryMilliseconds: Double?
        var firstCPUMilliseconds: Double?
        var listedCount = 0
        var memoryCount = 0
        var cpuCount = 0
        defer {
            store.setVisibleSection(nil, for: sceneID)
            store.setWindowActive(sceneID, active: false)
            store.stopPolling()
        }

        store.setWindowActive(sceneID, active: true)
        store.setVisibleSection(.containers, for: sceneID)
        while DispatchTime.now().uptimeNanoseconds - start < 15_000_000_000 {
            let snapshot = store.snapshots[.containers]
            if firstListMilliseconds == nil, snapshot?.fetchedAt != nil {
                firstListMilliseconds = Self.elapsedMilliseconds(since: start)
                listedCount = snapshot?.items.count ?? 0
            }
            if firstMemoryMilliseconds == nil {
                let samples = store.containerMetrics.values.filter { $0.memoryUsageBytes != nil }
                if !samples.isEmpty {
                    firstMemoryMilliseconds = Self.elapsedMilliseconds(since: start)
                    memoryCount = samples.count
                }
            }
            if firstCPUMilliseconds == nil {
                let samples = store.containerMetrics.values.filter { $0.cpuPercent != nil }
                if !samples.isEmpty {
                    firstCPUMilliseconds = Self.elapsedMilliseconds(since: start)
                    cpuCount = samples.count
                }
            }
            if firstListMilliseconds != nil, firstMemoryMilliseconds != nil, firstCPUMilliseconds != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(store.resourceReadBackends[.containers] == .nativeAPI, "AppStore container list did not use the native API.")
        #expect(store.containerMetricsBackend == .nativeAPI, "AppStore stats did not use the native API.")
        #expect(firstListMilliseconds != nil, "AppStore did not load the container list within 15 seconds.")
        #expect(firstMemoryMilliseconds != nil, "AppStore did not publish memory metrics within 15 seconds.")
        #expect(firstCPUMilliseconds != nil, "AppStore did not publish CPU metrics within 15 seconds.")

        let sampleCount = store.monitoring.history.samples.values.reduce(0) { $0 + $1.count }
        #expect(sampleCount > 0, "Live metrics were not retained in session history.")
        store.setVisibleSection(.logs, for: sceneID)
        let historyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.monitoring.history.samples.values.reduce(0, { $0 + $1.count }) <= sampleCount, ContinuousClock.now < historyDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.monitoring.history.samples.values.reduce(0, { $0 + $1.count }) > sampleCount, "History stopped collecting after navigation to Logs.")

        print("hybrid_live sections=\(sections.count) native_list_items=\(nativeListItemCount) cli_list_items=\(cliListItemCount) native_id_parity=\(parityCount)/\(nativeSections.count) stats_samples=\(stats.value.count) inspect_redaction=\(inspectionRedactionPassed ? "passed" : "failed") store_list_ms=\(Self.formatMilliseconds(firstListMilliseconds)) store_list_count=\(listedCount) first_ram_ms=\(Self.formatMilliseconds(firstMemoryMilliseconds)) ram_count=\(memoryCount) first_cpu_ms=\(Self.formatMilliseconds(firstCPUMilliseconds)) cpu_count=\(cpuCount) list_backend=\(store.resourceReadBackends[.containers]?.rawValue ?? "unavailable") stats_backend=\(store.containerMetricsBackend?.rawValue ?? "unavailable")")
    }

    private static func listArguments(for section: ContainerSection) -> [String] {
        switch section {
        case .containers: ["list", "--all", "--format", "json"]
        case .images: ["image", "list", "--format", "json", "--verbose"]
        case .volumes: ["volume", "list", "--format", "json"]
        case .networks: ["network", "list", "--format", "json"]
        case .registries: ["registry", "list", "--format", "json"]
        case .machines: ["machine", "list", "--format", "json"]
        default: []
        }
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func formatMilliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "timeout"
    }

    private static func hasUnredactedSensitiveContent(_ source: String) -> Bool {
        guard let data = source.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return true }
        return containsSensitiveValue(object)
    }

    private static func containsSensitiveValue(_ value: Any, key: String? = nil) -> Bool {
        let normalizedKey = (key ?? "").lowercased().filter(\.isLetter)
        let sensitiveFragments = ["password", "passwd", "token", "secret", "authorization", "credential", "privatekey", "accesskey", "apikey"]
        if normalizedKey == "environment" || normalizedKey == "env" {
            return !environmentIsRedacted(value)
        }
        if sensitiveFragments.contains(where: normalizedKey.contains) { return !valueIsRedacted(value) }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { containsSensitiveValue($0.value, key: $0.key) }
        }
        if let array = value as? [Any] {
            return argumentArrayHasUnredactedSecret(array) || array.contains { containsSensitiveValue($0) }
        }
        if let text = value as? String, assignmentHasUnredactedSecret(text) { return true }
        return false
    }

    private static func argumentArrayHasUnredactedSecret(_ values: [Any]) -> Bool {
        let flags: Set<String> = ["--password", "--passwd", "--token", "--secret", "--authorization", "--api-key", "--access-key", "--secret-key"]
        for index in values.indices {
            guard let text = values[index] as? String else { continue }
            let lower = text.lowercased()
            if flags.contains(lower), values.indices.contains(index + 1) {
                guard (values[index + 1] as? String) == "••••" else { return true }
            } else if let flag = flags.first(where: { lower.hasPrefix($0 + "=") }) {
                let suffix = text.dropFirst(flag.count + 1)
                if suffix != "••••" { return true }
            }
        }
        return false
    }

    private static func assignmentHasUnredactedSecret(_ text: String) -> Bool {
        guard let separator = text.firstIndex(of: "=") else { return false }
        let name = text[..<separator].lowercased().filter(\.isLetter)
        let sensitiveFragments = ["password", "passwd", "token", "secret", "authorization", "credential", "privatekey", "accesskey", "apikey"]
        guard sensitiveFragments.contains(where: name.contains) else { return false }
        return text[text.index(after: separator)...] != "••••"
    }

    private static func environmentIsRedacted(_ value: Any) -> Bool {
        if let values = value as? [String] {
            return values.allSatisfy { line in
                guard let separator = line.firstIndex(of: "=") else { return true }
                return line[line.index(after: separator)...] == "••••"
            }
        }
        if let values = value as? [String: Any] { return values.values.allSatisfy(valueIsRedacted) }
        return false
    }

    private static func valueIsRedacted(_ value: Any) -> Bool {
        if let text = value as? String { return text == "••••" }
        if let values = value as? [Any] { return values.allSatisfy(valueIsRedacted) }
        if let values = value as? [String: Any] { return values.values.allSatisfy(valueIsRedacted) }
        return value is NSNull
    }
}
