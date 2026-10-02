import AppKit
import SwiftUI
import PrizmXServices

/// Inspector request table on `NSTableView`.
///
/// SwiftUI `Table` rebuilt the hosting views of every changed row on each 1s
/// poll; with a full history most visible rows are open flows whose bytes
/// move, so All Apps spent the main thread tearing views down. Here rows are
/// inserted / removed by ID and a changed row only gets its cell text reset.
struct InspectorRequestTable: NSViewRepresentable {
    var rows: [InspectorRequest]
    @Binding var selection: InspectorRequest.ID?
    @Binding var sortOrder: [KeyPathComparator<InspectorRequest>]

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, sortOrder: $sortOrder)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsTypeSelect = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for column in InspectorTableColumn.all {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            table.addTableColumn(tableColumn)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        context.coordinator.table = table
        context.coordinator.apply(rows: rows, selection: selection, sortOrder: sortOrder)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.sortOrder = $sortOrder
        context.coordinator.apply(rows: rows, selection: selection, sortOrder: sortOrder)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
        coordinator.table = nil
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selection: Binding<InspectorRequest.ID?>
        var sortOrder: Binding<[KeyPathComparator<InspectorRequest>]>
        weak var table: NSTableView?
        private var rows: [InspectorRequest] = []
        /// Set while rows, sort or selection are applied in code: AppKit
        /// reports those changes too, and only user actions may write back.
        private var isApplying = false

        init(
            selection: Binding<InspectorRequest.ID?>,
            sortOrder: Binding<[KeyPathComparator<InspectorRequest>]>
        ) {
            self.selection = selection
            self.sortOrder = sortOrder
        }

        func apply(rows next: [InspectorRequest], selection selected: InspectorRequest.ID?, sortOrder order: [KeyPathComparator<InspectorRequest>]) {
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }
            applySortIndicator(order, to: table)

            let old = rows
            rows = next
            let oldIDs = old.map(\.id)
            let nextIDs = next.map(\.id)
            if oldIDs != nextIDs {
                let diff = nextIDs.difference(from: oldIDs)
                // A re-sort or regroup moves most rows: reload (cells are
                // reused) instead of animating hundreds of moves.
                if old.isEmpty || diff.count > 200 {
                    table.reloadData()
                } else {
                    table.beginUpdates()
                    table.removeRows(at: Self.offsets(diff.removals), withAnimation: [])
                    table.insertRows(at: Self.offsets(diff.insertions), withAnimation: [])
                    table.endUpdates()
                }
            }
            refreshVisibleRows(in: table, comparedTo: old)
            applySelection(selected, to: table)
        }

        private static func offsets(_ changes: [CollectionDifference<UUID>.Change]) -> IndexSet {
            IndexSet(changes.map { change in
                switch change {
                case .insert(let offset, _, _), .remove(let offset, _, _): offset
                }
            })
        }

        /// Rows kept across the update whose values changed: reset the text of
        /// their visible cells. Off-screen rows are configured when shown.
        private func refreshVisibleRows(in table: NSTableView, comparedTo old: [InspectorRequest]) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for row in visible.location..<min(NSMaxRange(visible), rows.count) {
                let request = rows[row]
                guard let previous = oldByID[request.id], previous != request else { continue }
                for (index, tableColumn) in table.tableColumns.enumerated() {
                    guard let column = InspectorTableColumn.byID[tableColumn.identifier.rawValue],
                          let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? InspectorCellView
                    else { continue }
                    cell.configure(column, request)
                }
            }
        }

        private func applySelection(_ selected: InspectorRequest.ID?, to table: NSTableView) {
            guard let selected, let row = rows.firstIndex(where: { $0.id == selected }) else {
                if table.selectedRow >= 0 { table.deselectAll(nil) }
                return
            }
            if table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        private func applySortIndicator(_ order: [KeyPathComparator<InspectorRequest>], to table: NSTableView) {
            guard let first = order.first,
                  let column = InspectorTableColumn.all.first(where: { $0.keyPath == first.keyPath })
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
                  let column = InspectorTableColumn.byID[tableColumn.identifier.rawValue]
            else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? InspectorCellView
                ?? InspectorCellView(identifier: column.identifier, showsIcon: column.showsIcon)
            cell.configure(column, rows[row])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table else { return }
            let row = table.selectedRow
            let id = row >= 0 && row < rows.count ? rows[row].id : nil
            if selection.wrappedValue != id {
                selection.wrappedValue = id
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = InspectorTableColumn.byID[key]
            else { return }
            sortOrder.wrappedValue = [column.comparator(descriptor.ascending ? .forward : .reverse)]
        }
    }
}

/// One Inspector column: header, width, sort key and cell content.
struct InspectorTableColumn {
    let id: String
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
    let font: NSFont
    let secondary: Bool
    let showsIcon: Bool
    let keyPath: PartialKeyPath<InspectorRequest>
    let comparator: (SortOrder) -> KeyPathComparator<InspectorRequest>
    let text: (InspectorRequest) -> String

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(id) }

    private static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    static let all: [InspectorTableColumn] = [
        column("id", "ID", \.sortSerial, width: 50, font: digits, secondary: true) { $0.idLabel },
        column("time", "Time", \.timestamp, width: 150, font: digits) { $0.timeLabel },
        column("app", "App", \.appName, width: 160, minWidth: 120, showsIcon: true) { $0.appName },
        column("status", "Status", \.statusLabel, width: 90) { $0.statusLabel },
        column("policy", "Policy", \.routeLabel, width: 200, minWidth: 140) { $0.routeLabel },
        column("rule", "Rule", \.ruleLabel, width: 180, minWidth: 120, secondary: true) { $0.ruleLabel },
        column("down", "↓", \.downloadBytes, width: 70, font: digits) { ByteRateFormatter.byteCount($0.downloadBytes) },
        column("up", "↑", \.uploadBytes, width: 70, font: digits) { ByteRateFormatter.byteCount($0.uploadBytes) },
        column("duration", "Duration", \.sortDuration, width: 80, font: digits) { $0.durationLabel },
        column("protocol", "Protocol", \.protocolLabel, width: 70) { $0.protocolLabel },
        column("url", "URL", \.url, width: 320, minWidth: 160, font: mono) { $0.url },
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static func column<Value: Comparable>(
        _ id: String,
        _ title: String,
        _ keyPath: KeyPath<InspectorRequest, Value>,
        width: CGFloat,
        minWidth: CGFloat = 40,
        font: NSFont = body,
        secondary: Bool = false,
        showsIcon: Bool = false,
        text: @escaping (InspectorRequest) -> String
    ) -> InspectorTableColumn {
        InspectorTableColumn(
            id: id, title: title, width: width, minWidth: minWidth, font: font,
            secondary: secondary, showsIcon: showsIcon, keyPath: keyPath,
            comparator: { KeyPathComparator(keyPath, order: $0) },
            text: text
        )
    }

    /// Strings sort like Finder (`localizedStandard`), as SwiftUI `Table` did.
    private static func column(
        _ id: String,
        _ title: String,
        _ keyPath: KeyPath<InspectorRequest, String>,
        width: CGFloat,
        minWidth: CGFloat = 40,
        font: NSFont = body,
        secondary: Bool = false,
        showsIcon: Bool = false,
        text: @escaping (InspectorRequest) -> String
    ) -> InspectorTableColumn {
        InspectorTableColumn(
            id: id, title: title, width: width, minWidth: minWidth, font: font,
            secondary: secondary, showsIcon: showsIcon, keyPath: keyPath,
            comparator: { KeyPathComparator(keyPath, comparator: .localizedStandard, order: $0) },
            text: text
        )
    }
}

/// Plain AppKit cell: one label, plus a 16pt icon in the App column.
final class InspectorCellView: NSTableCellView {
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

    func configure(_ column: InspectorTableColumn, _ request: InspectorRequest) {
        if label.font != column.font { label.font = column.font }
        label.textColor = column.secondary ? .secondaryLabelColor : .labelColor
        label.stringValue = column.text(request)
        if let icon {
            icon.image = Self.icon(for: request)
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

    private static func icon(for request: InspectorRequest) -> NSImage? {
        if request.isLANClient {
            return NSImage(
                systemSymbolName: request.placeholderSystemImage ?? LANDevice.Kind.unknown.systemImage,
                accessibilityDescription: nil
            )
        }
        return AppIcon.resolvedNSImage(bundleID: request.appBundleID, executablePath: request.appExecutablePath)
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
    }
}
