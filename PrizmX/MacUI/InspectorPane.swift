import AppKit
import SwiftUI
import PrizmXServices

struct InspectorRequest: Identifiable, Hashable, Sendable {
    var id: UUID
    var serial: UInt64?
    var timestamp: Date
    var appName: String
    var appBundleID: String?
    var appExecutablePath: String?
    var closed: Bool
    var policy: String
    var rule: String
    var uploadBytes: UInt64
    var downloadBytes: UInt64
    var url: String
    var milliseconds: Int
    var clientEnd: String
    var remoteEnd: String
    var port: UInt16
    var isLANClient: Bool
    var lanAddress: String?
    var placeholderSystemImage: String?

    init(flow: FlowRecord, lanDevice: LANDevice? = nil) {
        id = flow.id
        serial = flow.serial
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
        policy = flow.via
        rule = flow.rule
        uploadBytes = flow.uplinkBytes
        downloadBytes = flow.downlinkBytes
        url = flow.endpoint.description
        milliseconds = flow.milliseconds
        clientEnd = flow.clientEnd
        remoteEnd = flow.remoteEnd
        port = flow.endpoint.port
    }

    var idLabel: String {
        serial.map { "\($0)" } ?? "—"
    }

    /// Stable Apps / Inspector grouping key (bundle ID when present).
    var accountingKey: String {
        if let lanAddress { return "lan:\(lanAddress)" }
        if let appBundleID, !appBundleID.isEmpty { return appBundleID }
        return appName
    }

    /// Host without port, for Host grouping.
    var hostLabel: String {
        if url.hasPrefix("["), let end = url.firstIndex(of: "]") {
            return String(url[url.startIndex...end])
        }
        if let colon = url.lastIndex(of: ":"), colon > url.startIndex {
            return String(url[..<colon])
        }
        return url
    }

    var timeLabel: String {
        timestamp.formatted(date: .numeric, time: .standard)
    }

    /// Close reason mapped for the table. Raw `eof` is Completed.
    var statusLabel: String {
        if !closed { return "Active" }
        if clientEnd == "write-error" || remoteEnd == "error" { return "Failed" }
        return "Completed"
    }

    var policyLabel: String {
        let match = Self.ruleMatchLabel(rule)
        if match.isEmpty { return policy }
        return "\(policy) (\(match))"
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

    var protocolLabel: String {
        switch port {
        case 443, 8443: "HTTPS"
        case 80, 8080: "HTTP"
        default: "TCP"
        }
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
        .onChange(of: appModel.inspectorGrouping) { _, _ in
            appModel.inspectorSelectedGroup = ""
        }
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
            allCount: appModel.inspectorRequests.count,
            rows: appModel.inspectorGroupRows,
            grouping: appModel.inspectorGrouping
        )
        .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
        .safeAreaBar(edge: .top) {
            CapsuleSegmentedControl(
                options: InspectorGrouping.allCases,
                selection: $appModel.inspectorGrouping,
                title: \.title
            )
            .frame(maxWidth: .infinity)
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
    @State private var sortOrder: [KeyPathComparator<InspectorRequest>] = [
        KeyPathComparator(\InspectorRequest.timestamp, order: .reverse)
    ]

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
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", systemImage: "xmark.circle") {
                        appModel.clearInspector()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(
                        appModel.inspectorScope == .active
                            || appModel.inspectorRecentFlows.isEmpty
                    )
                    .help("Clear recent flows")
                }
                // Break the pill group: without a spacer the Clear button and
                // the search field are rendered as one capsule.
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    ToolbarSearchField(text: $appModel.inspectorFilter, prompt: "Filter")
                }
            }
    }

    private var requestTable: some View {
        Table(
            displayedRequests.sorted(using: sortOrder),
            selection: Binding(
                get: { appModel.selectedInspectorRequestID },
                set: { appModel.selectedInspectorRequestID = $0 }
            ),
            sortOrder: $sortOrder
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
            TableColumn("Policy", value: \.policyLabel) { item in
                Text(item.policyLabel)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 180)
            TableColumn("↓", value: \.downloadBytes) { item in
                Text(ByteRateFormatter.byteCount(item.downloadBytes))
                    .font(.body.monospacedDigit())
            }
            .width(70)
            TableColumn("↑", value: \.uploadBytes) { item in
                Text(ByteRateFormatter.byteCount(item.uploadBytes))
                    .font(.body.monospacedDigit())
            }
            .width(70)
            TableColumn("Duration", value: \.sortDuration) { item in
                Text(item.durationLabel)
                    .font(.body.monospacedDigit())
            }
            .width(80)
            TableColumn("Protocol", value: \.protocolLabel) { item in
                Text(item.protocolLabel)
            }
            .width(70)
            TableColumn("URL", value: \.url) { item in
                Text(item.url)
                    .font(.body.monospaced())
                    .lineLimit(1)
            }
        }
        .tableStyle(.inset)
        .overlay {
            if displayedRequests.isEmpty {
                ContentUnavailableView {
                    Label("No Requests", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(emptyDescription)
                }
            }
        }
    }

    private var displayedRequests: [InspectorRequest] {
        let rows = appModel.inspectorRequests
        let selected = appModel.inspectorSelectedGroup
        guard !selected.isEmpty else { return rows }
        return rows.filter {
            let key = appModel.inspectorGrouping == .app ? $0.accountingKey : $0.hostLabel
            return key == selected
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
