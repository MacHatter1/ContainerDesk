import ContainerDeskCore
import Foundation
import Testing
@testable import ContainerDeskApp

struct SystemDestructiveReviewTests {
    @MainActor @Test func stopServicesExecutesTheReviewedCommand() async throws {
        let suite = "SystemDestructiveReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = SystemReviewClient()
        let store = AppStore(client: client, defaults: defaults)
        let review = SystemStopReview(runtime: store.captureReviewedRuntime())
        let actions = SystemActionStore()

        let succeeded = await actions.perform {
            _ = try await store.execute(review.request, title: "Stop Container Services", reviewedRuntime: review.runtime)
        }

        #expect(succeeded)
        #expect(await client.requests().map(\.arguments) == [["system", "stop"]])
        #expect(store.operations.first?.state == .succeeded)
        #expect(!actions.isRunning && actions.error == nil)
    }

    @MainActor @Test(arguments: [false, true])
    func stopServicesRejectsChangedRuntimeBeforeRecordingOrLaunching(_ restoreOriginalPath: Bool) async throws {
        let suite = "SystemDestructiveReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = SystemReviewClient()
        let store = AppStore(client: client, defaults: defaults)
        let review = SystemStopReview(runtime: store.captureReviewedRuntime())
        let actions = SystemActionStore()
        store.cliPath = "/missing/unreviewed-container-\(UUID())"
        if restoreOriginalPath { store.cliPath = nil }

        let succeeded = await actions.perform {
            _ = try await store.execute(review.request, title: "Stop Container Services", reviewedRuntime: review.runtime)
        }

        #expect(!succeeded)
        #expect(!actions.isRunning && actions.error != nil)
        #expect(await client.requests().isEmpty)
        #expect(store.operations.isEmpty)
    }

    @MainActor @Test func removeDNSExecutesReviewedDomainAndExecutable() async throws {
        let suite = "SystemDestructiveReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/usr/bin/true", forKey: "containerDesk.cliPath")
        let client = SystemReviewClient()
        let store = AppStore(client: client, defaults: defaults)
        let actions = SystemActionStore()
        var domain = " reviewed.test \n"
        let review = try #require(actions.reviewDNSRemoval(domain: domain, store: store))
        domain = "changed.test"

        let output = try await store.executePrivilegedDNS(review.action) { request in
            try await client.run(request)
        }

        let request = try #require(await client.requests().first)
        #expect(Array(request.arguments.suffix(5)) == ["/usr/bin/true", "system", "dns", "delete", "reviewed.test"])
        #expect(review.domainName == "reviewed.test")
        #expect(domain == "changed.test")
        #expect(output == "stubbed DNS result")
        #expect(store.operations.first?.title == "Remove DNS domain reviewed.test")
        #expect(store.operations.first?.state == .succeeded)
        #expect(store.operations.first?.canRetry == false)
    }

    @MainActor @Test(arguments: [false, true])
    func removeDNSRejectsChangedRuntimeBeforeAdministratorRequest(_ restoreOriginalPath: Bool) async throws {
        let suite = "SystemDestructiveReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/usr/bin/true", forKey: "containerDesk.cliPath")
        let client = SystemReviewClient()
        let store = AppStore(client: client, defaults: defaults)
        let review = try SystemDNSRemovalReview(domain: "reviewed.test", store: store)
        store.cliPath = "/bin/echo"
        if restoreOriginalPath { store.cliPath = "/usr/bin/true" }

        await #expect(throws: RuntimeOperationError.self) {
            try await store.executePrivilegedDNS(review.action) { request in
                try await client.run(request)
            }
        }

        #expect(await client.requests().isEmpty)
        #expect(store.operations.isEmpty)
    }

    @MainActor @Test func dnsReviewsPreserveValidationBeforeElevation() throws {
        let suite = "SystemDestructiveReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/usr/bin/true", forKey: "containerDesk.cliPath")
        let store = AppStore(client: SystemReviewClient(), defaults: defaults)
        let actions = SystemActionStore()

        #expect(actions.reviewDNSRemoval(domain: "app.test; echo unsafe", store: store) == nil)
        #expect(actions.error != nil)
        #expect(throws: DNSAdminError.self) {
            try store.reviewPrivilegedDNS(.create(domainName: "app.test", localhost: "invalid-address"))
        }
        #expect(store.operations.isEmpty)
    }
}

private actor SystemReviewClient: ContainerClient {
    private var recorded: [CommandRequest] = []
    func requests() -> [CommandRequest] { recorded }
    func run(_ request: CommandRequest) async throws -> CommandResult {
        recorded.append(request)
        return .init(standardOutput: "stubbed DNS result\n", standardError: "", exitCode: 0, terminationReason: .exit, duration: .zero)
    }
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
