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
    @State private var unit = WidgetGrid.minUnit
    @State private var boardWidth = WidgetGrid.boardWidth(unit: WidgetGrid.minUnit)
    @State private var widthSettleTask: Task<Void, Never>?
    @AppStorage("homeTrafficPeriod") private var trafficPeriodRaw = TrafficPeriod.day.rawValue
    @AppStorage("homeTrafficRankScope") private var rankScopeRaw = TrafficRankScope.app.rawValue
    @AppStorage("homeDidShowReorderTip") private var didShowReorderTip = false
    @State private var showsEgressInfo = false

    var body: some View {
        let placed = layout.packed()
        let rows = placed.map { $0.row + $0.size.rows }.max() ?? 0

        VStack(alignment: .leading, spacing: WidgetGrid.spacing) {
            headerFacts(unit: unit)
                .frame(width: boardWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            if !didShowReorderTip {
                reorderTip
                    .frame(width: boardWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            settleBoard(for: width)
        }
        .navigationTitle("Home")
        .task {
            await appModel.refreshEgress()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { return }
                await appModel.refreshEgress()
            }
        }
        // Node / mode / capture / network changes schedule a coalesced
        // refresh in AppModel — no per-event onChange here (that raced the
        // route change and double-queried).
        .onChange(of: appModel.dashboard.status) {
            appModel.scheduleEgressRefresh()
        }
    }

    /// Sidebar expand/collapse changes width every frame. Rebuilding the
    /// widget grid on each tick is what hitchs the split animation.
    private func settleBoard(for width: CGFloat) {
        let nextUnit = WidgetGrid.unit(for: width - 40)
        let nextBoard = WidgetGrid.boardWidth(unit: nextUnit)
        if abs(nextUnit - unit) < 0.5 { return }
        if widthSettleTask == nil, unit == WidgetGrid.minUnit {
            unit = nextUnit
            boardWidth = nextBoard
            return
        }
        widthSettleTask?.cancel()
        widthSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            unit = nextUnit
            boardWidth = nextBoard
            widthSettleTask = nil
        }
    }

    private func placedCard(_ item: PlacedWidget, unit: CGFloat) -> some View {
        card(item.id)
            .opacity(dropTarget == item.id ? 0.72 : 1)
            .overlay {
                if dropTarget == item.id {
                    WidgetChrome.shape
                        .stroke(WidgetChrome.accent, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .draggable(item.id.rawValue)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let dragged = HomeWidgetID(rawValue: raw) else {
                    return false
                }
                layout.move(dragged, before: item.id)
                didShowReorderTip = true
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

    private var reorderTip: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw")
            Text("Drag widgets to reorder.")
            Spacer(minLength: 8)
            Button {
                didShowReorderTip = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WidgetChrome.fill, in: Capsule())
    }

    private func headerFacts(unit: CGFloat) -> some View {
        HStack(alignment: .top, spacing: WidgetGrid.spacing) {
            headerFact("Network") {
                HStack(spacing: 6) {
                    Image(systemName: appModel.networkLink.kind.systemImage)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(appModel.networkLink.title)
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            .frame(width: unit, alignment: .leading)
            headerFact("Profile", appModel.dashboard.activeProfileName)
                .frame(width: unit, alignment: .leading)
            headerFact("Mode", appModel.outboundMode.title)
                .frame(width: unit, alignment: .leading)
            headerFact("External IP") {
                Button {
                    showsEgressInfo = true
                } label: {
                    HStack(spacing: 6) {
                        if let flag = appModel.egressInfo?.flagEmoji {
                            Text(flag)
                                .font(.headline)
                        }
                        Text(appModel.egressIP)
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "info.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("IP details")
                .popover(isPresented: $showsEgressInfo, arrowEdge: .bottom) {
                    ExternalIPPopover()
                        .environment(appModel)
                }
            }
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
                tunIsOn: $model.tunModeEnabled
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
                appModel.presentNodePicker(using: openWindow)
            }
        }
    }

    // MARK: - Metrics

    private var latencyWidget: some View {
        let parts = latencyParts
        return LatencyCard(
            value: parts.value,
            unit: parts.unit,
            nodeText: appModel.dashboard.activeNodeName,
            bestText: latencyBestText
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
        let flows = appModel.dashboard.vpn.lastMetrics.activeFlows
        let processes = Set(flows.compactMap { $0.attribution?.accountingKey })
        let hosts = Set(flows.map(\.endpoint.host.description))
        return ConnectionsCard(
            count: live,
            processesText: "\(processes.count)",
            hostsText: "\(hosts.count)"
        ) {
            Button {
                appModel.presentInspector(using: openWindow)
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
                AppIcon.image(bundleID: row.bundleID, executablePath: nil)
                    ?? AppIcon.image(bundleID: "com.apple.Terminal", executablePath: nil)
            }
        ) {
            WidgetCapsulePicker(
                options: TrafficRankScope.allCases.map { ($0.rawValue, $0.title) },
                selection: $rankScopeRaw,
                compact: true,
                expands: true
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
        return Self.relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var latencyParts: (value: String, unit: String) {
        guard appModel.hasSelectedNodePing else { return ("—", "") }
        return LatencyFormat.parts(appModel.selectedNodeLatency)
    }

    private var latencyBestText: String {
        let samples = appModel.nodeList.latencyByNodeID.values.compactMap { rtt -> Double? in
            guard let rtt, !LatencyFormat.isTimeout(rtt) else { return nil }
            return rtt
        }
        guard let best = samples.min() else { return "—" }
        return LatencyFormat.label(best)
    }

    private var latencyDisplay: String {
        let parts = latencyParts
        return parts.unit.isEmpty ? parts.value : "\(parts.value) \(parts.unit)"
    }

    private func headerFact(_ title: String, _ value: String) -> some View {
        headerFact(title) {
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
    }

    private func headerFact<Content: View>(_ title: String, @ViewBuilder value: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pingSelected() async {
        guard let node = selectedNode else { return }
        await appModel.nodeList.ping(node)
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
