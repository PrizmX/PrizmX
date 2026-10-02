import AppKit
import SwiftUI
import PrizmXServices

struct InspectorRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let serial: UInt64?
    let timestamp: Date
    let appName: String
    let appBundleID: String?
    let appExecutablePath: String?
    let closed: Bool
    let route: FlowRoute
    let rule: String
    let uploadBytes: UInt64
    let downloadBytes: UInt64
    let url: String
    let milliseconds: Int
    let clientEnd: String
    let remoteEnd: String
    let port: UInt16
    let isLANClient: Bool
    let lanAddress: String?
    let placeholderSystemImage: String?
    // Built once per row: filter, grouping and sort read these for every row
    // on each refresh, and the table for every visible cell.
    let idLabel: String
    let timeLabel: String
    /// Close reason mapped for the table. Raw `eof` is Completed.
    let statusLabel: String
    /// Rule policy to exit: `🎯Direct → DIRECT`, `AI → 🇺🇸 San Jose 07`.
    let routeLabel: String
    /// Matched rule without its policy: `DOMAIN-SUFFIX,claude.ai`.
    let ruleLabel: String
    let protocolLabel: String
    /// Stable Apps / Inspector grouping key (bundle ID when present).
    let accountingKey: String
    /// Host without port, for Host grouping.
    let hostLabel: String
    private let searchText: String

    /// `fallbackSerial` numbers flows from tunnels that send none.
    init(flow: FlowRecord, lanDevice: LANDevice? = nil, fallbackSerial: UInt64? = nil) {
        id = flow.id
        serial = flow.serial ?? fallbackSerial
        timestamp = flow.startedAt
        if let lanDevice {
            appName = lanDevice.name
            appBundleID = nil
            appExecutablePath = nil
            isLANClient = true
            lanAddress = lanDevice.address
            placeholderSystemImage = lanDevice.kind.systemImage
        } else if let host = AppModel.lanClientAddress(flow.sourceHost) {
            appName = host
            appBundleID = nil
            appExecutablePath = nil
            isLANClient = true
            lanAddress = host
            placeholderSystemImage = LANDevice.Kind.unknown.systemImage
        } else {
            appName = flow.attribution?.processName ?? "—"
            appBundleID = flow.attribution?.bundleID
            appExecutablePath = flow.attribution?.executablePath
            isLANClient = false
            lanAddress = nil
            placeholderSystemImage = nil
        }
        closed = flow.closed
        route = flow.route
        rule = flow.rule
        uploadBytes = flow.uplinkBytes
        downloadBytes = flow.downlinkBytes
        url = flow.endpoint.description
        milliseconds = flow.milliseconds
        clientEnd = flow.clientEnd
        remoteEnd = flow.remoteEnd
        port = flow.endpoint.port

        idLabel = serial.map { "\($0)" } ?? "—"
        timeLabel = timestamp.formatted(date: .numeric, time: .standard)
        if !closed {
            statusLabel = "Active"
        } else if clientEnd == "write-error" || remoteEnd == "error" {
            statusLabel = "Failed"
        } else {
            statusLabel = "Completed"
        }
        routeLabel = route.description
        let match = Self.ruleMatchLabel(rule)
        ruleLabel = match.isEmpty ? "—" : match
        switch port {
        case 443, 8443: protocolLabel = "HTTPS"
        case 80, 8080: protocolLabel = "HTTP"
        default: protocolLabel = "TCP"
        }
        if let lanAddress {
            accountingKey = "lan:\(lanAddress)"
        } else if let appBundleID, !appBundleID.isEmpty {
            accountingKey = appBundleID
        } else {
            accountingKey = appName
        }
        hostLabel = Self.host(of: url)
        searchText = [url, appName, routeLabel, ruleLabel, statusLabel, protocolLabel, idLabel].joined(separator: "\n")
    }

    /// Filter field match (case-insensitive) on URL, app, route, rule,
    /// status, protocol or ID.
    func matches(_ query: String) -> Bool {
        searchText.localizedCaseInsensitiveContains(query)
    }

    private static func host(of url: String) -> String {
        if url.hasPrefix("["), let end = url.firstIndex(of: "]") {
            return String(url[url.startIndex...end])
        }
        if let colon = url.lastIndex(of: ":"), colon > url.startIndex {
            return String(url[..<colon])
        }
        return url
    }

    /// `TYPE,payload,policy` from `inspectorLabel` — drop the trailing policy,
    /// which already appears outside the parentheses.
    private static func ruleMatchLabel(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let comma = trimmed.lastIndex(of: ",") else { return trimmed }
        return String(trimmed[..<comma])
    }

    var sortSerial: UInt64 { serial ?? 0 }

    var sortDuration: Int { durationMilliseconds }

    var durationLabel: String {
        let ms = durationMilliseconds
        if ms < 1 { return "—" }
        if ms < 1_000 { return "\(ms) ms" }
        if ms < 60_000 {
            return ms.isMultiple(of: 1_000) ? "\(ms / 1_000) s" : String(format: "%.1f s", Double(ms) / 1_000)
        }
        let seconds = ms / 1_000
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private var durationMilliseconds: Int {
        if milliseconds > 0 { return milliseconds }
        if !closed {
            return max(0, Int(Date().timeIntervalSince(timestamp) * 1_000))
        }
        return milliseconds
    }
}

struct InspectorGroupRow: Identifiable, Hashable {
    var id: String
    var title: String
    var count: Int
    var bundleID: String?
    var executablePath: String?
    var placeholderSystemImage: String?
}

/// Request inspector: group list + request table.
struct InspectorPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var isSidebarCollapsed: Bool {
        columnVisibility == .detailOnly
    }

    var body: some View {
        // Same toggle as the main window: the system button stays in the
        // sidebar while it is open. Only the collapsed state uses a custom
        // one, so the system button is not moved across the divider.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            groupSidebar
                .hidingSystemSidebarToggle(isSidebarCollapsed)
        } detail: {
            InspectorDetail()
        }
        .toolbar {
            if isSidebarCollapsed {
                ToolbarItem(placement: .navigation) {
                    sidebarToggleButton
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var sidebarToggleButton: some View {
        Button("Toggle Sidebar", systemImage: "sidebar.left") {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
        .labelStyle(.iconOnly)
        .help("Toggle Sidebar")
    }

    private var groupSidebar: some View {
        @Bindable var appModel = appModel
        return InspectorSidebarList(
            selection: $appModel.inspectorSelectedGroup,
            allTitle: allGroupTitle,
            allCount: appModel.inspectorAllCount,
            rows: appModel.inspectorGroupRows,
            grouping: appModel.inspectorGrouping
        )
        .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
        .safeAreaBar(edge: .top) {
            AppSegmentedControl(
                options: InspectorGrouping.allCases.map { ($0, $0.title) },
                selection: $appModel.inspectorGrouping,
                size: .small,
                fill: true
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var allGroupTitle: String {
        appModel.inspectorGrouping == .app ? "All Apps" : "All Hosts"
    }

}

/// Detail column. Kept separate so sidebar collapse does not re-render it.
private struct InspectorDetail: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        requestTable
            .navigationTitle("Inspector")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Scope", selection: $appModel.inspectorScope) {
                        ForEach(InspectorScope.allCases) { scope in
                            Label(scope.title, systemImage: scope.systemImage)
                                .tag(scope)
                                .help(scope.title)
                        }
                    }
                    .appToolbarSegmentedStyle()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", systemImage: "xmark.circle") {
                        appModel.clearInspector()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(
                        appModel.inspectorScope == .active
                            || !appModel.inspectorFlows.contains(where: \.closed)
                    )
                    .help("Clear finished requests")
                }
                // Break the pill group: without a spacer the Clear button and
                // the search field are rendered as one capsule.
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    ToolbarSearchField(text: $appModel.inspectorFilter, prompt: "Filter")
                }
            }
    }

    /// Rows come filtered, grouped and sorted from the model; the view does no
    /// per-row work beyond the visible cells.
    private var requestTable: some View {
        Table(
            appModel.inspectorRows,
            selection: Binding(
                get: { appModel.selectedInspectorRequestID },
                set: { appModel.selectedInspectorRequestID = $0 }
            ),
            sortOrder: Binding(
                get: { appModel.inspectorSortOrder },
                set: { appModel.inspectorSortOrder = $0 }
            )
        ) {
            TableColumn("ID", value: \.sortSerial) { (item: InspectorRequest) in
                Text(item.idLabel)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(50)
            TableColumn("Time", value: \.timestamp) { item in
                Text(item.timeLabel)
                    .font(.body.monospacedDigit())
                    .lineLimit(1)
            }
            .width(150)
            TableColumn("App", value: \.appName) { item in
                HStack(spacing: 6) {
                    if item.isLANClient {
                        Image(systemName: item.placeholderSystemImage ?? LANDevice.Kind.unknown.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    } else {
                        AppIconView(
                            bundleID: item.appBundleID,
                            executablePath: item.appExecutablePath,
                            size: 16
                        )
                    }
                    Text(item.appName)
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Status", value: \.statusLabel) { item in
                Text(item.statusLabel)
            }
            .width(90)
            TableColumn("Policy", value: \.routeLabel) { item in
                Text(item.routeLabel)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Rule", value: \.ruleLabel) { item in
                Text(item.ruleLabel)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 180)
            // A column builder takes at most 10 columns; group the numbers.
            Group {
                TableColumn("↓", value: \InspectorRequest.downloadBytes) { (item: InspectorRequest) in
                    Text(ByteRateFormatter.byteCount(item.downloadBytes))
                        .font(.body.monospacedDigit())
                }
                .width(70)
                TableColumn("↑", value: \InspectorRequest.uploadBytes) { (item: InspectorRequest) in
                    Text(ByteRateFormatter.byteCount(item.uploadBytes))
                        .font(.body.monospacedDigit())
                }
                .width(70)
                TableColumn("Duration", value: \InspectorRequest.sortDuration) { (item: InspectorRequest) in
                    Text(item.durationLabel)
                        .font(.body.monospacedDigit())
                }
                .width(80)
                TableColumn("Protocol", value: \InspectorRequest.protocolLabel) { (item: InspectorRequest) in
                    Text(item.protocolLabel)
                }
                .width(70)
            }
            TableColumn("URL", value: \.url) { item in
                Text(item.url)
                    .font(.body.monospaced())
                    .lineLimit(1)
            }
        }
        .tableStyle(.inset)
        .overlay {
            if appModel.inspectorRows.isEmpty {
                ContentUnavailableView {
                    Label("No Requests", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(emptyDescription)
                }
            }
        }
    }

    private var emptyDescription: String {
        if !appModel.inspectorSelectedGroup.isEmpty {
            return "No requests in this group."
        }
        return appModel.inspectorScope == .active
            ? "Active flows will appear here once the tunnel reports connections."
            : "Recent requests will appear here once the tunnel reports connections."
    }

}

#Preview("Inspector") {
    InspectorPane()
        .environment(AppModel.preview)
        .frame(width: 980, height: 640)
}
