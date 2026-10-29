import ContainerDeskCore
import Testing
@testable import ContainerDeskApp

struct CleanupSelectionTests {
    @Test func aReplacementWithTheSameNameIsNeverSelectedAutomatically() {
        let original = makeCandidate("first-creation")
        let replacement = makeCandidate("second-creation")
        let previous = [original.id: original.identity]
        #expect(CleanupSelection.retained([original.id], previous: previous, candidates: [original]) == [original.id])
        #expect(CleanupSelection.retained([original.id], previous: previous, candidates: [replacement]).isEmpty)
        #expect(CleanupSelection.retained([original.id], previous: previous, candidates: []).isEmpty)
    }

    private func makeCandidate(_ creation: String) -> CleanupCandidate {
        CleanupCandidate(category: .volumes, resourceID: "database", title: "database", reason: "Unused volume", identity: .volume(name: "database", identityToken: creation, sizeBytes: nil))
    }
}
