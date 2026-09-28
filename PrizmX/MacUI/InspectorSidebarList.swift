import AppKit
import SwiftUI

/// Inspector group column. Same AppKit source-list path as the main console
/// sidebar so collapse/expand keeps the accent highlight.
struct InspectorSidebarList: NSViewRepresentable {
    @Binding var selection: String
    var allTitle: String
    var allCount: Int
    var rows: [InspectorGroupRow]
    var grouping: InspectorGrouping

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
        // SwiftUI sets the scroll view frame directly on split-view drags;
        // the width mask keeps the column autoresizing chain engaged.
        outline.autoresizingMask = [.width]
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
        context.coordinator.apply(
            allTitle: allTitle,
            allCount: allCount,
            rows: rows,
            grouping: grouping,
            selection: selection,
            forceReload: true
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.apply(
            allTitle: allTitle,
            allCount: allCount,
            rows: rows,
            grouping: grouping,
            selection: selection,
            forceReload: false
        )
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
        var selection: Binding<String>
        weak var outline: SidebarOutlineView?
        var isActive = true
        var nodes: [Node] = []
        var grouping: InspectorGrouping = .app
        private var lastAllTitle = ""
        private var lastAllCount = -1
        private var lastRowIDs: [String] = []
        private var lastRowTitles: [String] = []
        private var lastRowCounts: [Int] = []

        init(selection: Binding<String>) {
            self.selection = selection
        }

        func apply(
            allTitle: String,
            allCount: Int,
            rows: [InspectorGroupRow],
            grouping: InspectorGrouping,
            selection: String,
            forceReload: Bool
        ) {
            self.grouping = grouping
            let nextIDs = rows.map(\.id)
            let nextTitles = rows.map(\.title)
            let nextCounts = rows.map(\.count)
            let unchanged = !forceReload
                && lastAllTitle == allTitle
                && lastAllCount == allCount
                && lastRowIDs == nextIDs
                && lastRowTitles == nextTitles
                && lastRowCounts == nextCounts
            if unchanged {
                applySelection(selection)
                return
            }
            let sameIDs = nodes.map(\.id) == ([""] + nextIDs)
            if !sameIDs || forceReload || nodes.isEmpty {
                nodes = [Node.all(title: allTitle, count: allCount)]
                    + rows.map { Node(row: $0) }
            } else {
                nodes[0].title = allTitle
                nodes[0].count = allCount
                for (index, row) in rows.enumerated() {
                    let node = nodes[index + 1]
                    node.title = row.title
                    node.count = row.count
                    node.bundleID = row.bundleID
                    node.executablePath = row.executablePath
                    node.placeholderSystemImage = row.placeholderSystemImage
                }
            }
            lastAllTitle = allTitle
            lastAllCount = allCount
            lastRowIDs = nextIDs
            lastRowTitles = nextTitles
            lastRowCounts = nextCounts
            // SwiftUI transactions (the App/Host capsule switch) leak their
            // animation into representable updates; keep the AppKit reload
            // instant so the list never trails the thumb animation.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                outline?.reloadData()
                applySelection(selection)
            }
        }

        func applySelection(_ id: String) {
            // See NativeSidebarList: select off-window so recreation does not
            // reset the selection to the auto-selected first row.
            guard isActive, let outline else { return }
            guard let node = nodes.first(where: { $0.id == id }) else { return }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            if outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            outline.refreshEmphasis()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? nodes.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            nodes[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let cell = outlineView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("inspector-item"),
                owner: nil
            ) as? InspectorSidebarCell ?? InspectorSidebarCell()
            cell.textField?.stringValue = node.title
            cell.countField.stringValue = "\(node.count)"
            cell.imageView?.image = icon(for: node)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard isActive, let outline, outline.window != nil, outline.selectedRow >= 0 else { return }
            guard let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
            if selection.wrappedValue != node.id {
                selection.wrappedValue = node.id
            }
        }

        private func icon(for node: Node) -> NSImage? {
            if node.id.isEmpty {
                return NSImage(systemSymbolName: "tray.2", accessibilityDescription: node.title)
            }
            if let placeholder = node.placeholderSystemImage {
                return NSImage(systemSymbolName: placeholder, accessibilityDescription: node.title)
            }
            if grouping == .app, node.title != "—",
               let image = AppIcon.resolvedNSImage(bundleID: node.bundleID, executablePath: node.executablePath) {
                return image
            }
            return NSImage(
                systemSymbolName: grouping == .app ? "app" : "globe",
                accessibilityDescription: node.title
            )
        }
    }

    final class Node: NSObject {
        let id: String
        var title: String
        var count: Int
        var bundleID: String?
        var executablePath: String?
        var placeholderSystemImage: String?

        init(
            id: String,
            title: String,
            count: Int,
            bundleID: String? = nil,
            executablePath: String? = nil,
            placeholderSystemImage: String? = nil
        ) {
            self.id = id
            self.title = title
            self.count = count
            self.bundleID = bundleID
            self.executablePath = executablePath
            self.placeholderSystemImage = placeholderSystemImage
        }

        static func all(title: String, count: Int) -> Node {
            Node(id: "", title: title, count: count)
        }

        convenience init(row: InspectorGroupRow) {
            self.init(
                id: row.id,
                title: row.title,
                count: row.count,
                bundleID: row.bundleID,
                executablePath: row.executablePath,
                placeholderSystemImage: row.placeholderSystemImage
            )
        }
    }
}

private final class InspectorSidebarCell: NSTableCellView {
    let countField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("inspector-item")

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: NSFont.systemFontSize)

        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countField.textColor = .secondaryLabelColor
        countField.alignment = .right
        countField.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(image)
        addSubview(field)
        addSubview(countField)
        imageView = image
        textField = field

        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
