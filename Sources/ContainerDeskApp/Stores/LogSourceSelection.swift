import Foundation

/// Wait for the first nonempty inventory unless the user has chosen sources explicitly.
struct LogSourceSelection {
    private(set) var ids = Set<String>()
    private var choseInitialSources = false
    private var userChangedSources = false

    mutating func observeInventory(_ ids: [String], loaded: Bool) {
        guard loaded, !ids.isEmpty, !choseInitialSources, !userChangedSources else { return }
        self.ids = Set(ids)
        choseInitialSources = true
    }

    mutating func select(_ ids: Set<String>) {
        self.ids = ids
        userChangedSources = true
    }

    mutating func set(_ id: String, enabled: Bool) {
        userChangedSources = true
        if enabled { ids.insert(id) } else { ids.remove(id) }
    }
}
