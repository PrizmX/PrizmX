import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIComponents
import PrizmXUIEngine

/// Home tiled like system widgets: 1×1 / 2×1 / 2×2, drag to reorder.
struct HomePane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var layout = HomeWidgetLayout()
    @State private var dropTarget: HomeWidgetID?
    @AppStorage("homeTrafficPeriod") private var trafficPeriodRaw = TrafficPeriod.day.rawValue
    @AppStorage("homeTrafficRankScope") private var rankScopeRaw = TrafficRankScope.app.rawValue

    var body: some View {
        GeometryReader { geo in
            let unit = WidgetGrid.unit(for: geo.size.width - 40)
            let boardWidth = WidgetGrid.boardWidth(unit: unit)
            let placed = layout.packed()
            let rows = placed.map { $0.row + $0.size.rows }.max() ?? 0

            VStack(alignment: .leading, spacing: WidgetGrid.spacing) {
                headerFacts(unit: unit)
                    .frame(width: boardWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: WidgetGrid.spacing) {
                        ZStack(alignment: .topLeading) {
                            ForEach(placed) { item in
                                placedCard(item, unit: unit)
                            }
                        }
                        .environment(\.widgetUnit, unit)
                        .frame(
                            width: boardWidth,
                            height: WidgetGrid.boardHeight(rows: rows, unit: unit),
                            alignment: .topLeading
                        )
                        if let error = appModel.dashboard.lastError {
                            InfoWidget(title: "Error", systemImage: "exclamationmark.triangle", size: .large) {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            .environment(\.widgetUnit, unit)
                        }
                    }
                    .frame(width: boardWidth)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WidgetChrome.page)
        }
        .background(WidgetChrome.page)
        .navigationTitle("Home")
        .task {
            await appModel.refreshEgressIP()
        }
        .onChange(of: appModel.dashboard.status) {
            Task { await appModel.refreshEgressIP() }
        }
    }

    private func placedCard(_ item: PlacedWidget, unit: CGFloat) -> some View {
        card(item.id)
            .opacity(dropTarget == item.id ? 0.72 : 1)
            .overlay {
                if dropTarget == item.id {
                    WidgetChrome.shape
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .draggable(item.id.rawValue)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let dragged = HomeWidgetID(rawValue: raw) else {
                    return false
                }
                layout.move(dragged, before: item.id)
                return true
            } isTargeted: { hovering in
                dropTarget = hovering ? item.id : nil
            }
            .offset(
                x: CGFloat(item.column) * (unit + WidgetGrid.spacing),
                y: CGFloat(item.row) * (unit + WidgetGrid.spacing)
            )
    }

    // MARK: - Facts header

    private func headerFacts(unit: CGFloat) -> some View {
        HStack(alignment: .top, spacing: WidgetGrid.spacing) {
            headerFact("Network", appModel.dashboard.status.rawValue.capitalized)
                .frame(width: unit, alignment: .leading)
            headerFact("Profile", appModel.dashboard.activeProfileName)
                .frame(width: unit, alignment: .leading)
            headerFact("Mode", appModel.outboundMode.title)
                .frame(width: unit, alignment: .leading)
            headerFact("External IP", appModel.egressIP)
                .frame(width: unit, alignment: .leading)
        }
    }

    @ViewBuilder
    private func card(_ id: HomeWidgetID) -> some View {
        @Bindable var model = appModel
        switch id {
        case .outbound: outboundWidget
        case .capture:
            TakeoverCard(
                headline: takeoverHeadline,
                proxyIsOn: $model.systemProxyEnabled,
                tunIsOn: $model.tunModeEnabled,
                systemProxyAvailable: true
            )
        case .subscription: profileWidget
        case .node: nodeWidget
        case .latency: latencyWidget
        case .connections: connectionsWidget
        case .upload:
            RateCard(
                title: "Upload",
                systemImage: "arrow.up",
                series: .upload,
                livePoints: appModel.dashboard.speedHistory
            )
        case .download:
            RateCard(
                title: "Download",
                systemImage: "arrow.down",
                series: .download,
                livePoints: appModel.dashboard.speedHistory
            )
        case .totalTraffic: trafficWidget
        case .ranking: rankingWidget
        }
    }

    // MARK: - Outbound / Capture

    private var outboundWidget: some View {
        @Bindable var model = appModel
        return OutboundCard(
            headline: outboundHeadline,
            hintIcon: appModel.outboundMode.systemImage,
            hintText: appModel.outboundMode.summary
        ) {
            WidgetCapsulePicker(
                options: OutboundMode.allCases.map { ($0, $0.title) },
                selection: $model.outboundMode
            )
        }
    }

    private var takeoverHeadline: String {
        switch (appModel.systemProxyEnabled, appModel.tunModeEnabled) {
        case (true, true): "Proxy + TUN"
        case (true, false): "System Proxy"
        case (false, true): "TUN"
        case (false, false): "Off"
        }
    }

    // MARK: - Profile / Node

    private var profileWidget: some View {
        let profile = appModel.dashboard.profiles.activeProfile
        return ProfileCard(
            name: profile?.name,
            isSubscription: profile?.subscriptionURL != nil,
            updatedText: relativeUpdate(profile?.lastUpdated),
            formatLabel: profile?.formatLabel ?? "—"
        ) {
            if let profile, profile.subscriptionURL != nil {
                WidgetIconButton(systemImage: "arrow.clockwise", help: "Update subscription") {
                    Task { try? await appModel.dashboard.profiles.refreshSubscription(id: profile.id) }
                }
            }
        }
    }

    private var nodeWidget: some View {
        NodeCard(
            name: appModel.dashboard.activeNodeName,
            protocolText: selectedNode?.protocolLabel ?? "—",
            latencyText: latencyDisplay,
            groupText: appModel.dashboard.profiles.activeProfile?.selectedGroupName ?? "—"
        ) {
            WidgetIconButton(systemImage: "chevron.right", help: "Select node (⌘K)") {
                appModel.presentNodePicker()
            }
        }
    }

    // MARK: - Metrics

    private var latencyWidget: some View {
        let parts = latencyParts
        return LatencyCard(
            value: parts.value,
            unit: parts.unit
        ) {
            WidgetIconButton(
                systemImage: "arrow.clockwise",
                help: "Ping current node",
                enabled: !appModel.nodeList.isPinging
            ) {
                Task { await pingSelected() }
            }
        }
    }

    private var connectionsWidget: some View {
        let live = appModel.dashboard.vpn.activeConnections
        return ConnectionsCard(count: live) {
            Button {
                openInspector()
            } label: {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(appModel.dashboard.status == .connected ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Inspector")
        }
    }

    // MARK: - Traffic / Ranking

    private var trafficWidget: some View {
        let period = TrafficPeriod(rawValue: trafficPeriodRaw) ?? .day
        let totals = appModel.trafficLedger.totals(for: period)
        return TrafficCard(totals: totals) {
            WidgetCapsulePicker(
                options: TrafficPeriod.allCases.map { ($0.rawValue, $0.title) },
                selection: $trafficPeriodRaw,
                compact: true
            )
        }
    }

    private var rankingWidget: some View {
        let scope = TrafficRankScope(rawValue: rankScopeRaw) ?? .app
        return RankingCard(
            rows: appModel.trafficLedger.rows(for: scope),
            hourly: appModel.trafficLedger.hourly(),
            emptyText: scope.emptyDescription,
            iconImage: { row in
                guard let bundleID = row.bundleID,
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                    return nil
                }
                return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            }
        ) {
            WidgetCapsulePicker(
                options: TrafficRankScope.allCases.map { ($0.rawValue, $0.title) },
                selection: $rankScopeRaw,
                compact: true
            )
        }
    }

    // MARK: - Helpers

    private var selectedNode: OutboundNode? {
        guard let id = appModel.nodeList.selectedNodeID else { return nil }
        return appModel.nodeList.filteredNodes.first { $0.id == id }
    }

    private var outboundHeadline: String {
        switch appModel.dashboard.status {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .disconnecting: "Disconnecting"
        case .error: "Error"
        case .invalid, .disconnected: "Disconnected"
        }
    }

    private func relativeUpdate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private var latencyParts: (value: String, unit: String) {
        if appModel.hasSelectedNodePing {
            if let milliseconds = appModel.selectedNodeLatency, milliseconds >= 0, milliseconds <= 2_000 {
                return ("\(Int(milliseconds.rounded()))", "ms")
            }
            return ("Timeout", "")
        }
        return ("—", "")
    }

    private var latencyDisplay: String {
        let parts = latencyParts
        return parts.unit.isEmpty ? parts.value : "\(parts.value) \(parts.unit)"
    }

    private func headerFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pingSelected() async {
        guard let node = selectedNode else { return }
        await appModel.nodeList.ping(node)
    }

    private func openInspector() {
        openWindow(id: AppWindowID.inspector)
        NSApp.activate(ignoringOtherApps: true)
        DockPolicy.apply(menuBarOnly: appModel.menuBarOnly)
    }
}

typealias DashboardPane = HomePane

#Preview("Home") {
    NavigationStack {
        HomePane()
    }
    .environment(AppModel.preview)
    .frame(width: 980, height: 980)
}
