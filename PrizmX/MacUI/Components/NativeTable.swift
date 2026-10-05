import AppKit
import SwiftUI

/// Text table on `NSTableView`, for lists too large or too live for SwiftUI
/// `Table`.
///
/// SwiftUI `Table` re-renders row hosting views whenever the rows change and
/// diffs the whole array on every body pass. Here rows are inserted / removed
/// by ID, a changed row only gets the text of its visible cells reset, and
/// an unchanged array is a no-op. Columns are fixed once the table is made.
struct NativeTable<Row: Identifiable & Equatable>: View {
    var rows: [Row]
    var columns: [NativeTableColumn<Row>]
    @Binding var selection: Row.ID?
    /// `nil` keeps the rows in the given order (headers do not sort).
    var sortOrder: Binding<[KeyPathComparator<Row>]>?
    /// Items for a right-clicked row; empty shows no menu.
    var contextMenu: ((Row) -> [NativeTableMenuItem])?
    /// Runs on a double-clicked row.
    var primaryAction: ((Row) -> Void)?

    init(
        rows: [Row],
        columns: [NativeTableColumn<Row>],
        selection: Binding<Row.ID?>,
        sortOrder: Binding<[KeyPathComparator<Row>]>? = nil,
        contextMenu: ((Row) -> [NativeTableMenuItem])? = nil,
        primaryAction: ((Row) -> Void)? = nil
    ) {
        self.rows = rows
        self.columns = columns
        _selection = selection
        self.sortOrder = sortOrder
        self.contextMenu = contextMenu
        self.primaryAction = primaryAction
    }

    var body: some View {
        // Like SwiftUI `Table`: the scroll view runs under the toolbar and
        // AppKit insets it from the window's content layout rect, so the
        // header sits in the toolbar's scroll edge effect and rows scroll
        // beneath it. Below the safe area the header draws its own opaque
        // background, which does not match the toolbar. No effect where the
        // table does not touch the top edge.
        Representable(table: self)
            .ignoresSafeArea(.container, edges: .top)
    }

    private struct Representable: NSViewRepresentable {
        var table: NativeTable

        func makeCoordinator() -> Coordinator {
            Coordinator(table)
        }

        func makeNSView(context: Context) -> NSScrollView {
            table.makeScrollView(coordinator: context.coordinator)
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.apply(table)
        }

        static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
            coordinator.table?.menu?.delegate = nil
            coordinator.table?.target = nil
            coordinator.table?.delegate = nil
            coordinator.table?.dataSource = nil
            coordinator.table = nil
        }
    }

    private func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsTypeSelect = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for column in columns {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.resizingMask = column.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if sortOrder != nil, column.sort != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            }
            table.addTableColumn(tableColumn)
        }
        table.delegate = coordinator
        table.dataSource = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.performPrimaryAction(_:))
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        coordinator.table = table
        coordinator.apply(self)
        return scroll
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        /// More inserted + removed rows than this reload instead.
        private static var maxIncrementalChanges: Int { 200 }

        weak var table: NSTableView?
        private var parent: NativeTable
        private var columnsByID: [String: NativeTableColumn<Row>]
        private var rows: [Row] = []
        private var menuActions: [() -> Void] = []
        /// Set while rows, sort or selection are applied in code: AppKit
        /// reports those changes too, and only user actions may write back.
        private var isApplying = false

        init(_ parent: NativeTable) {
            self.parent = parent
            columnsByID = Dictionary(parent.columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        func apply(_ next: NativeTable) {
            parent = next
            columnsByID = Dictionary(next.columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }
            if let order = next.sortOrder?.wrappedValue {
                applySortIndicator(order, to: table)
            }
            // Same storage compares in O(1): a body pass that did not touch
            // the rows costs nothing here.
            if next.rows != rows {
                let old = rows
                rows = next.rows
                updateRows(in: table, from: old)
            }
            applySelection(next.selection, to: table)
        }

        private func updateRows(in table: NSTableView, from old: [Row]) {
            let oldIDs = old.map(\.id)
            let nextIDs = rows.map(\.id)
            if oldIDs == nextIDs {
                refreshVisibleRows(in: table) { old[$0] }
                return
            }
            guard let change = Self.change(from: oldIDs, to: nextIDs) else {
                // A re-sort, regroup or refilter moves most rows: reload
                // (only visible cells are made, and they are reused).
                table.reloadData()
                return
            }
            table.beginUpdates()
            table.removeRows(at: change.removals, withAnimation: [])
            table.insertRows(at: change.insertions, withAnimation: [])
            table.endUpdates()
            let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            refreshVisibleRows(in: table) { [rows] in oldByID[rows[$0].id] }
        }

        /// Removals and insertions that turn `old` into `next`, when the
        /// rows kept stay in order and only a few rows change; `nil` means
        /// reload. Linear, unlike `difference(from:)`, whose cost grows with
        /// the number of changes and stalls on a refilter of a long list.
        private static func change(from old: [Row.ID], to next: [Row.ID]) -> (removals: IndexSet, insertions: IndexSet)? {
            guard !old.isEmpty else { return nil }
            let oldSet = Set(old)
            let nextSet = Set(next)
            var removals = IndexSet()
            var kept: [Row.ID] = []
            kept.reserveCapacity(old.count)
            for (offset, id) in old.enumerated() {
                if nextSet.contains(id) {
                    kept.append(id)
                } else {
                    removals.insert(offset)
                }
            }
            var insertions = IndexSet()
            var keptIndex = 0
            for (offset, id) in next.enumerated() {
                if oldSet.contains(id) {
                    guard keptIndex < kept.count, kept[keptIndex] == id else { return nil }
                    keptIndex += 1
                } else {
                    insertions.insert(offset)
                }
            }
            guard removals.count + insertions.count <= maxIncrementalChanges else { return nil }
            return (removals, insertions)
        }

        /// Rows kept across the update whose values changed: reset the text of
        /// their visible cells. Off-screen rows are configured when shown.
        private func refreshVisibleRows(in table: NSTableView, previous: (Int) -> Row?) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<min(NSMaxRange(visible), rows.count) {
                let current = rows[row]
                guard let before = previous(row), before != current else { continue }
                for (index, tableColumn) in table.tableColumns.enumerated() {
                    guard let column = columnsByID[tableColumn.identifier.rawValue],
                          let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? NativeTableCellView
                    else { continue }
                    cell.configure(column, current)
                }
            }
        }

        private func applySelection(_ selected: Row.ID?, to table: NSTableView) {
            let current = table.selectedRow
            if let selected, current >= 0, current < rows.count, rows[current].id == selected { return }
            guard let selected, let row = rows.firstIndex(where: { $0.id == selected }) else {
                if current >= 0 { table.deselectAll(nil) }
                return
            }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        private func applySortIndicator(_ order: [KeyPathComparator<Row>], to table: NSTableView) {
            guard let first = order.first,
                  let column = parent.columns.first(where: { $0.sort?.keyPath == first.keyPath })
            else { return }
            let descriptor = NSSortDescriptor(key: column.id, ascending: first.order == .forward)
            if table.sortDescriptors != [descriptor] {
                table.sortDescriptors = [descriptor]
            }
        }

        // MARK: NSTableViewDataSource / NSTableViewDelegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count,
                  let column = columnsByID[tableColumn.identifier.rawValue]
            else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NativeTableCellView
                ?? NativeTableCellView(identifier: column.identifier, showsIcon: column.icon != nil)
            cell.configure(column, rows[row])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table else { return }
            let row = table.selectedRow
            let id = row >= 0 && row < rows.count ? rows[row].id : nil
            if parent.selection != id {
                parent.selection = id
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying,
                  let sortOrder = parent.sortOrder,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let sort = columnsByID[key]?.sort
            else { return }
            sortOrder.wrappedValue = [sort.comparator(descriptor.ascending ? .forward : .reverse)]
        }

        @objc func performPrimaryAction(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard let primaryAction = parent.primaryAction, row >= 0, row < rows.count else { return }
            primaryAction(rows[row])
        }

        // MARK: NSMenuDelegate

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menuActions = []
            guard let table, let contextMenu = parent.contextMenu,
                  table.clickedRow >= 0, table.clickedRow < rows.count
            else { return }
            for item in contextMenu(rows[table.clickedRow]) {
                let menuItem = NSMenuItem(title: item.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = menuActions.count
                menuActions.append(item.action)
                menu.addItem(menuItem)
            }
        }

        @objc private func performMenuItem(_ sender: NSMenuItem) {
            guard menuActions.indices.contains(sender.tag) else { return }
            menuActions[sender.tag]()
        }
    }
}

/// One column: header, width, cell text and style, and an optional sort key.
struct NativeTableColumn<Row> {
    let id: String
    let title: String
    var width: CGFloat
    var minWidth: CGFloat
    /// Takes the width the table gains or loses when it resizes.
    var flexible: Bool
    var font: NSFont
    var color: (Row) -> NSColor
    /// A 16pt icon before the text.
    var icon: ((Row) -> NSImage?)?
    var sort: NativeTableSortKey<Row>?
    var text: (Row) -> String

    init(
        _ id: String,
        _ title: String,
        width: CGFloat,
        minWidth: CGFloat = 40,
        flexible: Bool = false,
        font: NSFont = NativeTableFont.body,
        color: @escaping (Row) -> NSColor = { _ in .labelColor },
        icon: ((Row) -> NSImage?)? = nil,
        sort: NativeTableSortKey<Row>? = nil,
        text: @escaping (Row) -> String
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.flexible = flexible
        self.font = font
        self.color = color
        self.icon = icon
        self.sort = sort
        self.text = text
    }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(id) }
}

/// How a column sorts: the key path matched against the bound sort order,
/// and the comparator a header click writes back.
struct NativeTableSortKey<Row> {
    let keyPath: PartialKeyPath<Row>
    let comparator: (SortOrder) -> KeyPathComparator<Row>

    static func by<Value: Comparable>(_ keyPath: KeyPath<Row, Value>) -> Self {
        Self(keyPath: keyPath) { KeyPathComparator(keyPath, order: $0) }
    }

    /// Strings sort like Finder (`localizedStandard`), as SwiftUI `Table` did.
    static func by(_ keyPath: KeyPath<Row, String>) -> Self {
        Self(keyPath: keyPath) { KeyPathComparator(keyPath, comparator: .localizedStandard, order: $0) }
    }
}

enum NativeTableFont {
    static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
}

/// A context-menu command for one row.
struct NativeTableMenuItem {
    var title: String
    var action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// Plain AppKit cell: one label, plus a 16pt icon when the column has one.
final class NativeTableCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon: NSImageView?

    init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) {
        icon = showsIcon ? NSImageView() : nil
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        if let icon {
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure<Row>(_ column: NativeTableColumn<Row>, _ row: Row) {
        if label.font != column.font { label.font = column.font }
        label.textColor = column.color(row)
        label.stringValue = column.text(row)
        if let icon, let image = column.icon {
            icon.image = image(row)
            icon.contentTintColor = .secondaryLabelColor
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if let icon {
            icon.frame = NSRect(x: 0, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
            x = 22
        }
        let height = label.cell?.cellSize.height ?? 16
        label.frame = NSRect(
            x: x,
            y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - x),
            height: height
        )
    }
}
