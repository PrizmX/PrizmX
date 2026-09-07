import SwiftUI
import PrizmXServices

/// Request inspector: one table, system inspector for the selected row.
struct InspectorPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Table(appModel.inspectorRequests, selection: Binding(
            get: { appModel.selectedInspectorRequestID },
            set: { appModel.selectedInspectorRequestID = $0 }
        )) {
            TableColumn("Time") { (item: InspectorRequest) in
                Text(item.timestamp, style: .time)
                    .font(.body.monospacedDigit())
            }
            .width(80)
            TableColumn("App") { item in
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
            TableColumn("Status") { item in
                Text(item.status)
            }
            .width(90)
            TableColumn("Policy") { item in
                Text(item.policy)
            }
            .width(100)
            TableColumn("Rule") { item in
                Text(item.rule)
            }
            TableColumn("↓") { item in
                Text(ByteRateFormatter.byteCount(item.downloadBytes))
                    .font(.body.monospacedDigit())
            }
            .width(70)
            TableColumn("↑") { item in
                Text(ByteRateFormatter.byteCount(item.uploadBytes))
                    .font(.body.monospacedDigit())
            }
            .width(70)
            TableColumn("URL") { item in
                Text(item.url)
                    .font(.body.monospaced())
                    .lineLimit(1)
            }
        }
        .tableStyle(.inset)
        .overlay {
            if appModel.inspectorRequests.isEmpty {
                ContentUnavailableView {
                    Label("No Requests", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(
                        appModel.inspectorScope == .active
                            ? "Active flows will appear here once the tunnel reports connections."
                            : "Recent requests will appear here once the tunnel reports connections."
                    )
                }
            }
        }
        .searchable(text: $appModel.inspectorFilter, prompt: "Filter")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Scope", selection: $appModel.inspectorScope) {
                    ForEach(InspectorScope.allCases) { scope in
                        Image(systemName: scope.systemImage)
                            .help(scope.title)
                            .tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(appModel.inspectorScope.title)
            }
            ToolbarItem(placement: .automatic) {
                Picker("Group", selection: $appModel.inspectorGrouping) {
                    ForEach(InspectorGrouping.allCases) { grouping in
                        Image(systemName: grouping.systemImage)
                            .help(grouping.title)
                            .tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(appModel.inspectorGrouping.title)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear", systemImage: "trash") {
                    appModel.clearInspector()
                }
                .labelStyle(.iconOnly)
                .disabled(appModel.inspectorScope == .active || appModel.inspectorRecentFlows.isEmpty)
                .help("Clear recent flows")
            }
        }
        .inspector(isPresented: detailPresented) {
            if let request = appModel.selectedInspectorRequest {
                Form {
                    Section {
                        LabeledContent("App", value: request.appName)
                        LabeledContent("URL", value: request.url)
                        LabeledContent("Status", value: request.status)
                        LabeledContent("Policy", value: request.policy)
                        LabeledContent("Rule", value: request.rule)
                        LabeledContent("Duration", value: "\(request.milliseconds) ms")
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
        .navigationTitle("Inspector")
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

#Preview("Inspector") {
    InspectorPane()
        .environment(AppModel.preview)
        .frame(width: 980, height: 640)
}
