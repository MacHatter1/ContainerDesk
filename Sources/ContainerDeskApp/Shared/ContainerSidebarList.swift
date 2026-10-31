import AppKit
import ContainerDeskCore
import SwiftUI

/// A static native sidebar whose selection does not rebuild its rows.
struct ContainerSidebarList: NSViewRepresentable {
    @Binding var selection: ContainerSection?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.width = 230
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowHeight = 28
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = false
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.identifier = NSUserInterfaceItemIdentifier("ContainerDesk.Sidebar")
        outline.setAccessibilityLabel("Sidebar")

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        context.coordinator.applySelection(to: outline)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        context.coordinator.applySelection(to: outline)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var selection: Binding<ContainerSection?>
        private var applyingSelection = false
        private let groups: [Item] = [
            Item("Resources", children: [
                Item(.stacks, symbol: "square.stack.3d.up.fill", tint: .controlAccentColor),
                Item(.containers, symbol: "shippingbox", tint: .controlAccentColor),
                Item(.images, symbol: "square.stack.3d.up", tint: .controlAccentColor),
                Item(.volumes, symbol: "externaldrive", tint: .systemPurple),
                Item(.networks, symbol: "point.3.connected.trianglepath.dotted", tint: .systemTeal),
                Item(.registries, symbol: "externaldrive.badge.person.crop", tint: .controlAccentColor)
            ]),
            Item("Development", children: [
                Item(.builds, symbol: "hammer", tint: .systemOrange),
                Item(.compose, symbol: "square.stack.3d.forward.dottedline", tint: .systemTeal),
                Item(.kubernetes, symbol: "circle.hexagongrid", tint: .systemOrange),
                Item(.machines, symbol: "desktopcomputer", tint: .systemPurple)
            ]),
            Item("Runtime", children: [
                Item(.logs, symbol: "text.alignleft", tint: .systemTeal),
                Item(.system, symbol: "gearshape.2", tint: .secondaryLabelColor),
                Item(.cleanup, symbol: "sparkles", tint: .systemMint),
                Item(.activity, symbol: "clock.arrow.circlepath", tint: .secondaryLabelColor)
            ]),
            Item("Local AI", children: [Item(.mlxModels, symbol: "cpu", tint: .systemIndigo)])
        ]

        init(selection: Binding<ContainerSection?>) { self.selection = selection }

        func row(for section: ContainerSection, in outline: NSOutlineView) -> Int {
            let item = groups.lazy.flatMap(\.children).first { $0.section == section }
            return item.map { outline.row(forItem: $0) } ?? -1
        }

        func applySelection(to outline: NSOutlineView) {
            let destination = selection.wrappedValue ?? .containers
            let row = row(for: destination, in: outline)
            guard outline.selectedRow != row else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            } else {
                outline.deselectAll(nil)
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let outline = notification.object as? NSOutlineView,
                  let item = outline.item(atRow: outline.selectedRow) as? Item,
                  let section = item.section, selection.wrappedValue != section else { return }
            selection.wrappedValue = section
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? groups.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? Item)?.children ?? groups)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Item)?.section == nil
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Item)?.section == nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Item)?.section != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            if let cell = item.cell { return cell }
            let cell = SidebarCell(item: item)
            item.cell = cell
            return cell
        }
    }

    private final class Item: NSObject {
        let title: String
        let section: ContainerSection?
        let symbol: String?
        let tint: NSColor
        let children: [Item]
        var cell: SidebarCell?

        init(_ title: String, children: [Item]) {
            self.title = title
            section = nil
            symbol = nil
            tint = .secondaryLabelColor
            self.children = children
        }

        init(_ section: ContainerSection, symbol: String, tint: NSColor) {
            title = section.title
            self.section = section
            self.symbol = symbol
            self.tint = tint
            children = []
        }
    }

    private final class SidebarCell: NSTableCellView {
        private let tint: NSColor

        init(item: Item) {
            tint = item.tint
            super.init(frame: .zero)
            identifier = NSUserInterfaceItemIdentifier(item.section?.rawValue ?? item.title)
            let label = NSTextField(labelWithString: item.title)
            label.font = item.section == nil
                ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                : .systemFont(ofSize: NSFont.systemFontSize)
            label.textColor = item.section == nil ? .secondaryLabelColor : .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            textField = label
            var leading = leadingAnchor
            var inset: CGFloat = 2
            if let symbol = item.symbol {
                let icon = NSImageView()
                icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                icon.contentTintColor = tint
                icon.translatesAutoresizingMaskIntoConstraints = false
                addSubview(icon)
                imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 20),
                    icon.heightAnchor.constraint(equalToConstant: 18)
                ])
                leading = icon.trailingAnchor
                inset = 7
            }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leading, constant: inset),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        required init?(coder: NSCoder) { return nil }

        override var backgroundStyle: NSView.BackgroundStyle {
            didSet {
                imageView?.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : tint
            }
        }
    }
}
