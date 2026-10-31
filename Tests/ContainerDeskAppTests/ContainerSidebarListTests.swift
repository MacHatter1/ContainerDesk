import AppKit
import ContainerDeskCore
import SwiftUI
import Testing
@testable import ContainerDeskApp

@Suite(.serialized)
struct ContainerSidebarListTests {
    @MainActor @Test func nativeHierarchyExposesEveryDestinationAndNonselectableGroupHeader() async throws {
        let fixture = SidebarFixture(selection: .containers)
        defer { fixture.close() }
        let outline = try await fixture.outline()
        let coordinator = try #require(outline.dataSource as? ContainerSidebarList.Coordinator)
        let expectedGroups: [(String, [ContainerSection])] = [
            ("Resources", [.stacks, .containers, .images, .volumes, .networks, .registries]),
            ("Development", [.builds, .compose, .kubernetes, .machines]),
            ("Runtime", [.logs, .system, .cleanup, .activity]),
            ("Local AI", [.mlxModels])
        ]

        #expect(outline.numberOfRows == 19)
        #expect(coordinator.outlineView(outline, numberOfChildrenOfItem: nil) == 4)
        var destinationIDs: [String] = []
        for (groupIndex, expected) in expectedGroups.enumerated() {
            let group = coordinator.outlineView(outline, child: groupIndex, ofItem: nil)
            let groupRow = outline.row(forItem: group)
            let groupCell = try #require(outline.view(atColumn: 0, row: groupRow, makeIfNecessary: true) as? NSTableCellView)
            #expect(groupCell.identifier?.rawValue == expected.0)
            #expect(groupCell.textField?.stringValue == expected.0)
            #expect(outline.isItemExpanded(group))
            #expect(coordinator.outlineView(outline, isGroupItem: group))
            #expect(!coordinator.outlineView(outline, shouldSelectItem: group))
            #expect(!coordinator.outlineView(outline, shouldCollapseItem: group))
            #expect(coordinator.outlineView(outline, numberOfChildrenOfItem: group) == expected.1.count)
            for (childIndex, section) in expected.1.enumerated() {
                let item = coordinator.outlineView(outline, child: childIndex, ofItem: group)
                let row = outline.row(forItem: item)
                let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
                #expect(outline.level(forRow: row) == 1)
                #expect(cell.identifier?.rawValue == section.rawValue)
                #expect(cell.textField?.stringValue == section.title)
                #expect(coordinator.outlineView(outline, shouldSelectItem: item))
                #expect(!coordinator.outlineView(outline, isGroupItem: item))
                destinationIDs.append(try #require(cell.identifier?.rawValue))
            }
        }
        #expect(destinationIDs.count == ContainerSection.allCases.count)
        #expect(Set(destinationIDs) == Set(ContainerSection.allCases.map(\.rawValue)))
        #expect(fixture.state.writes.isEmpty)
    }

    @MainActor @Test func nativeSelectionWritesOnceAndProgrammaticSelectionPreservesNativeRowsAndCells() async throws {
        let fixture = SidebarFixture(selection: .containers)
        defer { fixture.close() }
        let outline = try await fixture.outline()
        let coordinator = try #require(outline.dataSource as? ContainerSidebarList.Coordinator)
        let rowViews = try (0..<outline.numberOfRows).map { row in
            try #require(outline.rowView(atRow: row, makeIfNecessary: true))
        }
        let cells = try (0..<outline.numberOfRows).map { row in
            try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true))
        }

        let imagesRow = try fixture.row(for: .images, in: outline)
        outline.selectRowIndexes(IndexSet(integer: imagesRow), byExtendingSelection: false)
        #expect(fixture.state.selection == .images)
        #expect(fixture.state.writes == [.images])
        #expect(outline.accessibilitySelectedRows()?.count == 1)
        outline.selectRowIndexes(IndexSet(integer: imagesRow), byExtendingSelection: false)
        #expect(fixture.state.writes == [.images])

        fixture.state.selection = .system
        coordinator.applySelection(to: outline)
        coordinator.applySelection(to: outline)
        #expect(outline.selectedRow == (try fixture.row(for: .system, in: outline)))
        #expect(fixture.state.writes == [.images])
        fixture.host.layoutSubtreeIfNeeded()
        for row in 0..<outline.numberOfRows {
            #expect(outline.rowView(atRow: row, makeIfNecessary: true) === rowViews[row])
            #expect(outline.view(atColumn: 0, row: row, makeIfNecessary: true) === cells[row])
        }

        fixture.state.selection = nil
        coordinator.applySelection(to: outline)
        #expect(outline.selectedRow == (try fixture.row(for: .containers, in: outline)))
        #expect(fixture.state.writes == [.images])
    }

    @MainActor @Test func nativeKeyboardNavigationSkipsHeadersInBothDirections() async throws {
        let fixture = SidebarFixture(selection: .registries)
        defer { fixture.close() }
        let outline = try await fixture.outline()
        #expect(fixture.window.makeFirstResponder(outline))

        try fixture.pressArrow(down: true, in: outline)
        #expect(outline.selectedRow == (try fixture.row(for: .builds, in: outline)))
        #expect(fixture.state.selection == .builds)
        try fixture.pressArrow(down: false, in: outline)
        #expect(outline.selectedRow == (try fixture.row(for: .registries, in: outline)))
        #expect(fixture.state.selection == .registries)

        fixture.state.selection = .machines
        let coordinator = try #require(outline.dataSource as? ContainerSidebarList.Coordinator)
        coordinator.applySelection(to: outline)
        try fixture.pressArrow(down: true, in: outline)
        #expect(outline.selectedRow == (try fixture.row(for: .logs, in: outline)))
        #expect(fixture.state.writes == [.builds, .registries, .logs])

        fixture.window.setContentSize(NSSize(width: 300, height: 180))
        fixture.host.layoutSubtreeIfNeeded()
        fixture.state.selection = .mlxModels
        coordinator.applySelection(to: outline)
        let mlxRow = try fixture.row(for: .mlxModels, in: outline)
        #expect(outline.selectedRow == mlxRow)
        let selectedRect = outline.rect(ofRow: mlxRow)
        #expect(outline.visibleRect.minY <= selectedRect.minY)
        #expect(outline.visibleRect.maxY >= selectedRect.maxY)
        #expect(outline.accessibilitySelectedRows()?.count == 1)
        #expect(fixture.state.writes == [.builds, .registries, .logs])
    }
}

@MainActor private final class SidebarSelection {
    var selection: ContainerSection?
    var writes: [ContainerSection?] = []

    init(_ selection: ContainerSection?) { self.selection = selection }

    var binding: Binding<ContainerSection?> {
        Binding(get: { self.selection }, set: { value in
            self.writes.append(value)
            self.selection = value
        })
    }
}

@MainActor private final class SidebarFixture {
    let state: SidebarSelection
    let host: NSHostingView<ContainerSidebarList>
    let window: NSWindow

    init(selection: ContainerSection) {
        _ = NativeTestApplication.shared
        let state = SidebarSelection(selection)
        self.state = state
        host = NSHostingView(rootView: ContainerSidebarList(selection: state.binding))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 650), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    func outline() async throws -> NSOutlineView {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let outline = findOutline(in: host), outline.numberOfRows == 19, outline.selectedRow >= 0 {
                outline.layoutSubtreeIfNeeded()
                return outline
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return try #require(findOutline(in: host), "The hosted sidebar must create its native outline")
    }

    func row(for section: ContainerSection, in outline: NSOutlineView) throws -> Int {
        try #require((0..<outline.numberOfRows).first { row in
            outline.view(atColumn: 0, row: row, makeIfNecessary: true)?.identifier?.rawValue == section.rawValue
        })
    }

    func pressArrow(down: Bool, in outline: NSOutlineView) throws {
        let scalar = try #require(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey))
        let characters = String(scalar)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: down ? 125 : 126))
        // Dispatch directly to this test process's outline; no event enters the desktop queue.
        outline.keyDown(with: event)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    private func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { self.findOutline(in: $0) }.first
    }
}
