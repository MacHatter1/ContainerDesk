import ContainerDeskCore
import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class ContainerMonitoringStore {
    private(set) var history = ContainerMetricsHistory()
    private(set) var notificationError: String?
    var notifyOnExit: Bool { didSet { defaults.set(notifyOnExit, forKey: "monitoring.notifyOnExit") } }
    var notifyOnThreshold: Bool { didSet { defaults.set(notifyOnThreshold, forKey: "monitoring.notifyOnThreshold"); latched.removeAll() } }
    var cpuThreshold: Double { didSet { defaults.set(cpuThreshold, forKey: "monitoring.cpuThreshold"); latched.removeAll() } }
    var memoryThreshold: Double { didSet { defaults.set(memoryThreshold, forKey: "monitoring.memoryThreshold"); latched.removeAll() } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifications = ContainerNotifications()
    @ObservationIgnored private var expectedExits: [String: Date] = [:]
    @ObservationIgnored private var restarting = Set<String>()
    @ObservationIgnored private var stoppedWithSystem = Set<String>()
    @ObservationIgnored private var latched = Set<String>()
    @ObservationIgnored private let notificationHandler: ((String, String) -> Void)?

    init(defaults: UserDefaults, notificationHandler: ((String, String) -> Void)? = nil) {
        self.defaults = defaults
        self.notificationHandler = notificationHandler
        notifyOnExit = defaults.bool(forKey: "monitoring.notifyOnExit")
        notifyOnThreshold = defaults.bool(forKey: "monitoring.notifyOnThreshold")
        let cpu = defaults.double(forKey: "monitoring.cpuThreshold")
        let memory = defaults.double(forKey: "monitoring.memoryThreshold")
        cpuThreshold = cpu > 0 && cpu <= 100 ? cpu : 90
        memoryThreshold = memory > 0 && memory <= 100 ? memory : 90
    }

    func reset() {
        history = ContainerMetricsHistory()
        expectedExits.removeAll()
        restarting.removeAll()
        stoppedWithSystem.removeAll()
        latched.removeAll()
    }

    func observe(_ containers: [ResourceSummary], at date: Date = .now) {
        expectedExits = expectedExits.filter { $0.value > date }
        let events = history.observe(containers, expectedExits: Set(expectedExits.keys), at: date)
        for event in events where event.kind == .exit {
            expectedExits[event.containerID] = nil
            latched = latched.filter { !$0.hasPrefix(event.containerID + ":") }
            if event.unexpected, notifyOnExit {
                notify(title: "Container exited: \(event.containerID)", body: event.detail)
            }
        }
        // The runtime may be offline for hours after System Stop. Consume its intent on
        // the first successful inventory after shutdown, rather than expiring it offline.
        for id in stoppedWithSystem { expectedExits[id] = nil }
        stoppedWithSystem.removeAll()
    }

    func append(_ metrics: [String: ContainerMetric], containers: [ResourceSummary], at date: Date = .now) {
        history.append(metrics, containers: containers, at: date)
        guard notifyOnThreshold else { return }
        for container in containers {
            guard let sample = history.latestSample(for: container.id), sample.date == date else { continue }
            threshold(sample.cpuOfLimit, limit: cpuThreshold, key: container.id + ":cpu", title: "High CPU: \(container.title)", unit: "CPU")
            threshold(sample.memoryOfLimit, limit: memoryThreshold, key: container.id + ":memory", title: "High memory: \(container.title)", unit: "Memory")
        }
    }

    /// Known app mutations are marked before awaiting the CLI, so polls during the command are covered.
    func beginCommand(_ request: CommandRequest, containers: [ResourceSummary]) -> [String] {
        let args = Array(request.arguments.prefix { $0 != "--" })
        guard let command = args.first, !args.contains("--dry-run") else { return [] }
        let ids: [String]
        if args.starts(with: ["system", "stop"]) {
            ids = containers.map(\.id)
        } else if args.starts(with: ["compose", "down"]) {
            func option(_ names: [String]) -> String? {
                for (index, argument) in args.enumerated() {
                    if names.contains(argument), args.indices.contains(index + 1) { return args[index + 1] }
                    for name in names where argument.hasPrefix(name + "=") { return String(argument.dropFirst(name.count + 1)) }
                }
                return nil
            }
            let project = option(["--project-name", "-p"]) ?? request.environment["COMPOSE_PROJECT_NAME"]
            let file = option(["--file", "-f"]).map { URL(fileURLWithPath: $0, relativeTo: request.workingDirectory).standardizedFileURL.path }
            ids = containers.filter { container in
                let labels = container.details.labels
                if let project, !project.isEmpty {
                    return labels["com.docker.compose.project"] == project || labels["com.apple.container.compose.project"] == project
                }
                guard let file, let files = labels["com.docker.compose.project.config_files"] else { return false }
                return files.split(separator: ",").contains { URL(fileURLWithPath: String($0), relativeTo: request.workingDirectory).standardizedFileURL.path == file }
            }.map(\.id)
        } else if ["stop", "kill", "delete"].contains(command) {
            if args.contains("--all") { ids = containers.map(\.id) }
            else if let separator = request.arguments.firstIndex(of: "--") { ids = Array(request.arguments.dropFirst(separator + 1)) }
            else { ids = containers.map(\.id).filter { args.dropFirst().contains($0) } }
        } else { return [] }
        for id in ids {
            expectedExits[id] = .now.addingTimeInterval(120)
            if command == "stop" || args.starts(with: ["system", "stop"]) { restarting.insert(id) }
        }
        return ids
    }

    func finishCommand(_ request: CommandRequest, affected: [String], succeeded: Bool) {
        if !succeeded {
            for id in affected { expectedExits[id] = nil; restarting.remove(id) }
            return
        }
        for id in affected { expectedExits[id] = .now.addingTimeInterval(30) }
        if request.arguments.starts(with: ["system", "stop"]) {
            for id in affected { expectedExits[id] = .distantFuture; stoppedWithSystem.insert(id) }
        }
        guard request.arguments.first == "start" else { return }
        for id in Array(restarting) where request.arguments.contains(id) || request.arguments.contains("--all") {
            history.recordRestart(id)
            restarting.remove(id)
            expectedExits[id] = nil
        }
    }

    func beginLimitsChange(_ id: String) { expectedExits[id] = .now.addingTimeInterval(600) }
    func finishLimitsChange(_ id: String, restarted: Bool) {
        expectedExits[id] = .now.addingTimeInterval(30)
        if restarted { history.recordRestart(id) }
    }

    func requestNotificationPermission() async {
        do {
            let granted = try await notifications.requestAuthorization()
            notificationError = granted ? nil : "Notifications are disabled. Allow ContainerDesk in System Settings → Notifications."
        } catch { notificationError = error.localizedDescription }
    }

    private func threshold(_ value: Double?, limit: Double, key: String, title: String, unit: String) {
        guard let value, value.isFinite else { return }
        if value > limit {
            if latched.insert(key).inserted { notify(title: title, body: String(format: "%@ is %.1f%% of its configured limit (threshold %.0f%%).", unit, value, limit)) }
        } else if value <= max(0, limit - 5) { latched.remove(key) }
    }
    private func notify(title: String, body: String) {
        if let notificationHandler { notificationHandler(title, body); return }
        Task { [weak self] in
            do { try await self?.notifications.send(title: title, body: body) }
            catch { self?.notificationError = error.localizedDescription }
        }
    }
}

/// Created lazily: SwiftPM tests do not run inside a notification-capable app bundle.
@MainActor private final class ContainerNotifications: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func send(title: String, body: String) async throws {
        let center = center
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
