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

    private var stack: TUNStack?
    private var engine: Engine?
    private var pumpTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var pathMonitor: Network.NWPathMonitor?
    private var pathRefreshTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var lastPathFingerprint: String?
    private var useFakeIP = true
    private var systemDNS: [String] = []
    private var ipv6FakeIP = false
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
            TunnelLog.write(.error, "config missing — extension cannot read staged kit; outbound will be DIRECT-only")
        }

        let attributor = ProcessFlowAttributor()
        let engine = try boot.makeEngine(flowAttributor: attributor)
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
        try await startStackAndRelays(engine: engine, attributor: attributor)

        // Mixed-port lives in the main app (SystemProxyRuntime). Hosting it
        // inside the Packet Tunnel requires a dummy VPN that steals the
        // default route when TUN is off.

        // 3. Virtual NIC: FakeIP 198.18.0.0/16 only. DIRECT FakeIP flows
        // splice to real IPs in userspace (those IPs are not in this CIDR).
        let settings = Self.makeNetworkSettings(
            useFakeIP: useFakeIP,
            dnsServers: systemDNS,
            ipv6: engine.dns.settings.ipv6
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
            throw error
        }

        // 4. Pump TUN packets into SwiftTCP.
        pumpTask = Task { [weak self] in
            await self?.runPacketPump()
        }
        TunnelLog.write(.info, "tunnel started fakeIP=\(useFakeIP) route=\(useFakeIP ? "198.18.0.0/16" : "default")")
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
            do {
                try engine?.nodeManager.select(nodeID: nodeID, inGroup: group)
                PolicySelectionStore.set(nodeID, inGroup: group)
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
            OutboundModeStore.save(mode: mode, globalGroup: request.groupName)
            completionHandler?(try? TunnelIPC.encode(.success()))
        case .setCaptureMode:
            let fakeIP = request.fakeIP ?? self.useFakeIP
            self.useFakeIP = fakeIP
            Task { [weak self] in
                guard let self else {
                    completionHandler?(try? TunnelIPC.encode(.failure("deallocated")))
                    return
                }
                do {
                    let settings = Self.makeNetworkSettings(
                        useFakeIP: fakeIP,
                        dnsServers: self.systemDNS,
                        ipv6: self.ipv6FakeIP
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
        }
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

    override func wake() {
        Task { [weak self] in
            await self?.refreshAfterPathChange(reason: "wake")
        }
    }

    private func shutdown() async {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathRefreshTask?.cancel()
        pathRefreshTask = nil
        stopMetricsDump()
        pumpTask?.cancel()
        relayTask?.cancel()
        pumpTask = nil
        relayTask = nil
        engine?.stopURLTest()
        engine = nil
        await stack?.stop()
        stack = nil
        TunnelLog.write(.info, "tunnel stopped")
        log.info("tunnel stopped")
    }

    /// Writes counters to the kit every 1s. Do not also `snapshot()` from
    /// `handleAppMessage` — that call resets the rate window.
    private func startMetricsDump() {
        publishMetrics()
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.publishMetrics()
            }
        }
    }

    private func stopMetricsDump() {
        metricsTask?.cancel()
        metricsTask = nil
        lastMetrics.withLock { $0 = .zero }
        TunnelMetricsStore.clear()
    }

    private func publishMetrics() {
        let snapshot = engine?.traffic.snapshot() ?? .zero
        lastMetrics.withLock { $0 = snapshot }
        if !TunnelMetricsStore.save(snapshot) {
            TunnelLog.write(.error, "metrics file write failed")
        }
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
        if fingerprint == lastPathFingerprint { return }
        let isFirst = lastPathFingerprint == nil
        lastPathFingerprint = fingerprint
        if isFirst { return }
        pathRefreshTask?.cancel()
        pathRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refreshAfterPathChange(reason: "path \(fingerprint)")
        }
    }

    private func refreshAfterPathChange(reason: String) async {
        guard engine != nil else { return }
        let captured = PhysicalDNSSnapshot.capture()
        engine?.dns.applyPhysicalDNS(captured)
        if !captured.isEmpty {
            systemDNS = captured
        }
        TunnelLog.write(.info, "path refresh (\(reason)) dns=\(captured)")
        log.info("path refresh (\(reason, privacy: .public)) dns=\(captured, privacy: .public)")
        let settings = Self.makeNetworkSettings(
            useFakeIP: useFakeIP,
            dnsServers: systemDNS,
            ipv6: ipv6FakeIP
        )
        do {
            try await setTunnelNetworkSettings(settings)
        } catch {
            TunnelLog.write(.error, "path refresh settings: \(error.localizedDescription)")
        }
    }

    /// Ignore utun so bringing the tunnel up is not itself a "network change".
    private static func pathFingerprint(_ path: Network.NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map(\.name)
            .filter { !$0.hasPrefix("utun") && !$0.hasPrefix("ipsec") }
            .sorted()
            .joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        return "\(path.status)|exp=\(path.isExpensive)|if=\(interfaces)|gw=\(gateways)"
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
    private func startStackAndRelays(
        engine: Engine,
        attributor: ProcessFlowAttributor
    ) async throws {
        // `NEPacketTunnelFlow.writePackets` is thread-safe; the wrapper is
        // `@unchecked Sendable` because the system type is not Sendable.
        let flow = packetFlow
        let stack = TUNStack(
            fakeIP: useFakeIP ? FakeIPAllocator() : nil,
            fakeIPFilter: engine.dns.settings.fakeIPFilter,
            dns: engine.dns,
            dnsPolicy: { host in await engine.dnsPolicy(host: host) },
            ipv6: engine.dns.settings.ipv6,
            flowAttributor: attributor,
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
        // (DIRECT / Shadowsocks / VLESS) with structured concurrency.
        let engineRef = engine
        engine.startURLTest()
        relayTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await stream in await stack.tcpConnections() {
                        Task {
                            await EngineTCPRelay.pipe(stream: stream, engine: engineRef)
                        }
                    }
                }
                group.addTask {
                    await TUNUDPRelay.run(stack: stack, engine: engineRef)
                }
            }
        }
    }

    // MARK: - Virtual NIC

    public static func makeNetworkSettings(
        useFakeIP: Bool,
        dnsServers: [String]?,
        ipv6: Bool = false
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = Self.tunnelMTU

        if useFakeIP {
            // Surge-style FakeIP capture: only 198.18.0.0/16 enters the TUN.
            // DIRECT is spliced to a real IP in userspace — not in this CIDR —
            // so it leaves via the kernel NIC without hairpin.
            let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
            ipv4.includedRoutes = [
                NEIPv4Route(destinationAddress: "198.18.0.0", subnetMask: "255.255.0.0")
            ]
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

        if useFakeIP, ipv6 {
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

enum PacketTunnelError: Error {
    case deallocated
}
