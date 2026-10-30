import Foundation
import Testing
@testable import ContainerDeskCore

struct ManagedStackTests {
    @Test func repositoryRoundTripsRuntimeCollectionsAndRejectsInvalidReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ManagedStackRepository(storageURL: directory.appendingPathComponent("stacks.json"))
        #expect(try repository.load() == ManagedStackLibrary())
        var library = ManagedStackLibrary()
        var collection = ManagedStackCollection()
        collection.stacks = [ManagedStack(name: "Development", containerIDs: ["api", "db"])]
        collection.ungroupedContainerIDs = ["redis"]
        library.runtimes["default"] = collection
        try repository.save(library)
        #expect(try repository.load() == library)
        let permissions = try FileManager.default.attributesOfItem(atPath: repository.storageURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        var invalid = library
        invalid.runtimes["default"]?.stacks.append(ManagedStack(name: "development"))
        #expect(throws: ManagedStackError.duplicateName("development")) { try repository.save(invalid) }
        #expect(try repository.load() == library)
        invalid = library
        invalid.runtimes["default"]?.stacks.append(ManagedStack(name: "Other", containerIDs: ["api"]))
        #expect(throws: ManagedStackError.duplicateMembership) { try repository.save(invalid) }
        #expect(try repository.load() == library)
    }

    @Test func invalidAndFutureDocumentsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ManagedStackRepository(storageURL: directory.appendingPathComponent("stacks.json"))
        try Data("not json".utf8).write(to: repository.storageURL)
        #expect(throws: ManagedStackError.invalidDocument) { try repository.load() }
        try Data(#"{"version":2,"runtimes":{}}"#.utf8).write(to: repository.storageURL)
        #expect(throws: ManagedStackError.unsupportedVersion) { try repository.load() }
        try Data(count: 2 * 1024 * 1024 + 1).write(to: repository.storageURL)
        #expect(throws: ManagedStackError.tooLarge) { try repository.load() }
    }

    @Test func managedMembershipWinsAndRemovedMembersStayStandalone() throws {
        let managed = ManagedStack(name: "My App", containerIDs: ["api", "gone"])
        let containers = ["api", "db", "cache"].map {
            ResourceSummary(id: $0, title: "app-\($0)", state: "running", details: ResourceDetails(labels: ["com.docker.compose.project": "app"]))
        }
        let workspaces = StackWorkspaceCatalog.build(containers: containers, managedStacks: [managed], ungroupedContainerIDs: ["db"])
        let saved = try #require(workspaces.first { $0.id == managed.workspaceID })
        #expect(saved.containers.map(\.id) == ["api"])
        #expect(saved.missingContainerIDs == ["gone"])
        #expect(saved.allowsLifecycleActions)
        let discovered = try #require(workspaces.first { $0.id == "label:com.docker.compose.project=app" })
        #expect(discovered.containers.map(\.id) == ["cache"])
        #expect(workspaces.first { $0.id == "container:db" }?.containers.map(\.id) == ["db"])
        #expect(workspaces.flatMap(\.containers).map(\.id).sorted() == ["api", "cache", "db"])
    }

    @Test func emptySavedStacksPersistAndLifecyclePlansUseOnlyCurrentMembers() throws {
        let empty = ManagedStack(name: "Empty", containerIDs: ["missing"])
        let active = ManagedStack(name: "Active", containerIDs: ["--all"])
        let workspaces = StackWorkspaceCatalog.build(containers: [.init(id: "--all", title: "API", state: "running")], managedStacks: [empty, active])
        let emptyWorkspace = try #require(workspaces.first { $0.id == empty.workspaceID })
        #expect(emptyWorkspace.containers.isEmpty)
        #expect(emptyWorkspace.missingContainerIDs == ["missing"])
        #expect(StackWorkspaceCatalog.plan(.start, for: emptyWorkspace).isEmpty)
        let activeWorkspace = try #require(workspaces.first { $0.id == active.workspaceID })
        #expect(StackWorkspaceCatalog.plan(.stop, for: activeWorkspace).map(\.arguments) == [["stop", "--", "--all"]])
    }

    @Test func savingADiscoveredStackPreservesItsLabelRelatedResources() throws {
        let stack = ManagedStack(name: "App", containerIDs: ["api"])
        let labels = ["com.docker.compose.project": "app"]
        let workspaces = StackWorkspaceCatalog.build(
            containers: [.init(id: "api", title: "API", details: .init(imageReference: "alpine:3.20", labels: labels))],
            images: [.init(id: "image", title: "Alpine", details: .init(imageReference: "alpine:3.20"))],
            volumes: [.init(id: "data", title: "Data", details: .init(labels: labels))],
            networks: [.init(id: "net", title: "Network", details: .init(labels: labels))], managedStacks: [stack]
        )
        let saved = try #require(workspaces.first)
        #expect(workspaces.count == 1)
        #expect(saved.images.map(\.id) == ["image"])
        #expect(saved.volumes.map(\.id) == ["data"])
        #expect(saved.networks.map(\.id) == ["net"])
    }
}
