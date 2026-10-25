import Foundation
import Network
import NetworkExtension
import Darwin
import os
import PrizmXAttribution
import PrizmXConfig
import PrizmXCore
import PrizmXProtocols
import PrizmXTUN

/// Packet-tunnel entry point. The system instantiates this class when the
/// main app calls `NETunnelProviderManager.connection.startVPNTunnel()`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// Conservative tunnel MTU: leaves headroom for PPPoE / DS-Lite / extra
    /// encapsulation on the physical path.
    private static let tunnelMTU: NSNumber = 1400

    /// Mutable tunnel state. NE calls (`handleAppMessage`, `stopTunnel`,
    /// `sleep`, `wake`) arrive on the provider queue while the path monitor
    /// and start/stop Tasks run elsewhere, so every access goes through
    /// `shared`.
    private struct SharedState {
        var stack: TUNStack?
        var engine: Engine?
        var pumpTask: Task<Void, Never>?
        var relayTask: Task<Void, Never>?
        var pathMonitor: Network.NWPathMonitor?
        var pathRefreshTask: Task<Void, Never>?
        var metricsTask: Task<Void, Never>?
        var lastPathFingerprint: String?
        /// The `Egress` last seen, and whether a change since the open flows
        /// were last reset left them on a network that is gone.
        var lastEgress: Egress?
        var egressChanged = false
        /// When the system last went to sleep, for `wake` to tell a real
        /// sleep from a brief one.
        var sleptAt: ContinuousClock.Instant?
        var useFakeIP = true
        /// "Route All Traffic" as configured, which a reload compares against.
        var captureAllConfigured = false
        /// Whether the default route goes into the tunnel now: off when the
        /// tunnel interface is unknown or the loop breaker tripped.
        var captureAll = false
        /// The IPv6 default route too: only while the physical network has
        /// IPv6 (on an IPv4-only one there is nothing to leak around us).
        var captureIPv6 = false
        /// Loop breaker window: when it began and `TunnelEgress.loopCount` then.
        var loopWindowStart = ContinuousClock.now
        var loopWindowBase = 0
        var systemDNS: [String] = []
        var ipv6FakeIP = false
        /// The app's mixed-port listeners and the table reader that finds
        /// their clients for `ProxyClientStore`.
        var attributor: ProcessFlowAttributor?
        var proxyListenPorts: Set<UInt16> = []
        /// A config reload is building its engine.
        var reloading = false
    }

    private let shared = OSAllocatedUnfairLock(uncheckedState: SharedState())

    private var stack: TUNStack? {
        get { shared.withLockUnchecked { $0.stack } }
        set { shared.withLockUnchecked { $0.stack = newValue } }
    }
    private var engine: Engine? {
        get { shared.withLockUnchecked { $0.engine } }
        set { shared.withLockUnchecked { $0.engine = newValue } }
    }
    private var pumpTask: Task<Void, Never>? {
        get { shared.withLockUnchecked { $0.pumpTask } }
        set { shared.withLockUnchecked { $0.pumpTask = newValue } }
    }
    private var relayTask: Task<Void, Never>? {
        get { shared.withLockUnchecked { $0.relayTask } }
        set { shared.withLockUnchecked { $0.relayTask = newValue } }
    }
    private var pathMonitor: Network.NWPathMonitor? {
        get { shared.withLockUnchecked { $0.pathMonitor } }
        set { shared.withLockUnchecked { $0.pathMonitor = newValue } }
    }
    private var metricsTask: Task<Void, Never>? {
        get { shared.withLockUnchecked { $0.metricsTask } }
        set { shared.withLockUnchecked { $0.metricsTask = newValue } }
    }
    private var useFakeIP: Bool {
        get { shared.withLockUnchecked { $0.useFakeIP } }
        set { shared.withLockUnchecked { $0.useFakeIP = newValue } }
    }
    private var captureAll: Bool {
        get { shared.withLockUnchecked { $0.captureAll } }
        set { shared.withLockUnchecked { $0.captureAll = newValue } }
    }
    private var systemDNS: [String] {
        get { shared.withLockUnchecked { $0.systemDNS } }
        set { shared.withLockUnchecked { $0.systemDNS = newValue } }
    }
    private var ipv6FakeIP: Bool {
        get { shared.withLockUnchecked { $0.ipv6FakeIP } }
        set { shared.withLockUnchecked { $0.ipv6FakeIP = newValue } }
    }
    /// Engine new flows and DNS answers use. Relays read it per flow, so a
    /// config reload swaps it without touching open flows or the stack.
    private let currentEngine = EngineSlot()
    private let log = Logger(subsystem: "app.prizmx", category: "PacketTunnel")
    /// Last 1s snapshot for `handleAppMessage`; the host UI reads the kit file.
    private let lastMetrics = OSAllocatedUnfairLock(initialState: TrafficSnapshot.zero)

    // MARK: - Start

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { [weak self] in
            guard let self else {
                completionHandler(PacketTunnelError.deallocated)
                return
            }
            do {
                self.log.info("startTunnel begin")
                try await self.bootstrap(options: options)
                self.startPathMonitor()
                completionHandler(nil)
            } catch {
                TunnelEgress.avoid(nil)
                TunnelLog.write(.error, "startTunnel failed: \(error.localizedDescription)")
                self.log.error("startTunnel failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
    }

    private func bootstrap(options: [String: NSObject]?) async throws {
        // 1. Read Clash / sing-box text from the App Group file referenced
        //    by `configPath` in providerConfiguration.
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        var provider = proto?.providerConfiguration ?? [:]
        if let options {
            for (key, value) in options { provider[key] = value }
        }
        if let root = provider[TunnelProviderKeys.containerPath] as? String {
            TunnelLog.bind(kitRoot: URL(fileURLWithPath: root))
            log.info("bound kitRoot=\(root, privacy: .public)")
        } else {
            log.error("containerPath missing")
        }
        let boot = ExtensionBootstrap(
            providerConfiguration: provider,
            options: nil
        )
        let useFakeIP = boot.useFakeIP
        let systemDNS = boot.systemDNS
        self.useFakeIP = useFakeIP
        self.systemDNS = systemDNS
        // Our own dials must never take the default route into the tunnel.
        // Without the tunnel's interface there is no way to keep them off,
        // so the experiment stays off.
        var captureAll = boot.captureAllTraffic
        if captureAll {
            if let tunnel = virtualInterface {
                TunnelEgress.avoid(tunnel)
            } else {
                captureAll = false
                TunnelLog.write(.error, "route all traffic skipped: the tunnel interface is unknown")
            }
        }
        let captureIPv6 = captureAll && Self.physicalNetworkHasIPv6()
        shared.withLockUnchecked { state in
            state.captureAllConfigured = boot.captureAllTraffic
            state.captureAll = captureAll
            state.captureIPv6 = captureIPv6
            // `avoid` above restarted `TunnelEgress.loopCount` at zero.
            state.loopWindowStart = .now
            state.loopWindowBase = 0
        }
        let pinPreview = boot.pinnedNodeAddresses.map { "\($0.key)→\($0.value.map(\.description))" }.sorted().joined(separator: ",")
        let configBytes = boot.configText?.utf8.count ?? 0
        let kitRoot = TunnelLog.kitRoot?.path ?? "-"
        log.info("tunnel starting configBytes=\(configBytes) fakeIP=\(useFakeIP, privacy: .public)")
        TunnelLog.write(
            .info,
            "tunnel starting configBytes=\(configBytes) fakeIP=\(useFakeIP) appDNS=\(systemDNS)"
        )
        TunnelLog.write(
            .info,
            "tunnel pins=\(pinPreview) selections=\(PolicySelectionStore.load()) kitRoot=\(kitRoot)"
        )
        if boot.configText == nil {
            log.error("config missing — outbound will be DIRECT-only")
            TunnelLog.write(.error, "config missing — extension cannot read the kit; outbound will be DIRECT-only")
        }

        let attributor = ProcessFlowAttributor()
        let engine = try boot.makeEngine(flowAttributor: attributor)
        // Same profile the app's SystemProxyRuntime listens with.
        let listenPorts = Set(InboundListenConfig.parse(from: boot.configText).sockets.map(\.port))
        shared.withLockUnchecked { state in
            state.attributor = attributor
            state.proxyListenPorts = listenPorts
        }
        self.ipv6FakeIP = engine.dns.settings.ipv6
        let nodeCount = engine.nodeManager.nodesByID.count
        log.info("engine ready rules=\(engine.router.rules.count) nodes=\(nodeCount)")
        TunnelLog.write(
            .info,
            "engine ready rules=\(engine.router.rules.count) nodes=\(nodeCount) groups=\(engine.nodeManager.groupsByName.count)"
        )
        let attributionProbe = AttributionProbe.run(attributor: attributor)
        TunnelLog.write(.info, attributionProbe.summary)

        // 2. SwiftTCP stack wired to the engine; packet emitter + relays.
        try await startStackAndRelays(engine: engine)

        // Mixed-port lives in the main app (SystemProxyRuntime). Hosting it
        // inside the Packet Tunnel requires a dummy VPN that steals the
        // default route when TUN is off.

        // 3. Virtual NIC: FakeIP 198.18.0.0/16 only. DIRECT FakeIP flows
        // splice to real IPs in userspace (those IPs are not in this CIDR).
        // "Route All Traffic" takes the default route as well.
        let settings = Self.makeNetworkSettings(
            useFakeIP: useFakeIP,
            dnsServers: systemDNS,
            ipv6: engine.dns.settings.ipv6,
            captureAll: captureAll,
            captureIPv6: captureIPv6
        )
        do {
            try await setTunnelNetworkSettings(settings)
        } catch {
            // Roll back the already-started stack/relay; NE keeps the process
            // alive after a failed start, so leaking them would leave a
            // running engine with no virtual NIC.
            relayTask?.cancel()
            relayTask = nil
            await self.stack?.stop()
            self.stack = nil
            self.engine = nil
            currentEngine.set(nil)
            TunnelEgress.avoid(nil)
            throw error
        }

        // 4. Pump TUN packets into SwiftTCP.
        pumpTask = Task { [weak self] in
            await self?.runPacketPump()
        }
        let ipv6 = !captureIPv6
            ? "IPv4; no IPv6 on this network"
            : (engine.allowsIPv6 ? "IPv4 + IPv6" : "IPv4; IPv6 refused by ipv6: false")
        let route = captureAll
            ? "all via \(virtualInterface?.name ?? "?") (\(ipv6))"
            : (useFakeIP ? "198.18.0.0/16" : "none")
        TunnelLog.write(.info, "tunnel started fakeIP=\(useFakeIP) route=\(route)")
        log.info("tunnel started fakeIP=\(useFakeIP, privacy: .public) (SwiftTCP)")
        TunnelLifecycleStore.markStarted()
        startMetricsDump()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let request = try? TunnelIPC.decodeRequest(from: messageData) else {
            completionHandler?(nil)
            return
        }
        switch request.method {
        case .fetchMetrics:
            reply(.success(metrics: lastMetrics.withLock { $0 }), completionHandler)
        case .selectNode:
            guard let nodeID = request.nodeID, let group = request.groupName else {
                completionHandler?(try? TunnelIPC.encode(.failure("selectNode missing nodeID/groupName")))
                return
            }
            let engine = self.engine
            do {
                try engine?.nodeManager.select(nodeID: nodeID, inGroup: group)
                engine?.applyGlobalGroup(group)
                TunnelLog.write(.info, "select \(group) → \(nodeID)")
                completionHandler?(try? TunnelIPC.encode(.success()))
            } catch {
                TunnelLog.write(.error, "select \(group) → \(nodeID) failed: \(error.localizedDescription)")
                completionHandler?(try? TunnelIPC.encode(.failure(error.localizedDescription)))
            }
        case .setOutboundMode:
            guard let raw = request.outboundMode, let mode = OutboundMode(rawValue: raw) else {
                completionHandler?(try? TunnelIPC.encode(.failure("setOutboundMode missing mode")))
                return
            }
            engine?.setOutboundMode(mode, globalGroup: request.groupName)
            completionHandler?(try? TunnelIPC.encode(.success()))
        case .setCaptureMode:
            let (fakeIP, captureAll, captureIPv6) = shared.withLockUnchecked { state -> (Bool, Bool, Bool) in
                let next = request.fakeIP ?? state.useFakeIP
                state.useFakeIP = next
                return (next, state.captureAll, state.captureIPv6)
            }
            Task { [weak self] in
                guard let self else {
                    completionHandler?(try? TunnelIPC.encode(.failure("deallocated")))
                    return
                }
                do {
                    let settings = Self.makeNetworkSettings(
                        useFakeIP: fakeIP,
                        dnsServers: self.systemDNS,
                        ipv6: self.ipv6FakeIP,
                        captureAll: captureAll,
                        captureIPv6: captureIPv6
                    )
                    try await self.setTunnelNetworkSettings(settings)
                    TunnelLog.write(.info, "capture mode fakeIP=\(fakeIP)")
                    completionHandler?(try? TunnelIPC.encode(.success()))
                } catch {
                    completionHandler?(try? TunnelIPC.encode(.failure(error.localizedDescription)))
                }
            }
        case .clearFlows:
            engine?.traffic.clearRecent()
            completionHandler?(try? TunnelIPC.encode(.success()))
        case .reloadConfig:
            guard let data = request.providerConfiguration,
                  let payload = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else {
                completionHandler?(try? TunnelIPC.encode(.failure("reloadConfig missing providerConfiguration")))
                return
            }
            let box = UncheckedSendableBox(payload)
            Task { [weak self] in
                guard let self else {
                    completionHandler?(try? TunnelIPC.encode(.failure("deallocated")))
                    return
                }
                self.reply(await self.reloadEngine(with: box.value), completionHandler)
            }
        }
    }

    /// Builds an engine from `payload` and swaps it in. The SwiftTCP stack,
    /// its FakeIP table and every open flow stay; only new flows use the new
    /// rules. A change to the virtual NIC (FakeIP / IPv6) needs a restart.
    private func reloadEngine(with payload: [String: Any]) async -> TunnelIPC.Response {
        // One at a time: two overlapping swaps would each stop the same old
        // engine and leave the other's url-test running.
        let claimed = shared.withLockUnchecked { state -> Bool in
            guard !state.reloading else { return false }
            state.reloading = true
            return true
        }
        guard claimed else { return .failure("a reload is already in progress") }
        defer { shared.withLockUnchecked { $0.reloading = false } }
        guard let stack, let oldEngine = engine else {
            return .failure("tunnel is not running")
        }
        let boot = ExtensionBootstrap(providerConfiguration: payload, options: nil)
        guard boot.useFakeIP == useFakeIP else {
            return .failure("restart required: capture mode changed")
        }
        let configured = shared.withLockUnchecked { $0.captureAllConfigured }
        guard boot.captureAllTraffic == configured else {
            return .failure("restart required: Route All Traffic changed")
        }
        let attributor = shared.withLockUnchecked { $0.attributor }
        let next: Engine
        do {
            next = try boot.makeEngine(flowAttributor: attributor, traffic: oldEngine.traffic)
        } catch {
            TunnelLog.write(.error, "reload failed: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
        guard next.dns.settings.ipv6 == ipv6FakeIP else {
            return .failure("restart required: IPv6 changed")
        }
        let listenPorts = Set(InboundListenConfig.parse(from: boot.configText).sockets.map(\.port))
        // Swap only if the tunnel is still the one this reload started on:
        // a stop (or restart) while the engine was building wins.
        let swapped = shared.withLockUnchecked { state -> Bool in
            guard state.stack === stack, state.engine === oldEngine else { return false }
            state.engine = next
            state.proxyListenPorts = listenPorts
            if !boot.systemDNS.isEmpty { state.systemDNS = boot.systemDNS }
            return true
        }
        guard swapped else { return .failure("the tunnel changed during the reload") }
        currentEngine.set(next)
        await stack.updateResolution(
            fakeIPFilter: next.dns.settings.fakeIPFilter,
            dns: next.dns,
            carriesIPv6: next.allowsIPv6
        )
        oldEngine.stopURLTest()
        next.startURLTest()
        TunnelLog.write(
            .info,
            "engine reloaded rules=\(next.router.rules.count) nodes=\(next.nodeManager.nodesByID.count) groups=\(next.nodeManager.groupsByName.count) ipv6=\(next.allowsIPv6 ? "carried" : "refused (ipv6: false)")"
        )
        return .success()
    }

    // MARK: - Stop

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        // A user stop (Settings toggle / app) runs this; a pkd/launchd SIGTERM
        // does not. Record first so the app can tell the two apart.
        TunnelLifecycleStore.markStopped(reason: reason.rawValue)
        Task { [weak self] in
            await self?.shutdown()
            completionHandler()
        }
    }

    /// A sleep at least this long resets the open flows on wake.
    private static let resetAfterSleep: Duration = .seconds(60)

    override func sleep(completionHandler: @escaping () -> Void) {
        shared.withLockUnchecked { $0.sleptAt = ContinuousClock.now }
        completionHandler()
    }

    override func wake() {
        let slept = shared.withLockUnchecked { state -> Duration? in
            defer { state.sleptAt = nil }
            return state.sleptAt.map { ContinuousClock.now - $0 }
        }
        let reason = slept.map { "wake after \($0.components.seconds)s" } ?? "wake"
        // Flows idle through a real sleep may be dead (NAT or server
        // timeouts). A brief one, such as the nap between maintenance (dark)
        // wakes, which call this too, leaves them: a reset would only cut
        // what apps just opened.
        let resets = slept.map { $0 >= Self.resetAfterSleep } ?? true
        Task { [weak self] in
            await self?.refreshAfterPathChange(reason: reason)
            if resets { await self?.resetFlows(reason: reason) }
        }
    }

    private func shutdown() async {
        let taken = shared.withLockUnchecked { state -> SharedState in
            let snapshot = state
            state.pathMonitor = nil
            state.pathRefreshTask = nil
            state.pumpTask = nil
            state.relayTask = nil
            state.engine = nil
            state.stack = nil
            state.attributor = nil
            return snapshot
        }
        currentEngine.set(nil)
        taken.pathMonitor?.cancel()
        taken.pathRefreshTask?.cancel()
        stopMetricsDump()
        taken.pumpTask?.cancel()
        taken.relayTask?.cancel()
        taken.engine?.stopURLTest()
        await taken.stack?.stop()
        TunnelEgress.avoid(nil)
        TunnelLog.write(.info, "tunnel stopped")
        log.info("tunnel stopped")
    }

    /// Writes counters to the kit every 1s. Do not also `snapshot()` from
    /// `handleAppMessage` — that call resets the rate window.
    private func startMetricsDump() {
        publishMetrics()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.publishMetrics()
            }
        }
        let previous = shared.withLockUnchecked { state -> Task<Void, Never>? in
            let old = state.metricsTask
            state.metricsTask = task
            return old
        }
        previous?.cancel()
    }

    private func stopMetricsDump() {
        let task = shared.withLockUnchecked { state -> Task<Void, Never>? in
            let old = state.metricsTask
            state.metricsTask = nil
            return old
        }
        task?.cancel()
        lastMetrics.withLock { $0 = .zero }
        TunnelMetricsStore.clear()
        ProxyClientStore.clear()
    }

    private func publishMetrics() {
        var snapshot = engine?.traffic.snapshot() ?? .zero
        // The app shows which member each url-test / fallback group uses.
        snapshot.groupSelections = engine?.nodeManager.autoSelections() ?? [:]
        lastMetrics.withLock { $0 = snapshot }
        if !TunnelMetricsStore.save(snapshot) {
            TunnelLog.write(.error, "metrics file write failed")
        }
        publishProxyClients()
        breakEgressLoops()
    }

    /// Loops within `loopWindow` that turn "Route All Traffic" off.
    private static let loopTripCount = 20
    private static let loopWindow: Duration = .seconds(10)

    /// Falls back to FakeIP-only routes when PrizmX's own connections keep
    /// coming back through the tunnel, so a binding that does not hold
    /// cannot take the Mac offline. Each loop is already refused on its own;
    /// this stops the dials that would fail meanwhile.
    private func breakEgressLoops() {
        let total = TunnelEgress.loopCount
        let tripped = shared.withLockUnchecked { state -> Int? in
            guard state.captureAll else { return nil }
            let now = ContinuousClock.now
            if now - state.loopWindowStart >= Self.loopWindow {
                state.loopWindowStart = now
                state.loopWindowBase = total
            }
            let recent = total - state.loopWindowBase
            guard recent >= Self.loopTripCount else { return nil }
            state.captureAll = false
            return recent
        }
        guard let tripped else { return }
        TunnelLog.write(
            .error,
            "route all traffic turned off: \(tripped) PrizmX connections came back through the tunnel within 10 s"
        )
        Task { await self.refreshAfterPathChange(reason: "egress loop") }
    }

    /// Root sees every socket; the app attributes the mixed-port
    /// flows it could not place from this file. Written even when empty, so
    /// the app can tell a missing client from a tunnel that is not publishing.
    private func publishProxyClients() {
        let (attributor, ports) = shared.withLockUnchecked { ($0.attributor, $0.proxyListenPorts) }
        guard let attributor else { return }
        // Stamped before the table read: every socket opened before this
        // instant is in the list if it is still alive (the app relies on it).
        let readAt = Date().timeIntervalSince1970
        ProxyClientStore.save(attributor.loopbackClients(listenPorts: ports), writtenAt: readAt)
    }

    private func reply(
        _ response: TunnelIPC.Response,
        _ completionHandler: ((Data?) -> Void)?
    ) {
        do {
            completionHandler?(try TunnelIPC.encode(response))
        } catch {
            TunnelLog.write(.error, "IPC encode failed: \(error.localizedDescription)")
            completionHandler?(nil)
        }
    }

    // MARK: - Physical path

    /// FakeIP captures DNS at start. After a Wi-Fi / Ethernet / hotspot
    /// switch the old LAN resolver is a blackhole until we rebase.
    private func startPathMonitor() {
        let monitor = Network.NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.notePath(path) }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func notePath(_ path: Network.NWPath) async {
        let fingerprint = Self.pathFingerprint(path)
        let egress = Egress(path)
        let changed = shared.withLockUnchecked { state -> Bool in
            let isFirst = state.lastPathFingerprint == nil
            let egressMoved = state.lastEgress.map { egress.strands(flowsOn: $0) } ?? false
            if egressMoved { state.egressChanged = true }
            state.lastEgress = egress
            if fingerprint == state.lastPathFingerprint, !egressMoved { return false }
            state.lastPathFingerprint = fingerprint
            return !isFirst
        }
        guard changed else { return }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refreshAfterPathChange(reason: "path \(fingerprint)")
            await self?.resetFlows(reason: "network changed", onlyIfEgressChanged: true)
        }
        let previous = shared.withLockUnchecked { state -> Task<Void, Never>? in
            let old = state.pathRefreshTask
            state.pathRefreshTask = task
            return old
        }
        previous?.cancel()
    }

    private func refreshAfterPathChange(reason: String) async {
        guard let engine else { return }
        let captured = PhysicalDNSSnapshot.capture()
        engine.dns.applyPhysicalDNS(captured)
        // The new network may have IPv6 or lack it.
        let physicalIPv6 = Self.physicalNetworkHasIPv6()
        let (fakeIP, dnsServers, ipv6, captureAll, captureIPv6) = shared.withLockUnchecked { state in
            if !captured.isEmpty {
                state.systemDNS = captured
            }
            state.captureIPv6 = state.captureAll && physicalIPv6
            return (state.useFakeIP, state.systemDNS, state.ipv6FakeIP, state.captureAll, state.captureIPv6)
        }
        TunnelLog.write(.info, "path refresh (\(reason)) dns=\(captured)\(captureAll ? " ipv6=\(captureIPv6)" : "")")
        log.info("path refresh (\(reason, privacy: .public)) dns=\(captured, privacy: .public)")
        let settings = Self.makeNetworkSettings(
            useFakeIP: fakeIP,
            dnsServers: dnsServers,
            ipv6: ipv6,
            captureAll: captureAll,
            captureIPv6: captureIPv6
        )
        do {
            try await setTunnelNetworkSettings(settings)
        } catch {
            TunnelLog.write(.error, "path refresh settings: \(error.localizedDescription)")
        }
    }

    /// Resets the open flows so apps reconnect over the current network.
    /// Their sockets sit on the utun, whose address never changes, so they
    /// would keep waiting on outbounds the old network left behind.
    /// `onlyIfEgressChanged`: only when the network flows leave by changed.
    private func resetFlows(reason: String, onlyIfEgressChanged: Bool = false) async {
        let due = shared.withLockUnchecked { state -> Bool in
            defer { state.egressChanged = false }
            return state.egressChanged || !onlyIfEgressChanged
        }
        guard due, let stack else { return }
        let reset = await stack.resetFlows()
        TunnelLog.write(.info, "reset \(reset.tcp) TCP and \(reset.udp) UDP flows (\(reason))")
        log.info("reset \(reset.tcp) TCP and \(reset.udp) UDP flows (\(reason, privacy: .public))")
    }

    /// Ignore utun so bringing the tunnel up is not itself a "network change".
    private static func pathFingerprint(_ path: Network.NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map(\.name)
            .filter { !isTunnelInterface($0) }
            .sorted()
            .joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        return "\(path.status)|exp=\(path.isExpensive)|if=\(interfaces)|gw=\(gateways)"
    }

    /// What open flows leave by: the path's status, the preferred
    /// interface and the gateways.
    private struct Egress {
        let status: String
        let interface: String?
        let gateways: Set<String>

        init(_ path: Network.NWPath) {
            status = "\(path.status)"
            interface = path.availableInterfaces
                .first { !PacketTunnelProvider.isTunnelInterface($0.name) }?.name
            gateways = Set(path.gateways.map { "\($0)" })
        }

        /// Whether flows opened on `old` may now sit on a network that is
        /// gone: the status or the preferred interface changed, or a gateway
        /// went away. Another interface coming or going, or a gateway only
        /// added (the IPv6 router advertising after DHCP), leaves them
        /// working, so it refreshes DNS but resets nothing.
        func strands(flowsOn old: Egress) -> Bool {
            status != old.status || interface != old.interface || !gateways.isSuperset(of: old.gateways)
        }
    }

    private static func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec")
    }

    // MARK: - Packet pump

    private func runPacketPump() async {
        while !Task.isCancelled {
            let packets: [Data] = await withCheckedContinuation { continuation in
                self.packetFlow.readPackets { packets, _ in
                    continuation.resume(returning: packets)
                }
            }
            guard let stack else { return }
            await stack.input(packets: packets)
        }
    }

    /// Starts SwiftTCP on the virtual NIC and splices streams through Engine.
    private func startStackAndRelays(engine: Engine) async throws {
        // `NEPacketTunnelFlow.writePackets` is thread-safe; the wrapper is
        // `@unchecked Sendable` because the system type is not Sendable.
        let flow = packetFlow
        currentEngine.set(engine)
        let current = currentEngine
        let stack = TUNStack(
            fakeIP: useFakeIP ? FakeIPAllocator() : nil,
            fakeIPFilter: engine.dns.settings.fakeIPFilter,
            dns: engine.dns,
            dnsPolicy: { host in await current.engine?.dnsPolicy(host: host) },
            ipv6: engine.dns.settings.ipv6,
            // Clash `ipv6`: relay the IPv6 routed here, or refuse it.
            carriesIPv6: engine.allowsIPv6,
            onOutput: { packets in
                guard !packets.isEmpty else { return }
                let protocols = packets.map { packet -> NSNumber in
                    if packet.first.map({ $0 >> 4 }) == 6 {
                        return NSNumber(value: AF_INET6)
                    }
                    return NSNumber(value: AF_INET)
                }
                flow.writePackets(packets, withProtocols: protocols)
            }
        )
        await stack.start()
        self.stack = stack
        self.engine = engine

        // Accept SwiftTCP streams and splice each one through Engine
        // (DIRECT / Shadowsocks / VLESS) with structured concurrency. Each
        // flow takes the engine current when it opens (config reloads).
        engine.startURLTest()
        relayTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await stream in await stack.tcpConnections() {
                        let engine = current.engine ?? engine
                        Task {
                            await EngineTCPRelay.pipe(stream: stream, engine: engine)
                        }
                    }
                }
                group.addTask {
                    await TUNUDPRelay.run(stack: stack, engineProvider: { current.engine ?? engine })
                }
            }
        }
    }

    // MARK: - Virtual NIC

    public static func makeNetworkSettings(
        useFakeIP: Bool,
        dnsServers: [String]?,
        ipv6: Bool = false,
        captureAll: Bool = false,
        captureIPv6: Bool = false
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = Self.tunnelMTU
        let captureAll = useFakeIP && captureAll
        let captureIPv6 = captureAll && captureIPv6

        if useFakeIP {
            // Surge-style FakeIP capture: only 198.18.0.0/16 enters the TUN.
            // DIRECT is spliced to a real IP in userspace — not in this CIDR —
            // so it leaves via the kernel NIC without hairpin.
            let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
            ipv4.includedRoutes = [
                NEIPv4Route(destinationAddress: "198.18.0.0", subnetMask: "255.255.0.0")
            ]
            if captureAll {
                // Every app, also those that dial IP addresses. Our own dials
                // stay off the tunnel through `TunnelEgress`.
                ipv4.includedRoutes = [NEIPv4Route.default()]
                ipv4.excludedRoutes = Self.localIPv4Routes
            }
            settings.ipv4Settings = ipv4
        } else {
            // System Proxy only: keep the extension alive with a /32 address
            // and no included routes. A /16 address here is on-link and steals
            // 198.18.0.0/16 (and on some macOS builds the default route).
            let ipv4 = NEIPv4Settings(
                addresses: ["198.18.0.1"],
                subnetMasks: ["255.255.255.255"]
            )
            ipv4.includedRoutes = [
                NEIPv4Route(
                    destinationAddress: "198.18.0.1",
                    subnetMask: "255.255.255.255"
                )
            ]
            settings.ipv4Settings = ipv4
        }

        if useFakeIP, ipv6 || captureIPv6 {
            let ipv6Settings = NEIPv6Settings(
                addresses: [FakeIPAllocator.gateway6.description],
                networkPrefixLengths: [64]
            )
            ipv6Settings.includedRoutes = [
                NEIPv6Route(
                    destinationAddress: FakeIPAllocator.network6.description,
                    networkPrefixLength: 64
                )
            ]
            if captureIPv6 {
                // IPv6 too, or it would leave around the tunnel. The stack
                // relays it like IPv4, or refuses it (TCP gets a RST, apps
                // use IPv4) when the profile sets `ipv6: false`. The FakeIPv6
                // /64 stays included: it sits inside the excluded
                // unique-local fc00::/7.
                ipv6Settings.includedRoutes?.append(NEIPv6Route.default())
                ipv6Settings.excludedRoutes = Self.localIPv6Routes
            }
            settings.ipv6Settings = ipv6Settings
        }

        if useFakeIP {
            var resolvers = ["198.18.0.2"]
            if ipv6 {
                resolvers.append(FakeIPAllocator.dns6.description)
            }
            let dns = NEDNSSettings(servers: resolvers)
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }
        return settings
    }
}

extension PacketTunnelProvider {
    /// A global IPv6 address (2000::/3) on an interface that is up and not
    /// a tunnel. A path monitor cannot tell: with the tunnel holding the
    /// IPv6 default route it reports the tunnel's IPv6, even with VPN
    /// interfaces prohibited.
    static func physicalNetworkHasIPv6() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        let tunnels = ["utun", "ipsec", "gif", "stf", "lo"]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET6)
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard !tunnels.contains(where: { name.hasPrefix($0) }) else { continue }
            let firstByte = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_addr.__u6_addr.__u6_addr8.0
            }
            if firstByte & 0xE0 == 0x20 { return true }
        }
        return false
    }

    /// Stays on the physical network with "Route All Traffic": private,
    /// link-local, multicast and broadcast (LAN devices, the router, mDNS).
    static let localIPv4Routes = [
        NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
        NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
        NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
        NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
        NEIPv4Route(destinationAddress: "255.255.255.255", subnetMask: "255.255.255.255"),
    ]

    /// Link-local, unique-local and multicast.
    static let localIPv6Routes = [
        NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10),
        NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7),
        NEIPv6Route(destinationAddress: "ff00::", networkPrefixLength: 8),
    ]
}

enum PacketTunnelError: Error {
    case deallocated
}

/// The engine relays hand new flows to; swapped by a config reload.
final class EngineSlot: Sendable {
    private let box = OSAllocatedUnfairLock<Engine?>(initialState: nil)

    var engine: Engine? { box.withLock { $0 } }

    func set(_ engine: Engine?) {
        box.withLock { $0 = engine }
    }
}

/// Carries a non-Sendable value (a property-list dictionary) into a Task
/// that is its only user.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
