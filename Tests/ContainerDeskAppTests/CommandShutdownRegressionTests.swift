import ContainerDeskCore
import Darwin
import Foundation
import Testing
@testable import ContainerDeskApp

@Suite(.serialized)
struct CommandShutdownRegressionTests {
    @MainActor @Test(arguments: [false, true])
    func cancelledMutationFinishesShutdownBeforeReleasingAdmission(streamed: Bool) async throws {
        let fixture = try ShutdownCLI()
        defer { fixture.remove() }
        let store = AppStore(client: fixture.client)
        let request = CommandRequest(arguments: ["stop", "web"])
        let consumer: Task<Void, Never>
        if streamed {
            let operation = store.streamWithID(request, title: "Streamed mutation")
            consumer = Task { do { for try await _ in operation.events {} } catch {} }
        } else {
            consumer = Task { _ = try? await store.execute(request, title: "Mutation") }
        }
        try await waitUntil { fixture.isAlive }
        let id = try #require(store.operations.first?.id)
        #expect(store.runtimeOperations.beginLimitsChange("web") == nil)
        store.cancelOperation(id)
        await consumer.value
        let token = store.runtimeOperations.beginLimitsChange("web")
        #expect(!fixture.isAlive, "Command completion must include waitpid and pipe drain, even after cancellation.")
        #expect(!fixture.isAlive || token == nil, "Limits must not overlap a cancelled but still-running mutation.")
        if let token { store.runtimeOperations.endLimitsChange(token) }
        #expect(store.operations.first?.state == .cancelled)
    }

    @MainActor @Test func cancellingKubernetesCallerKeepsOwnershipUntilItsProcessExits() async throws {
        let fixture = try ShutdownCLI()
        defer { fixture.remove() }
        let store = AppStore(client: fixture.client)
        let owner = UUID()
        let operation = store.kubernetesOperations
        let caller = Task { await operation.run(.init(arguments: ["k8s", "create"]), title: "Create cluster", store: store, owner: owner) }
        try await waitUntil { fixture.isAlive }
        caller.cancel()
        try await Task.sleep(for: .milliseconds(20))
        if fixture.isAlive {
            #expect(operation.isRunning && operation.owner == owner)
            let token = store.runtimeOperations.beginLimitsChange("web")
            #expect(token == nil)
            if let token { store.runtimeOperations.endLimitsChange(token) }
        }
        #expect(await caller.value == false)
        #expect(!fixture.isAlive)
        #expect(!operation.isRunning && operation.owner == nil)
        let token = try #require(store.runtimeOperations.beginLimitsChange("web"))
        store.runtimeOperations.endLimitsChange(token)
    }

    @MainActor @Test func cancellingBuildKeepsOwnershipUntilItsProcessExits() async throws {
        let fixture = try ShutdownCLI()
        defer { fixture.remove() }
        let store = AppStore(client: fixture.client)
        let build = BuildOperationStore()
        build.start(.init(arguments: ["build", "/fixture"]), title: "Build", store: store)
        try await waitUntil { fixture.isAlive }
        build.cancel()
        try await Task.sleep(for: .milliseconds(20))
        if fixture.isAlive {
            #expect(build.isRunning)
            let token = store.runtimeOperations.beginLimitsChange("web")
            #expect(token == nil)
            if let token { store.runtimeOperations.endLimitsChange(token) }
        }
        try await waitUntil { !build.isRunning }
        #expect(!fixture.isAlive)
    }

    @MainActor @Test func cancellingExecutionCallerWaitsForShutdownAndRecordsCancellation() async throws {
        let fixture = try ShutdownCLI()
        defer { fixture.remove() }
        let store = AppStore(client: fixture.client)
        let caller = Task { _ = try? await store.execute(.init(arguments: ["stop", "web"]), title: "Caller-owned mutation") }
        try await waitUntil { fixture.isAlive }
        caller.cancel()
        await caller.value
        #expect(!fixture.isAlive)
        #expect(store.operations.first?.state == .cancelled)
        let token = try #require(store.runtimeOperations.beginLimitsChange("web"))
        store.runtimeOperations.endLimitsChange(token)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

private struct ShutdownCLI {
    let folder: URL
    let marker: URL
    let client: ProcessContainerClient
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerDesk-shutdown-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        marker = folder.appendingPathComponent("pid")
        let executable = folder.appendingPathComponent("container")
        try "#!/bin/sh\ntrap '' TERM\necho $$ > '\(marker.path)'\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = ProcessContainerClient(resolver: .init(overridePath: executable.path))
    }
    private var pid: pid_t? { (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    var isAlive: Bool { pid.map { kill($0, 0) == 0 } ?? false }
    func remove() {
        if let pid, isAlive { _ = kill(-pid, SIGKILL) }
        try? FileManager.default.removeItem(at: folder)
    }
}
