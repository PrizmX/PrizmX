import SwiftUI
import PrizmXNodes
import PrizmXUIEngine

/// Grouped node table with search and concurrent ping. As in Policies, a
/// click only highlights; double-click or Select in the context menu picks
/// the node and closes the window.
struct NodeSelectPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var highlightedID: OutboundNode.ID?

    var body: some View {
        @Bindable var nodeList = appModel.nodeList

        Group {
            if nodeList.sections.isEmpty {
                emptyState
            } else {
                nodeTable
            }
        }
        .navigationTitle("Select Node")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Group By", selection: $nodeList.grouping) {
                        Label("Policy", systemImage: "arrow.triangle.branch")
                            .tag(NodeListGrouping.policy)
                        Label("Region", systemImage: "globe")
                            .tag(NodeListGrouping.region)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Group By", systemImage: "rectangle.3.group")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .help("Group by policy or region")
            }
            ToolbarItem(placement: .primaryAction) {
                pingButton
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $nodeList.searchText, prompt: "Filter nodes")
            }
        }
        // Esc closes the picker. A cancel-action shortcut works wherever focus
        // is; `onExitCommand` only fires while the table has focus. A search
        // field with text takes the first Esc to clear itself.
        .background {
            Button("Close") {
                dismissWindow(id: AppWindowID.nodePicker)
            }
            .keyboardShortcut(.cancelAction)
            .hidden()
        }
    }

    /// The Policies control; clicking it while testing stops the test.
    private var pingButton: some View {
        let nodeList = appModel.nodeList
        return Button("Ping All", systemImage: "gauge.with.dots.needle.67percent") {
            if nodeList.isPinging {
                nodeList.cancelPing()
            } else {
                Task { await nodeList.pingAllNodes() }
            }
        }
        .labelStyle(.iconOnly)
        .symbolRenderingMode(.hierarchical)
        .symbolEffect(
            .variableColor.iterative.dimInactiveLayers,
            options: .repeating.speed(0.8),
            isActive: nodeList.isPinging
        )
        .help(nodeList.isPinging ? "Stop delay test" : "Concurrent delay test")
    }

    private var nodeTable: some View {
        Table(of: OutboundNode.self, selection: $highlightedID) {
            TableColumn("Node") { node in
                HStack {
                    if node.id == appModel.nodeList.selectedNodeID {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .frame(width: 14)
                    } else {
                        Color.clear.frame(width: 14)
                    }
                    Text(node.name)
                }
            }
            .width(min: 160, ideal: 240)

            TableColumn("Protocol") { node in
                Text(node.protocolLabel)
            }
            .width(80)

            TableColumn("Latency") { node in
                if appModel.nodeList.hasPingResult(for: node) {
                    let ms = appModel.nodeList.latency(for: node)
                    Text(LatencyFormat.label(ms))
                        .foregroundStyle(LatencyFormat.color(ms))
                        .monospacedDigit()
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
                    }
                }
            }
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: OutboundNode.ID.self) { ids in
            if let node = node(ids.first) {
                Button("Select") { selectAndClose(node) }
                Button("Ping") { Task { await appModel.nodeList.ping(node) } }
            }
        } primaryAction: { ids in
            if let node = node(ids.first) {
                selectAndClose(node)
            }
        }
    }

    private func node(_ id: OutboundNode.ID?) -> OutboundNode? {
        guard let id else { return nil }
        return appModel.nodeList.filteredNodes.first { $0.id == id }
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

}

#Preview("Nodes") {
    NavigationStack {
        NodeSelectPane()
    }
    .environment(AppModel.preview)
    .frame(width: 640, height: 520)
}
