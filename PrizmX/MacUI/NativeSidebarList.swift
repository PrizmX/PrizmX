import AppKit
import SwiftUI

/// AppKit source list. SwiftUI `List` is rebuilt when NavigationSplitView
/// collapses, and the new NSTableView never sees `didBecomeKey` — so the
/// accent highlight stays gray until the window cycles focus. This outline
/// view owns that refresh.
struct NativeSidebarList: NSViewRepresentable {
    @Binding var selection: SidebarItem

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.style = .sourceList
        outline.selectionHighlightStyle = .sourceList
        outline.headerView = nil
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.focusRingType = .none
        outline.backgroundColor = .clear
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        scroll.borderType = .noBorder

        context.coordinator.outline = outline
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        context.coordinator.applySelection(selection, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.applySelection(selection, force: false)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.isActive = false
        let outline = (scroll.documentView as? SidebarOutlineView) ?? coordinator.outline
        outline?.delegate = nil
        outline?.dataSource = nil
        outline?.tearDown()
        coordinator.outline = nil
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var selection: Binding<SidebarItem>
        weak var outline: SidebarOutlineView?
        var isActive = true

        let root: [Node] = Node.makeTree()

        init(selection: Binding<SidebarItem>) {
            self.selection = selection
        }

        func applySelection(_ item: SidebarItem, force: Bool) {
            guard isActive, let outline, outline.window != nil else { return }
            guard let node = findNode(item) else { return }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            if !force, outline.selectedRow == row { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        private func findNode(_ item: SidebarItem) -> Node? {
            for node in root {
                if node.item == item { return node }
                if let child = node.children.first(where: { $0.item == item }) {
                    return child
                }
            }
            return nil
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return root.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let children = (item as? Node)?.children ?? root
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            ((item as? Node)?.children.isEmpty) == false
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Node)?.isGroup == true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? Node, let item = node.item else { return false }
            return item.isEnabled
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            if node.isGroup {
                let cell = outlineView.makeView(
                    withIdentifier: NSUserInterfaceItemIdentifier("group"),
                    owner: nil
                ) as? NSTableCellView ?? makeGroupCell()
                cell.textField?.stringValue = node.title
                return cell
            }
            let cell = outlineView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("item"),
                owner: nil
            ) as? NSTableCellView ?? makeItemCell()
            guard let item = node.item else { return cell }
            cell.textField?.stringValue = item.title
            cell.textField?.textColor = item.isEnabled ? .labelColor : .secondaryLabelColor
            cell.imageView?.image = NSImage(
                systemSymbolName: item.systemImage,
                accessibilityDescription: item.title
            )
            cell.imageView?.contentTintColor = item.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard isActive, let outline, outline.window != nil, outline.selectedRow >= 0 else { return }
            guard let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
            guard let item = node.item, item.isEnabled else { return }
            if selection.wrappedValue != item {
                selection.wrappedValue = item
            }
        }

        private func makeItemCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("item")
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            cell.addSubview(image)
            cell.addSubview(field)
            cell.imageView = image
            cell.textField = field
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func makeGroupCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("group")
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = .systemFont(ofSize: 11, weight: .semibold)
            field.textColor = .secondaryLabelColor
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
    }

    final class Node: NSObject {
        let title: String
        let item: SidebarItem?
        let children: [Node]
        var isGroup: Bool { item == nil }

        init(title: String, item: SidebarItem?, children: [Node] = []) {
            self.title = title
            self.item = item
            self.children = children
        }

        static func makeTree() -> [Node] {
            [
                Node(title: SidebarItem.home.title, item: .home),
                Node(title: "SOURCES", item: nil, children: [
                    Node(title: SidebarItem.apps.title, item: .apps),
                    Node(title: SidebarItem.lan.title, item: .lan)
                ]),
                Node(title: "ROUTING", item: nil, children: [
                    Node(title: SidebarItem.profiles.title, item: .profiles),
                    Node(title: SidebarItem.policies.title, item: .policies),
                    Node(title: SidebarItem.rules.title, item: .rules)
                ]),
                Node(title: "ADVANCED", item: nil, children: [
                    Node(title: SidebarItem.module.title, item: .module),
                    Node(title: SidebarItem.scripts.title, item: .scripts)
                ]),
                Node(title: "SYSTEM", item: nil, children: [
                    Node(title: SidebarItem.settings.title, item: .settings),
                    Node(title: SidebarItem.events.title, item: .events)
                ])
            ]
        }
    }
}

final class SidebarOutlineView: NSOutlineView {
    func tearDown() {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            NotificationCenter.default.removeObserver(self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowKeyChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowKeyChanged),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        refreshEmphasis()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowKeyChanged() {
        refreshEmphasis()
    }

    func refreshEmphasis() {
        guard window != nil else { return }
        let emphasized = window?.isKeyWindow ?? false
        enumerateAvailableRowViews { rowView, _ in
            if rowView.isEmphasized != emphasized {
                rowView.isEmphasized = emphasized
            }
        }
        needsDisplay = true
    }
}
