import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct ContainerMonitoringTests {
    @MainActor @Test func systemShutdownRemainsExpectedWhileTheRuntimeIsOffline() {
        let suite = "MonitorSystem.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var alerts = 0
        let monitor = ContainerMonitoringStore(defaults: defaults) { _, _ in alerts += 1 }
        monitor.notifyOnExit = true
        monitor.observe([container])
        let request = CommandRequest(arguments: ["system", "stop"])
        let affected = monitor.beginCommand(request, containers: [container])
        monitor.finishCommand(request, affected: affected, succeeded: true)
        monitor.observe([], at: .now.addingTimeInterval(600))
        #expect(affected == ["web"])
        #expect(alerts == 0)
        #expect(monitor.history.events.last?.unexpected == false)
        monitor.observe([container])
        monitor.observe([])
        #expect(alerts == 1, "Consumed shutdown intent must not hide a later crash")
    }

    @MainActor @Test func composeTeardownSuppressesOnlyItsVerifiedProjectMembers() {
        let suite = "MonitorCompose.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var alerts: [String] = []
        let monitor = ContainerMonitoringStore(defaults: defaults) { title, _ in alerts.append(title) }
        monitor.notifyOnExit = true
        let member = ResourceSummary(id: "app-web", title: "app-web", state: "running", details: .init(labels: ["com.docker.compose.project": "app"]))
        let unrelated = ResourceSummary(id: "other-web", title: "other-web", state: "running", details: .init(labels: ["com.docker.compose.project": "other"]))
        monitor.observe([member, unrelated])
        let request = CommandRequest(arguments: ["compose", "down", "--project-name", "app"])
        let affected = monitor.beginCommand(request, containers: [member, unrelated])
        monitor.finishCommand(request, affected: affected, succeeded: true)
        monitor.observe([])
        #expect(affected == ["app-web"])
        #expect(alerts == ["Container exited: other-web"])
    }

    @MainActor @Test func composeFileScopeFailureAndDryRunDoNotHideUnrelatedExits() {
        let suite = "MonitorComposeFailure.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var alerts = 0
        let monitor = ContainerMonitoringStore(defaults: defaults) { _, _ in alerts += 1 }
        monitor.notifyOnExit = true
        let member = ResourceSummary(id: "web", title: "web", state: "running", details: .init(labels: ["com.docker.compose.project.config_files": "/fixture/compose.yaml"]))
        let request = CommandRequest(arguments: ["compose", "down", "--file", "/fixture/compose.yaml"])
        monitor.observe([member])
        #expect(monitor.beginCommand(CommandRequest(arguments: request.arguments + ["--dry-run"]), containers: [member]).isEmpty)
        let affected = monitor.beginCommand(request, containers: [member])
        #expect(affected == ["web"])
        monitor.finishCommand(request, affected: affected, succeeded: false)
        monitor.observe([])
        #expect(alerts == 1)
    }

    private var container: ResourceSummary {
        ResourceSummary(id: "web", title: "Web", state: "running", details: ResourceDetails(cpuCount: 2, memoryLimitBytes: 1_000))
    }

    @MainActor @Test func appStopSuppressesExitAlertButSubsequentUnexpectedExitNotifies() {
        let suite = "ContainerMonitoringTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var alerts: [String] = []
        let monitor = ContainerMonitoringStore(defaults: defaults) { title, _ in alerts.append(title) }
        monitor.notifyOnExit = true
        monitor.observe([container])
        let stop = CommandRequest(arguments: ["stop", "--", "web"])
        let affected = monitor.beginCommand(stop, containers: [container])
        monitor.observe([])
        monitor.finishCommand(stop, affected: affected, succeeded: true)
        #expect(alerts.isEmpty)
        monitor.finishCommand(CommandRequest(arguments: ["start", "--", "web"]), affected: [], succeeded: true)
        monitor.observe([container])
        monitor.observe([])
        #expect(alerts.count == 1)
        #expect(monitor.history.events.filter { $0.kind == .restart }.count == 1)
    }

    @MainActor @Test func thresholdsNormalizeByLimitsAndRequireRecoveryBeforeRepeating() {
        let suite = "ContainerMonitoringTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var alerts: [String] = []
        let monitor = ContainerMonitoringStore(defaults: defaults) { title, _ in alerts.append(title) }
        monitor.notifyOnThreshold = true
        monitor.observe([container])
        let date = Date.now
        func sample(_ cpu: Double, _ ram: Int64, _ offset: Double) {
            monitor.append(["web": ContainerMetric(cpuPercent: cpu, memoryUsageBytes: ram)], containers: [container], at: date.addingTimeInterval(offset))
        }
        sample(100, 500, 0)
        #expect(alerts.isEmpty)
        sample(190, 950, 1)
        sample(195, 960, 2)
        sample(178, 890, 3)
        sample(195, 960, 4)
        #expect(alerts.count == 2)
        sample(150, 700, 5)
        sample(190, 950, 6)
        #expect(alerts.count == 4)
    }

    @MainActor @Test func failedMutationDoesNotHideLaterExitAndSettingsPersist() {
        let suite = "ContainerMonitoringTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var alerts = 0
        let monitor = ContainerMonitoringStore(defaults: defaults) { _, _ in alerts += 1 }
        monitor.notifyOnExit = true
        monitor.cpuThreshold = 80
        monitor.observe([container])
        let stop = CommandRequest(arguments: ["stop", "--", "web"])
        let affected = monitor.beginCommand(stop, containers: [container])
        monitor.finishCommand(stop, affected: affected, succeeded: false)
        monitor.observe([])
        #expect(alerts == 1)
        let reloaded = ContainerMonitoringStore(defaults: defaults)
        #expect(reloaded.notifyOnExit)
        #expect(reloaded.cpuThreshold == 80)
        monitor.reset()
        #expect(monitor.history.events.isEmpty)
    }
}
