import ContainerDeskCore

/// Preserves checked items only while the exact reviewed identities still exist.
enum CleanupSelection {
    static func retained(_ selectedIDs: Set<String>, previous: [String: CleanupIdentity], candidates: [CleanupCandidate]) -> Set<String> {
        Set(candidates.compactMap { candidate in
            selectedIDs.contains(candidate.id) && previous[candidate.id] == candidate.identity ? candidate.id : nil
        })
    }
}
