import AppKit
import Foundation
import Observation
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

enum AppWindowID {
    static let main = "prizmx.main"
    static let nodePicker = "prizmx.nodePicker"
    static let inspector = "prizmx.inspector"
}

enum AppEvent {
    static let toggleVPN = Notification.Name("app.prizmx.toggleVPN")
    static let presentNodePicker = Notification.Name("app.prizmx.presentNodePicker")
}

enum MenuBarConnectedStyle: String, CaseIterable, Identifiable, Hashable {
    case monochrome
    case accent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monochrome: "Black & White"
        case .accent: "Theme Color"
        }
    }
}

enum OutboundMode: String, CaseIterable, Identifiable, Hashable {
    case rule
    case global
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rule: "Rule"
        case .global: "Global"
        case .direct: "Direct"
        }
    }

    var systemImage: String {
        switch self {
        case .rule: "signpost.right.and.left"
        case .global: "globe"
        case .direct: "arrow.right"
        }
    }

    var summary: String {
        switch self {
        case .rule: "Traffic follows routing rules"
        case .global: "All traffic uses the selected node"
        case .direct: "All traffic bypasses the proxy"
        }
    }
}

enum MoreSheet: String, Identifiable, Hashable {
    case settings
    case profiles
    case events

    var id: String { rawValue }
}

enum InspectorScope: String, CaseIterable, Identifiable {
    case recent
    case active

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .active: "Active"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .active: "link"
        }
    }
}

enum InspectorGrouping: String, CaseIterable, Identifiable {
    case app
    case host

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "By App"
        case .host: "By Host"
        }
    }

    var systemImage: String {
        switch self {
        case .app: "app"
        case .host: "globe"
        }
    }
}

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home
    case apps
    case lan
    case policies
    case rules
    case capture
    case decrypt
    case rewrite
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .apps: "Apps"
        case .lan: "LAN"
        case .policies: "Policies"
        case .rules: "Rules"
        case .capture: "Capture"
        case .decrypt: "Decrypt"
        case .rewrite: "Rewrite"
        case .more: "More"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .apps: "app"
        case .lan: "laptopcomputer.and.iphone"
        case .policies: "arrow.triangle.branch"
        case .rules: "list.bullet.rectangle"
        case .capture: "record.circle"
        case .decrypt: "lock.open"
        case .rewrite: "arrow.left.arrow.right"
        case .more: "ellipsis"
        }
    }
}

/// Shared session for the menu-bar panel and the main console window.
@MainActor
@Observable
final class AppModel {
    private enum DefaultsKey {
        static let menuBarOnly = "menuBarOnly"
        static let systemProxyEnabled = "systemProxyEnabled"
        static let tunModeEnabled = "tunModeEnabled"
        static let allowLANEnabled = "allowLANEnabled"
        static let httpCaptureEnabled = "httpCaptureEnabled"
        static let menuBarConnectedStyle = "menuBarConnectedStyle"
        static let outboundMode = "outboundMode"
    }

    let dashboard: DashboardViewModel
    let nodeList: NodeListViewModel
    let trafficLedger: TrafficLedger

    var selectedSidebarItem: SidebarItem = .home
    var presentedMoreSheet: MoreSheet?
    var sessionStartedAt: Date?
    var inspectorScope: InspectorScope = .recent
    var inspectorGrouping: InspectorGrouping = .app
    var inspectorFilter = ""
    var selectedInspectorRequestID: InspectorRequest.ID?
    var inspectorActiveFlows: [FlowRecord] = []
    var inspectorRecentFlows: [FlowRecord] = []
    var egressIP = "—"

    var outboundMode: OutboundMode {
        didSet {
            guard outboundMode != oldValue else { return }
            UserDefaults.standard.set(outboundMode.rawValue, forKey: DefaultsKey.outboundMode)
            persistOutboundMode()
        }
    }

    var menuBarOnly: Bool {
        didSet {
            guard menuBarOnly != oldValue else { return }
            UserDefaults.standard.set(menuBarOnly, forKey: DefaultsKey.menuBarOnly)
            DockPolicy.apply(menuBarOnly: menuBarOnly)
        }
    }

    var systemProxyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(systemProxyEnabled, forKey: DefaultsKey.systemProxyEnabled)
            Task { await applyCaptureMode() }
        }
    }

    var tunModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(tunModeEnabled, forKey: DefaultsKey.tunModeEnabled)
            Task { await applyCaptureMode() }
        }
    }

    var allowLANEnabled: Bool {
        didSet {
            UserDefaults.standard.set(allowLANEnabled, forKey: DefaultsKey.allowLANEnabled)
            Task { await applyCaptureMode() }
        }
    }

    var httpCaptureEnabled: Bool {
        didSet {
            UserDefaults.standard.set(httpCaptureEnabled, forKey: DefaultsKey.httpCaptureEnabled)
        }
    }

    var menuBarConnectedStyle: MenuBarConnectedStyle {
        didSet {
            guard menuBarConnectedStyle != oldValue else { return }
            UserDefaults.standard.set(menuBarConnectedStyle.rawValue, forKey: DefaultsKey.menuBarConnectedStyle)
        }
    }

    @ObservationIgnored
    nonisolated(unsafe) private var keyMonitor: Any?
    @ObservationIgnored
    nonisolated(unsafe) private var trafficIngestTask: Task<Void, Never>?

    init(preview: Bool = false) {
        if preview {
            let profiles = ProfileStore.preview
            dashboard = DashboardViewModel(
                vpn: PrizmXServices.VPNManager(isMock: true),
                profiles: profiles,
                speedHistory: .preview()
            )
            let list = NodeListViewModel(profiles: profiles)
            list.latencyByNodeID = PreviewFixtures.previewLatencies
            nodeList = list
            menuBarOnly = false
            systemProxyEnabled = true
            tunModeEnabled = true
            allowLANEnabled = false
            httpCaptureEnabled = false
            menuBarConnectedStyle = .monochrome
            outboundMode = .rule
            sessionStartedAt = Date().addingTimeInterval(-3_723)
            trafficLedger = .preview
            inspectorRecentFlows = [
                FlowRecord(
                    startedAt: Date().addingTimeInterval(-8),
                    endpoint: Endpoint(domain: "github.com", port: 443),
                    via: "Proxies",
                    uplinkBytes: 12_000,
                    downlinkBytes: 180_000,
                    milliseconds: 1_840,
                    clientEnd: "eof",
                    remoteEnd: "eof"
                )
            ]
        } else {
            let profiles = ProfileStore()
            dashboard = DashboardViewModel(
                vpn: PrizmXServices.VPNManager.shared,
                profiles: profiles
            )
            nodeList = NodeListViewModel(profiles: profiles)
            menuBarOnly = UserDefaults.standard.bool(forKey: DefaultsKey.menuBarOnly)
            systemProxyEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.systemProxyEnabled)
            tunModeEnabled = UserDefaults.standard.object(forKey: DefaultsKey.tunModeEnabled) as? Bool ?? true
            allowLANEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.allowLANEnabled)
            httpCaptureEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.httpCaptureEnabled)
            menuBarConnectedStyle = MenuBarConnectedStyle(
                rawValue: UserDefaults.standard.string(forKey: DefaultsKey.menuBarConnectedStyle) ?? ""
            ) ?? .monochrome
            outboundMode = OutboundMode(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.outboundMode) ?? "") ?? .rule
            if dashboard.status == .connected {
                sessionStartedAt = Date()
            }
            trafficLedger = TrafficLedger()
        }
        installKeyMonitor()
        startTrafficIngest()
        // Follow external VPN changes (System Settings toggle) so the app's
        // TUN switch never fights the real session state.
        if !preview {
            dashboard.vpn.onExternalStateChange = { [weak self] on in
                guard let self, self.tunModeEnabled != on else { return }
                self.tunModeEnabled = on
            }
            // Settings off while the app was quit must stay off on next launch.
            // Assignment in init does not run didSet — persist explicitly.
            if TunnelLifecycleStore.stopWasUserInitiated() {
                tunModeEnabled = false
                UserDefaults.standard.set(false, forKey: DefaultsKey.tunModeEnabled)
            } else if tunModeEnabled || systemProxyEnabled {
                Task { await applyCaptureMode() }
            }
            persistOutboundMode()
        }
    }

    private func persistOutboundMode() {
        let group = dashboard.profiles.activeProfile?.selectedGroupName
        Task { await dashboard.vpn.notifyOutboundMode(outboundMode.rawValue, globalGroup: group) }
    }

    func applyLaunchPolicy() {
        DockPolicy.apply(menuBarOnly: menuBarOnly)
    }

    deinit {
        trafficIngestTask?.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func startTrafficIngest() {
        trafficIngestTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let metrics = self.dashboard.vpn.lastMetrics
                self.trafficLedger.ingest(metrics)
                self.inspectorActiveFlows = metrics.activeFlows
                self.inspectorRecentFlows = metrics.recentFlows
            }
        }
    }

    static var preview: AppModel { AppModel(preview: true) }

    var isVPNOn: Bool {
        dashboard.status.isConnectedOrTransitioningOn
    }

    var selectedNodeLatency: Double? {
        guard let id = nodeList.selectedNodeID else { return nil }
        return nodeList.latencyByNodeID[id] ?? nil
    }

    var hasSelectedNodePing: Bool {
        guard let id = nodeList.selectedNodeID else { return false }
        return nodeList.latencyByNodeID[id] != nil
    }

    var inspectorRequests: [InspectorRequest] {
        let flows = inspectorScope == .active ? inspectorActiveFlows : inspectorRecentFlows
        var rows = flows.map(InspectorRequest.init(flow:))
        let query = inspectorFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            rows = rows.filter {
                $0.url.localizedCaseInsensitiveContains(query)
                    || $0.policy.localizedCaseInsensitiveContains(query)
                    || $0.status.localizedCaseInsensitiveContains(query)
            }
        }
        switch inspectorGrouping {
        case .host:
            rows.sort { $0.url < $1.url }
        case .app:
            rows.sort { $0.timestamp > $1.timestamp }
        }
        return rows
    }

    var selectedInspectorRequest: InspectorRequest? {
        guard let selectedInspectorRequestID else { return nil }
        return inspectorRequests.first { $0.id == selectedInspectorRequestID }
    }

    func clearInspector() {
        inspectorRecentFlows = []
        selectedInspectorRequestID = nil
        Task { await dashboard.vpn.clearFlows() }
    }

    /// Persists the active profile overlay, rebuilds the in-app catalog, and
    /// restarts a live tunnel so Packet Tunnel reads the merged rules.
    func saveOverlay(_ overlay: ProfileOverlay) {
        try? dashboard.profiles.saveOverlay(overlay)
        Task { await reloadTunnelForOverlay() }
    }

    private func reloadTunnelForOverlay() async {
        guard tunModeEnabled || systemProxyEnabled, isVPNOn else { return }
        dashboard.vpn.stopVPN()
        try? await Task.sleep(for: .milliseconds(400))
        await applyCaptureMode()
    }

    func toggleConnection() async {
        await dashboard.toggleConnection()
        refreshSessionClock()
        await refreshEgressIP()
    }

    /// Starts/stops the NE tunnel so its state follows TUN and System Proxy.
    func applyCaptureMode() async {
        let wantSession = tunModeEnabled || systemProxyEnabled
        if !wantSession {
            if isVPNOn { dashboard.vpn.stopVPN() }
            return
        }
        let config = dashboard.profiles.activeProfile?.rawConfig ?? VPNManager.defaultDirectConfig
        try? await dashboard.vpn.startVPN(
            configText: config,
            fakeIP: tunModeEnabled,
            systemProxy: systemProxyEnabled,
            allowLAN: allowLANEnabled,
            overlay: dashboard.profiles.overlay
        )
    }

    func refreshEgressIP() async {
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                egressIP = "—"
                return
            }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            egressIP = text.isEmpty ? "—" : text
        } catch {
            egressIP = "—"
        }
    }

    func refreshSessionClock() {
        if dashboard.status == .connected {
            if sessionStartedAt == nil {
                sessionStartedAt = Date()
            }
        } else if !dashboard.status.isSessionActive {
            sessionStartedAt = nil
        }
    }

    func select(_ node: OutboundNode) {
        dashboard.selectNode(node)
    }

    /// Focuses the standalone Inspector window, bringing the app forward.
    func presentInspector(using openWindow: OpenWindowAction) {
        openWindow(id: AppWindowID.inspector)
        NSApp.activate(ignoringOtherApps: true)
        DockPolicy.apply(menuBarOnly: menuBarOnly)
    }

    func presentNodePicker(using openWindow: OpenWindowAction) {
        openWindow(id: AppWindowID.nodePicker)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Focuses the main console, optionally switching the sidebar selection.
    func presentMain(using openWindow: OpenWindowAction, selecting item: SidebarItem? = nil) {
        if let item { selectedSidebarItem = item }
        openWindow(id: AppWindowID.main)
        NSApp.activate(ignoringOtherApps: true)
        DockPolicy.apply(menuBarOnly: menuBarOnly)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleLocalKey(event)
        }
    }

    /// Local (app-active) shortcuts so Menu Bar Only still receives ⌘K / ⌘.
    nonisolated private static func handleLocalKey(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control)
        else { return event }

        if isEditingText { return event }

        switch event.charactersIgnoringModifiers {
        case "k":
            NotificationCenter.default.post(name: AppEvent.presentNodePicker, object: nil)
            return nil
        case ".":
            NotificationCenter.default.post(name: AppEvent.toggleVPN, object: nil)
            return nil
        default:
            return event
        }
    }

    nonisolated private static var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSTextView || responder is NSText
    }
}

struct InspectorRequest: Identifiable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var appName: String
    var status: String
    var policy: String
    var rule: String
    var uploadBytes: UInt64
    var downloadBytes: UInt64
    var url: String
    var milliseconds: Int
    var clientEnd: String
    var remoteEnd: String

    init(flow: FlowRecord) {
        id = flow.id
        timestamp = flow.startedAt
        appName = "—"
        status = flow.closed ? (flow.clientEnd.isEmpty ? "closed" : flow.clientEnd) : "active"
        policy = flow.via
        rule = flow.rule.isEmpty ? "—" : flow.rule
        uploadBytes = flow.uplinkBytes
        downloadBytes = flow.downlinkBytes
        url = flow.endpoint.description
        milliseconds = flow.milliseconds
        clientEnd = flow.clientEnd
        remoteEnd = flow.remoteEnd
    }
}

enum DockPolicy {
    @MainActor
    static func apply(menuBarOnly: Bool) {
        let app = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = menuBarOnly ? .accessory : .regular
        app.setActivationPolicy(policy)
        if !menuBarOnly {
            app.activate()
        }
    }
}

extension ProxyProfile.Format {
    var label: String {
        switch self {
        case .clash: "Clash"
        case .singbox: "sing-box"
        case .unknown: "Unknown"
        }
    }
}

extension ProxyProfile {
    var formatLabel: String { format.label }
}

extension OutboundNode {
    var protocolLabel: String {
        switch protocolConfig {
        case .shadowsocks: "SS"
        case .vless: "VLESS"
        case .trojan: "Trojan"
        case .anytls: "AnyTLS"
        case .direct: "Direct"
        }
    }
}
