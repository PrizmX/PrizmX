import SwiftUI
import PrizmXServices

/// Request inspector: group list + table + system inspector for the selected row.
struct InspectorPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var sortOrder: [KeyPathComparator<InspectorRequest>] = [
        KeyPathComparator(\InspectorRequest.timestamp, order: .reverse)
    ]
    /// Empty string is All Apps / All Hosts.
    @State private var selectedGroup = ""

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            groupSidebar
        } detail: {
            requestTable
                .navigationTitle("Inspector")
                .toolbarRole(.editor)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ToolbarIconPicker(
                            selection: $appModel.inspectorScope,
                            items: InspectorScope.allCases.map {
                                .init(value: $0, title: $0.title, systemImage: $0.systemImage)
                            }
                        )
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear", systemImage: "trash") {
                            appModel.clearInspector()
                        }
                        .labelStyle(.iconOnly)
                        .disabled(
                            appModel.inspectorScope == .active
                                || appModel.inspectorRecentFlows.isEmpty
                        )
                        .help("Clear recent flows")
                    }
                }
        }
        .searchable(text: $appModel.inspectorFilter, prompt: "Filter")
        .inspector(isPresented: detailPresented) {
            requestInspector
        }
        .onChange(of: appModel.inspectorGrouping) { _, _ in
            selectedGroup = ""
        }
        .onChange(of: groupKeys) { _, keys in
            if !selectedGroup.isEmpty, !keys.contains(selectedGroup) {
                selectedGroup = ""
            }
        }
    }

    private var groupSidebar: some View {
        @Bindable var appModel = appModel
        return List(selection: $selectedGroup) {
            Label(allGroupTitle, systemImage: "tray.2")
                .badge(appModel.inspectorRequests.count)
                .tag("")
            ForEach(namedGroups) { row in
                Label {
                    Text(row.title)
                        .lineLimit(1)
                } icon: {
                    groupIcon(row)
                }
                .badge(row.count)
                .tag(row.id)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
        .safeAreaBar(edge: .top) {
            Picker("Group", selection: $appModel.inspectorGrouping) {
                ForEach(InspectorGrouping.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
                    if item.appName != "—" {
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

    @ViewBuilder
    private var requestInspector: some View {
        if let request = appModel.selectedInspectorRequest {
            Form {
                Section {
                    LabeledContent("App", value: request.appName)
                    LabeledContent("URL", value: request.url)
                    LabeledContent("Status", value: request.statusLabel)
                    LabeledContent("Policy", value: request.policyLabel)
                    LabeledContent("Protocol", value: request.protocolLabel)
                    LabeledContent("Duration", value: request.durationLabel)
                    LabeledContent("Client", value: request.clientEnd)
                    LabeledContent("Remote", value: request.remoteEnd)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("Request", systemImage: "doc.plaintext")
            } description: {
                Text("Select a request to inspect policy and timing.")
            }
        }
    }

    private var displayedRequests: [InspectorRequest] {
        let rows = appModel.inspectorRequests
        guard !selectedGroup.isEmpty else { return rows }
        return rows.filter { $0.groupKey(appModel.inspectorGrouping) == selectedGroup }
    }

    private var namedGroups: [InspectorGroupRow] {
        var counts: [String: Int] = [:]
        var icons: [String: (bundleID: String?, path: String?)] = [:]
        for request in appModel.inspectorRequests {
            let key = request.groupKey(appModel.inspectorGrouping)
            counts[key, default: 0] += 1
            if icons[key] == nil {
                icons[key] = (request.appBundleID, request.appExecutablePath)
            }
        }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            InspectorGroupRow(
                id: key,
                title: key,
                count: counts[key] ?? 0,
                bundleID: icons[key]?.bundleID,
                executablePath: icons[key]?.path
            )
        }
    }

    private var groupKeys: Set<String> {
        Set(namedGroups.map(\.id))
    }

    private var allGroupTitle: String {
        appModel.inspectorGrouping == .app ? "All Apps" : "All Hosts"
    }

    private var emptyDescription: String {
        if !selectedGroup.isEmpty {
            return "No requests in this group."
        }
        return appModel.inspectorScope == .active
            ? "Active flows will appear here once the tunnel reports connections."
            : "Recent requests will appear here once the tunnel reports connections."
    }

    @ViewBuilder
    private func groupIcon(_ row: InspectorGroupRow) -> some View {
        if appModel.inspectorGrouping == .app, row.title != "—" {
            AppIconView(bundleID: row.bundleID, executablePath: row.executablePath, size: 16)
        } else {
            Image(systemName: appModel.inspectorGrouping == .app ? "app" : "globe")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    private var detailPresented: Binding<Bool> {
        Binding(
            get: { appModel.selectedInspectorRequestID != nil },
            set: { presented in
                if !presented {
                    appModel.selectedInspectorRequestID = nil
                }
            }
        )
    }
}

private struct InspectorGroupRow: Identifiable, Hashable {
    var id: String
    var title: String
    var count: Int
    var bundleID: String?
    var executablePath: String?
}

private extension InspectorRequest {
    func groupKey(_ grouping: InspectorGrouping) -> String {
        switch grouping {
        case .app: appName
        case .host: hostLabel
        }
    }
}

#Preview("Inspector") {
    InspectorPane()
        .environment(AppModel.preview)
        .frame(width: 980, height: 640)
}
