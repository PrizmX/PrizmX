import SwiftUI
import PrizmXNodes
import PrizmXUIEngine

/// Grouped node table with search, concurrent ping, and selection highlight.
struct NodeSelectPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    var showsToolbar: Bool = true
    var showsDoneButton: Bool = false

    var body: some View {
        @Bindable var nodeList = appModel.nodeList

        Group {
            if nodeList.sections.isEmpty {
                emptyState
            } else {
                nodeTable
            }
        }
        .navigationTitle("Policies")
        .searchable(text: $nodeList.searchText, prompt: "Filter nodes")
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismissWindow(id: AppWindowID.nodePicker)
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            if showsToolbar {
                ToolbarItem(placement: .automatic) {
                    Picker("Group", selection: $nodeList.grouping) {
                        Text("Policy").tag(NodeListGrouping.policy)
                        Text("Region").tag(NodeListGrouping.region)
                    }
                    .pickerStyle(.segmented)
                    .frame(minWidth: 160)
                    .help("Group by policy or region")
                }
                ToolbarItem(placement: .primaryAction) {
                    if nodeList.isPinging {
                        Button("Stop") {
                            nodeList.cancelPing()
                        }
                    } else {
                        Button("Ping All", systemImage: "gauge.with.dots.needle.67percent") {
                            Task { await nodeList.pingAllNodes() }
                        }
                        .help("Concurrent delay test")
                    }
                }
            }
        }
    }

    private var nodeTable: some View {
        Table(of: OutboundNode.self, selection: tableSelection) {
            TableColumn("Node") { node in
                Text(node.name)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Protocol") { node in
                Text(node.protocolLabel)
            }
            .width(80)

            TableColumn("Latency") { node in
                if appModel.nodeList.hasPingResult(for: node) {
                    Text(latencyLabel(appModel.nodeList.latency(for: node)))
                } else if appModel.nodeList.isPinging {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(90)
        } rows: {
            ForEach(appModel.nodeList.sections) { section in
                Section(section.title) {
                    ForEach(section.nodes) { node in
                        TableRow(node)
                            .contextMenu {
                                Button("Select") {
                                    selectAndClose(node)
                                }
                                Button("Ping") {
                                    Task { await appModel.nodeList.ping(node) }
                                }
                            }
                    }
                }
            }
        }
        .tableStyle(.inset)
    }

    private var tableSelection: Binding<OutboundNode.ID?> {
        Binding(
            get: { appModel.nodeList.selectedNodeID },
            set: { newValue in
                guard let newValue,
                      let node = appModel.nodeList.filteredNodes.first(where: { $0.id == newValue })
                else { return }
                selectAndClose(node)
            }
        )
    }

    private func selectAndClose(_ node: OutboundNode) {
        appModel.select(node)
        dismissWindow(id: AppWindowID.nodePicker)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Nodes", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text(appModel.nodeList.searchText.isEmpty
                 ? "Import a profile to populate proxies."
                 : "No nodes match this filter.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func latencyLabel(_ milliseconds: Double?) -> String {
        LatencyFormat.label(milliseconds)
    }
}

#Preview("Nodes") {
    NavigationStack {
        NodeSelectPane()
    }
    .environment(AppModel.preview)
    .frame(width: 640, height: 520)
}
