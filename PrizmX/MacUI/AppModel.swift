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

/// Menu-bar glyph. Capture is reserved so the label can grow without another AppKit probe.
enum MenuBarSessionState: String, Hashable {
    case idle
    case systemProxy
    case tun
    case capture

    var title: String {
        switch self {
        case .idle: "Not Proxied"
        case .systemProxy: "System Proxy"
        case .tun: "TUN"
        case .capture: "Capturing"
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
        case .app: "App"
        case .host: "Host"
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
    case profiles
    case events
    case settings
    case module
    case scripts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .apps: "Apps"
        case .lan: "LAN"
        case .policies: "Policies"
        case .rules: "Rules"
        case .profiles: "Profiles"
        case .events: "Events"
        case .settings: "Settings"
        case .module: "Module"
        case .scripts: "Scripts"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .apps: "app"
        case .lan: "laptopcomputer.and.iphone"
        case .policies: "arrow.triangle.branch"
        case .rules: "list.bullet.rectangle"
        case .profiles: "doc.text"
        case .events: "terminal"
        case .settings: "gearshape"
        case .module: "shippingbox"
        case .scripts: "flask"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .module, .scripts: false
        default: true
        }
    }

    var placeholderSummary: String? {
        switch self {
        case .module: "Overlay snippets on the active profile."
        case .scripts: "Extend routing with JavaScript."
        default: nil
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
        static let menuBarConnectedStyle = "menuBarConnectedStyle"
        static let outboundMode = "outboundMode"
    }

    let dashboard: DashboardViewModel
    let nodeList: NodeListViewModel
    let trafficLedger: TrafficLedger
    let scripts: ScriptStore
    let networkLink = NetworkLinkMonitor()
    /// Direct internet RTT (not the selected node). `nil` before the first probe.
    var internetLatency: Double?
    /// UDP query time against the physical resolver (not FakeIP).
    var dnsLatency: Double?
    var isMeasuringPathLatency = false
    private let mixedPortRuntime = SystemProxyRuntime()

    var eventsLogLevel: TunnelLog.Level = .info {
        didSet {
            guard eventsLogLevel != oldValue else { return }
            TunnelLog.minimumLevel = eventsLogLevel
        }
    }
    var selectedSidebarItem: SidebarItem = .home
    var sessionStartedAt: Date?
    var inspectorScope: InspectorScope = .recent {
        didSet { refreshInspectorRows() }
    }
    var inspectorGrouping: InspectorGrouping = .app {
        didSet {
            // Keys differ per grouping (bundle ID vs host). Reset in the same
            // update so the old key is never listed under the new grouping.
            if inspectorGrouping != oldValue {
                inspectorSelectedGroup = ""
            }
        }
    }
    var inspectorFilter = "" {
        didSet { refreshInspectorRows() }
    }
    /// Empty string is All Apps / All Hosts. App grouping uses `accountingKey`.
    var inspectorSelectedGroup = "" {
        didSet { refreshInspectorRows() }
    }
    var inspectorSortOrder = [KeyPathComparator(\InspectorRequest.timestamp, order: .reverse)] {
        didSet { refreshInspectorRows() }
    }
    var selectedInspectorRequestID: InspectorRequest.ID?
    /// Inspector history, newest first: open and finished requests in one
    /// list (Recent); Active is the open ones. Mirrors `inspectorHistory`.
    var inspectorFlows: [FlowRecord] = [] {
        didSet { refreshInspectorRows() }
    }
    @ObservationIgnored
    private var inspectorHistory = FlowHistory()
    /// Inspector table and sidebar, rebuilt by `refreshInspectorRows()` when
    /// an input changes (views only read them).
    private(set) var inspectorRows: [InspectorRequest] = []
    private(set) var inspectorGroupRows: [InspectorGroupRow] = []
    private(set) var inspectorAllCount = 0
    @ObservationIgnored
    private var inspectorRowBuilder = InspectorRowBuilder()
    var appByteRates: [String: Double] = [:]
    @ObservationIgnored
    private var inspectorSerials: [UUID: UInt64] = [:]
    @ObservationIgnored
    private var inspectorNextSerial: UInt64 = 0
    @ObservationIgnored
    var lastAppByteSample: (at: Date, bytes: [String: TrafficByteCount])?
    var egressIP = "—"
    var egressInfo: EgressIPInfo?
    var egressLookupError: String?
    var mixedPortListenError: String?
    /// System proxy actually applied (listener up). `systemProxyEnabled` is
    /// the user's intent; this drops to false when the apply fails.
    private(set) var systemProxyActive = false
    /// Parsed once per profile apply. Home/LAN must not YAML-parse every tick.
    var inboundListen = InboundListenConfig.appDefault
    var lanDeviceByAddress: [String: LANDevice] = [:] {
        didSet { refreshInspectorRows() }
    }
    @ObservationIgnored
    var lanResolveAttempted = Set<String>()

    var outboundMode: OutboundMode {
        didSet {
            guard outboundMode != oldValue else { return }
            UserDefaults.standard.set(outboundMode.rawValue, forKey: DefaultsKey.outboundMode)
            persistOutboundMode()
            scheduleEgressRefresh()
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
            guard systemProxyEnabled != oldValue else { return }
            UserDefaults.standard.set(systemProxyEnabled, forKey: DefaultsKey.systemProxyEnabled)
            scheduleTakeover()
        }
    }

    var tunModeEnabled: Bool {
        didSet {
            guard tunModeEnabled != oldValue else { return }
            UserDefaults.standard.set(tunModeEnabled, forKey: DefaultsKey.tunModeEnabled)
            scheduleTakeover()
        }
    }

    var allowLANEnabled: Bool {
        didSet {
            guard allowLANEnabled != oldValue else { return }
            UserDefaults.standard.set(allowLANEnabled, forKey: DefaultsKey.allowLANEnabled)
            scheduleTakeover()
        }
    }

    var menuBarConnectedStyle: MenuBarConnectedStyle {
        didSet {
            guard menuBarConnectedStyle != oldValue else { return }
            UserDefaults.standard.set(menuBarConnectedStyle.rawValue, forKey: DefaultsKey.menuBarConnectedStyle)
        }
    }

    /// Menu-bar popover open state, derived from window visibility tracking.
    var menuPanelPresented = false {
        didSet { updateUIVisibility() }
    }
    /// True while any titled app window is on screen and not occluded.
    /// Gates live-chart publishing and wall-clock TimelineViews.
    private(set) var anyWindowVisible = false

    @ObservationIgnored
    nonisolated(unsafe) private var uiVisibilityObservers: [NSObjectProtocol] = []

    @ObservationIgnored
    nonisolated(unsafe) private var keyMonitor: Any?
    @ObservationIgnored
    nonisolated(unsafe) private var trafficIngestTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var takeoverTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) var egressRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

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
            systemProxyActive = true
            tunModeEnabled = true
            allowLANEnabled = false
            menuBarConnectedStyle = .monochrome
            outboundMode = .rule
            eventsLogLevel = .info
            sessionStartedAt = Date().addingTimeInterval(-3_723)
            trafficLedger = .preview
            scripts = .preview
            internetLatency = 9
            dnsLatency = 6
            var history = FlowHistory()
            history.ingest(MockTrafficGenerator.metrics())
            inspectorHistory = history
            inspectorFlows = history.flows
            appByteRates = [
                "com.apple.Safari": 86_000,
                "com.apple.Music": 2_400
            ]
        } else {
            // Open-core Developer ID system extension: sendProviderMessage is
            // unreliable. iOS / Pro leave the Kit default (.providerMessage).
            VPNManager.metricsChannel = .kitFile
            let profiles = ProfileStore()
            dashboard = DashboardViewModel(
                vpn: PrizmXServices.VPNManager.shared,
                profiles: profiles
            )
            let mixedPort = mixedPortRuntime
            dashboard.vpn.localMetricsProvider = { mixedPort.metrics() }
            nodeList = NodeListViewModel(profiles: profiles)
            menuBarOnly = UserDefaults.standard.bool(forKey: DefaultsKey.menuBarOnly)
            systemProxyEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.systemProxyEnabled)
            tunModeEnabled = UserDefaults.standard.object(forKey: DefaultsKey.tunModeEnabled) as? Bool ?? true
            allowLANEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.allowLANEnabled)
            menuBarConnectedStyle = MenuBarConnectedStyle(
                rawValue: UserDefaults.standard.string(forKey: DefaultsKey.menuBarConnectedStyle) ?? ""
            ) ?? .monochrome
            outboundMode = OutboundMode(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.outboundMode) ?? "") ?? .rule
            eventsLogLevel = TunnelLog.minimumLevel
            if dashboard.status == .connected {
                sessionStartedAt = Date()
            }
            trafficLedger = TrafficLedger()
            scripts = ScriptStore()
        }
        // Assignments in init skip didSet.
        refreshInspectorRows()
        if !preview {
            installKeyMonitor()
            installUIVisibilityTracking()
            startTrafficIngest()
            networkLink.onChange = { [weak self] in
                self?.scheduleEgressRefresh()
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.mixedPortRuntime.shutdown()
        }
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
            } else if tunModeEnabled || systemProxyEnabled || allowLANEnabled {
                Task { await applyTakeover() }
            }
            persistOutboundMode()
            refreshInboundListen()
        }
    }

    private func persistOutboundMode() {
        let group = dashboard.profiles.activeProfile?.selectedGroupName
        Task { await dashboard.vpn.notifyOutboundMode(outboundMode.rawValue, globalGroup: group) }
        mixedPortRuntime.reloadSelections()
    }

    func applyLaunchPolicy() {
        DockPolicy.apply(menuBarOnly: menuBarOnly)
        if !systemProxyEnabled && !allowLANEnabled {
            mixedPortRuntime.shutdown()
            syncMixedPortState()
        }
    }

    deinit {
        trafficIngestTask?.cancel()
        takeoverTask?.cancel()
        egressRefreshTask?.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        for observer in uiVisibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Ingests at 1 Hz only while `VPNManager` polls (tunnel or mixed-port
    /// up); otherwise there is nothing new to read.
    private func startTrafficIngest() {
        let polling = withObservationTracking {
            dashboard.vpn.isPollingMetrics
        } onChange: { [weak self] in
            Task { @MainActor in self?.startTrafficIngest() }
        }
        guard polling else {
            guard trafficIngestTask != nil else { return }
            trafficIngestTask?.cancel()
            trafficIngestTask = nil
            // Final pass with the zeroed snapshot closes live flows.
            ingestTrafficTick()
            return
        }
        guard trafficIngestTask == nil else { return }
        trafficIngestTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.ingestTrafficTick()
            }
        }
    }

    private func ingestTrafficTick() {
        let metrics = dashboard.vpn.lastMetrics
        trafficLedger.ingest(metrics)
        ingestAppByteRates(metrics)
        inspectorHistory.ingest(metrics)
        rememberInspectorSerials(inspectorHistory.flows)
        if inspectorFlows != inspectorHistory.flows {
            inspectorFlows = inspectorHistory.flows
        }
        noteLANDevices(in: metrics.activeFlows + metrics.recentFlows)
    }

    func refreshInboundListen() {
        let next = InboundListenConfig.parse(
            from: dashboard.profiles.activeProfile?.rawConfig
        )
        if next != inboundListen {
            inboundListen = next
        }
    }

    static var preview: AppModel { AppModel(preview: true) }

    var isVPNOn: Bool {
        dashboard.status.isConnectedOrTransitioningOn
    }

    /// Precedence: capture (later) > TUN > system proxy > idle.
    var menuBarSessionState: MenuBarSessionState {
        if isVPNOn { return .tun }
        if systemProxyActive { return .systemProxy }
        return .idle
    }

    var selectedNodeLatency: Double? {
        guard let id = nodeList.selectedNodeID else { return nil }
        return nodeList.latencyByNodeID[id] ?? nil
    }

    var hasSelectedNodePing: Bool {
        guard let id = nodeList.selectedNodeID else { return false }
        return nodeList.latencyByNodeID[id] != nil
    }

    func refreshPathLatency() async {
        guard !isMeasuringPathLatency else { return }
        isMeasuringPathLatency = true
        defer { isMeasuringPathLatency = false }
        let probe = PathLatencyProbe()
        async let internet = probe.measureInternet()
        async let dns = probe.measureDNS()
        if let id = nodeList.selectedNodeID,
           let node = nodeList.profiles.nodeManager?.nodesByID[id] {
            await nodeList.ping(node)
        }
        internetLatency = await internet
        dnsLatency = await dns
    }

    /// Rebuilds the Inspector table and sidebar from the history, scope,
    /// filter, group and sort. Unchanged outputs are not re-published, so an
    /// idle history does not redraw the table.
    private func refreshInspectorRows() {
        let output = inspectorRowBuilder.build(
            InspectorRowBuilder.Input(
                flows: inspectorFlows,
                scope: inspectorScope,
                filter: inspectorFilter,
                grouping: inspectorGrouping,
                selectedGroup: inspectorSelectedGroup,
                sortOrder: inspectorSortOrder,
                lanDevices: lanDeviceByAddress,
                serials: inspectorSerials
            )
        )
        if inspectorRows != output.rows {
            inspectorRows = output.rows
        }
        if inspectorGroupRows != output.groups {
            inspectorGroupRows = output.groups
        }
        if inspectorAllCount != output.allCount {
            inspectorAllCount = output.allCount
        }
    }

    var selectedInspectorRequest: InspectorRequest? {
        guard let selectedInspectorRequestID else { return nil }
        return inspectorRows.first { $0.id == selectedInspectorRequestID }
    }

    /// Clears finished requests; open ones stay listed while they are live.
    func clearInspector() {
        inspectorHistory.clear()
        inspectorFlows = inspectorHistory.flows
        if let selected = selectedInspectorRequestID,
           !inspectorFlows.contains(where: { $0.id == selected }) {
            selectedInspectorRequestID = nil
        }
        mixedPortRuntime.clearFlows()
        Task { await dashboard.vpn.clearFlows() }
    }

    /// Tunnel snapshots may omit `serial` (old sysex). Number flows stably by UUID.
    private func rememberInspectorSerials(_ flows: [FlowRecord]) {
        for flow in flows {
            if inspectorSerials[flow.id] != nil { continue }
            if let serial = flow.serial, serial > 0 {
                inspectorSerials[flow.id] = serial
                inspectorNextSerial = max(inspectorNextSerial, serial)
            } else {
                inspectorNextSerial += 1
                inspectorSerials[flow.id] = inspectorNextSerial
            }
        }
        // Rows are built only from the current flows; forget the rest once
        // the map outgrows them so a long session does not grow it forever.
        if inspectorSerials.count > flows.count * 2 + 256 {
            let live = Set(flows.map(\.id))
            inspectorSerials = inspectorSerials.filter { live.contains($0.key) }
        }
    }

    /// Persists the active profile overlay, rebuilds the in-app catalog, and
    /// restarts a live tunnel so Packet Tunnel reads the merged rules.
    func saveOverlay(_ overlay: ProfileOverlay) {
        do {
            try dashboard.profiles.saveOverlay(overlay)
        } catch {
            // Surface persistence failures instead of silently losing rules
            // on next launch.
            TunnelLog.write(.error, "overlay save failed: \(error.localizedDescription)")
            dashboard.profiles.recordError(error)
            return
        }
        Task { await reloadLiveEgress() }
    }

    /// UI catalog already rebuilt; restart Packet Tunnel / mixed-port so the
    /// live engine matches the newly selected profile. Coalesced like other
    /// takeover flips so rapid switching cannot race stop/start.
    func didChangeActiveProfile() {
        persistOutboundMode()
        TunnelLog.write(.info, "active profile changed, reloading live egress")
        takeoverTask?.cancel()
        takeoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await reloadLiveEgress()
        }
    }

    /// Downloads a subscription (errors surface via `profiles.lastError`)
    /// and reloads the live engine when it is the active profile.
    func refreshSubscription(id: UUID) async {
        do {
            try await dashboard.profiles.refreshSubscription(id: id)
        } catch {
            TunnelLog.write(.error, "subscription refresh failed: \(error.localizedDescription)")
            return
        }
        guard dashboard.profiles.activeProfileID == id else { return }
        refreshInboundListen()
        didChangeActiveProfile()
    }

    private func reloadLiveEgress() async {
        guard tunModeEnabled || systemProxyEnabled || allowLANEnabled else { return }
        mixedPortRuntime.invalidate()
        if isVPNOn {
            dashboard.vpn.stopVPN()
            try? await Task.sleep(for: .milliseconds(400))
        }
        // Superseded by a newer takeover, which applies the latest state.
        guard !Task.isCancelled else { return }
        await applyTakeover()
    }

    func toggleConnection() async {
        await dashboard.toggleConnection()
        refreshSessionClock()
        scheduleEgressRefresh()
    }

    /// Coalesce rapid TUN / System Proxy / Allow LAN flips onto the last state
    /// so apply+restore cannot race and re-prompt.
    private func scheduleTakeover() {
        takeoverTask?.cancel()
        takeoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await applyTakeover()
        }
    }

    /// TUN → Packet Tunnel (FakeIP). System Proxy / Allow LAN → mixed-port
    /// in this process. Allow LAN can listen without setting system proxy.
    func applyTakeover() async {
        let config = dashboard.profiles.activeProfile?.rawConfig ?? VPNManager.defaultDirectConfig
        let overlay = dashboard.profiles.overlay
        refreshInboundListen()
        if tunModeEnabled {
            do {
                try await TunnelSystemExtension.activate()
                guard !Task.isCancelled, tunModeEnabled else { return }
                try await dashboard.vpn.startVPN(
                    configText: config,
                    fakeIP: true,
                    systemProxy: false,
                    allowLAN: allowLANEnabled,
                    overlay: overlay
                )
            } catch is CancellationError {
                return
            } catch {
                TunnelLog.write(.error, "TUN start failed: \(error.localizedDescription)")
                dashboard.vpn.reportHostError(error)
                tunModeEnabled = false
                dashboard.vpn.stopVPN()
            }
        } else {
            dashboard.vpn.stopVPN()
        }
        // A newer takeover was scheduled; it owns the mixed-port state.
        guard !Task.isCancelled else { return }
        if systemProxyEnabled || allowLANEnabled {
            do {
                // The runtime drops superseded requests and restores the
                // system proxy itself when an apply fails.
                try await mixedPortRuntime.apply(
                    configText: config,
                    overlay: overlay,
                    allowLAN: allowLANEnabled,
                    setSystemProxy: systemProxyEnabled
                )
                mixedPortListenError = nil
            } catch {
                mixedPortListenError = error.localizedDescription
                dashboard.vpn.reportHostError(error)
                TunnelLog.write(.error, "mixed-port failed: \(error.localizedDescription)")
            }
        } else {
            mixedPortRuntime.shutdown()
            mixedPortListenError = nil
        }
        syncMixedPortState()
        scheduleEgressRefresh()
    }

    /// Mirrors the runtime's real state into the UI and the metrics poller.
    private func syncMixedPortState() {
        let running = mixedPortRuntime.isRunning
        dashboard.vpn.localEgressActive = running
        let active = running && systemProxyEnabled
        if systemProxyActive != active {
            systemProxyActive = active
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
        mixedPortRuntime.reloadSelections()
        scheduleEgressRefresh()
    }

    func selectPolicyMember(_ memberID: String, inGroup groupName: String) {
        dashboard.selectPolicyMember(memberID, inGroup: groupName)
        mixedPortRuntime.reloadSelections()
        scheduleEgressRefresh()
    }
}

// MARK: - Presentation & shortcuts

extension AppModel {
    /// Focuses the standalone Inspector window, bringing the app forward.
    func presentInspector(using openWindow: OpenWindowAction) {
        openWindow(id: AppWindowID.inspector)
        NSApp.activate(ignoringOtherApps: true)
        DockPolicy.apply(menuBarOnly: menuBarOnly)
    }

    /// Opens Inspector grouped by App. `key` is an accounting key; nil shows All Apps.
    func presentInspectorForApp(key: String?, using openWindow: OpenWindowAction) {
        inspectorGrouping = .app
        inspectorSelectedGroup = key ?? ""
        inspectorFilter = ""
        presentInspector(using: openWindow)
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

    func presentSettings(using openWindow: OpenWindowAction) {
        presentMain(using: openWindow, selecting: .settings)
    }

    func quit() {
        mixedPortRuntime.shutdown()
        NSApplication.shared.terminate(nil)
    }

    /// Live charts and clocks only earn their keep while some surface is
    /// visible. Window close / miniaturize / occlusion all land here; the
    /// menu-bar popover reports through `menuPanelPresented`.
    private func installUIVisibilityTracking() {
        // The macOS 27 SDK dropped the Visible notifications; occlusion
        // state flips whenever a window is ordered in or out.
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Window state flips after the notification posts.
                DispatchQueue.main.async { self?.updateUIVisibility() }
            }
            uiVisibilityObservers.append(observer)
        }
        updateUIVisibility()
    }

    private func updateUIVisibility() {
        var windowVisible = false
        var panelVisible = false
        for window in NSApp.windows where window.isVisible && window.occlusionState.contains(.visible) {
            if window.styleMask.contains(.titled) {
                windowVisible = true
            } else if window.frame.height >= 50 {
                // The menu-bar popover panel; status-item label windows are
                // menu-bar height and never reach this branch.
                panelVisible = true
            }
        }
        if windowVisible != anyWindowVisible {
            anyWindowVisible = windowVisible
        }
        if panelVisible != menuPanelPresented {
            menuPanelPresented = panelVisible
        }
        dashboard.setSpeedHistoryPublishing(windowVisible || panelVisible)
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
