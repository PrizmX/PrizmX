import Foundation
import NetworkExtension
import Darwin
import os
import PrizmXConfig
import PrizmXCore
import PrizmXProtocols
import PrizmXTUN

/// Packet-tunnel entry point. The system instantiates this class when the
/// main app calls `NETunnelProviderManager.connection.startVPNTunnel()`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var stack: TUNStack?
    private var engine: Engine?
    private var mixedPort: MixedPortServer?
    private var pumpTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var useFakeIP = true
    private var systemProxy = false
    private var allowLAN = false
    private var mixedPortNumber = MixedPortServer.defaultPort
    private var systemDNS: [String] = []
    private var ipv6FakeIP = false
    private let log = Logger(subsystem: "app.prizmx", category: "PacketTunnel")

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
                try await self.bootstrap(options: options)
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
        let boot = ExtensionBootstrap(
            providerConfiguration: proto?.providerConfiguration,
            options: options?.mapValues { $0 }
        )
        let useFakeIP = boot.useFakeIP
        let systemDNS = boot.systemDNS
        self.useFakeIP = useFakeIP
        self.systemProxy = boot.systemProxy
        self.allowLAN = boot.allowLAN
        self.mixedPortNumber = boot.mixedPort
        self.systemDNS = systemDNS
        let pinPreview = boot.pinnedNodeAddresses.map { "\($0.key)→\($0.value.map(\.description))" }.sorted().joined(separator: ",")
        TunnelLog.write(
            .info,
            "tunnel starting configBytes=\(boot.configText?.utf8.count ?? 0) fakeIP=\(useFakeIP) appDNS=\(systemDNS) pinned=\(pinPreview) selections=\(PolicySelectionStore.load())"
        )

        let engine = try boot.makeEngine()
        self.ipv6FakeIP = engine.dns.settings.ipv6
        TunnelLog.write(
            .info,
            "engine ready rules=\(engine.router.rules.count) nodes=\(engine.nodeManager.nodesByID.count) groups=\(engine.nodeManager.groupsByName.count)"
        )

        // 2. Wire the packet emitter. `NEPacketTunnelFlow.writePackets` is
        //    thread-safe; the wrapper is `@unchecked Sendable` because the
        //    system type is not marked Sendable.
        let flow = packetFlow
        let stack = TUNStack(
            fakeIP: useFakeIP ? FakeIPAllocator() : nil,
            fakeIPFilter: engine.dns.settings.fakeIPFilter,
            dns: engine.dns,
            dnsPolicy: { host in await engine.dnsPolicy(host: host) },
            ipv6: engine.dns.settings.ipv6,
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

        try await applyMixedPort(
            engine: engine,
            enabled: boot.systemProxy,
            port: boot.mixedPort,
            allowLAN: boot.allowLAN
        )

        // 3. Virtual NIC: FakeIP 198.18.0.0/16 only (Direct uses kernel).
        // System Proxy without TUN uses a dummy /32 so nothing is captured.
        let settings = Self.makeNetworkSettings(
            useFakeIP: useFakeIP,
            systemProxy: boot.systemProxy,
            mixedPort: boot.mixedPort,
            dnsServers: systemDNS,
            ipv6: engine.dns.settings.ipv6
        )
        try await setTunnelNetworkSettings(settings)

        // 4. Pump TUN packets into SwiftTCP.
        pumpTask = Task { [weak self] in
            await self?.runPacketPump()
        }
        TunnelLog.write(.info, "tunnel started fakeIP=\(useFakeIP) route=\(useFakeIP ? "198.18.0.0/16" : "default")")
        log.info("tunnel started fakeIP=\(useFakeIP, privacy: .public) (SwiftTCP)")
        TunnelLifecycleStore.markStarted()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let request = try? TunnelIPC.decodeRequest(from: messageData) else {
            completionHandler?(nil)
            return
        }
        switch request.method {
        case .fetchMetrics:
            let snapshot = engine?.traffic.snapshot() ?? TrafficSnapshot()
            completionHandler?(try? TunnelIPC.encode(.success(metrics: snapshot)))
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
            let proxy = request.systemProxy ?? self.systemProxy
            let lan = request.allowLAN ?? self.allowLAN
            self.useFakeIP = fakeIP
            self.systemProxy = proxy
            self.allowLAN = lan
            Task { [weak self] in
                guard let self else {
                    completionHandler?(try? TunnelIPC.encode(.failure("deallocated")))
                    return
                }
                do {
                    if let engine = self.engine {
                        try await self.applyMixedPort(
                            engine: engine,
                            enabled: proxy,
                            port: self.mixedPortNumber,
                            allowLAN: lan
                        )
                    }
                    let settings = Self.makeNetworkSettings(
                        useFakeIP: fakeIP,
                        systemProxy: proxy,
                        mixedPort: self.mixedPortNumber,
                        dnsServers: self.systemDNS,
                        ipv6: self.ipv6FakeIP
                    )
                    try await self.setTunnelNetworkSettings(settings)
                    TunnelLog.write(.info, "capture mode fakeIP=\(fakeIP) systemProxy=\(proxy)")
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

    private func shutdown() async {
        pumpTask?.cancel()
        relayTask?.cancel()
        pumpTask = nil
        relayTask = nil
        mixedPort?.stop()
        mixedPort = nil
        engine?.stopURLTest()
        engine = nil
        await stack?.stop()
        stack = nil
        TunnelLog.write(.info, "tunnel stopped")
        log.info("tunnel stopped")
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

    // MARK: - Virtual NIC

    private func applyMixedPort(
        engine: Engine,
        enabled: Bool,
        port: UInt16,
        allowLAN: Bool
    ) async throws {
        mixedPort?.stop()
        mixedPort = nil
        guard enabled else { return }
        let server = MixedPortServer(engine: engine, port: port, allowLAN: allowLAN)
        try server.start()
        mixedPort = server
    }

    public static func makeNetworkSettings(
        useFakeIP: Bool,
        systemProxy: Bool = false,
        mixedPort: UInt16 = MixedPortServer.defaultPort,
        dnsServers: [String]?,
        ipv6: Bool = false
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1400

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        if useFakeIP {
            // Clash-style: only FakeIP CIDR enters the TUN. Direct names get
            // real A records and leave via the kernel NIC.
            ipv4.includedRoutes = [
                NEIPv4Route(destinationAddress: "198.18.0.0", subnetMask: "255.255.0.0")
            ]
        } else {
            // System Proxy only: keep utun addressed but route nothing into it.
            ipv4.includedRoutes = [
                NEIPv4Route(destinationAddress: "198.18.0.1", subnetMask: "255.255.255.255")
            ]
        }
        settings.ipv4Settings = ipv4

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

        if systemProxy {
            let proxy = NEProxySettings()
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            let server = NEProxyServer(address: "127.0.0.1", port: Int(mixedPort))
            proxy.httpServer = server
            proxy.httpsServer = server
            proxy.excludeSimpleHostnames = true
            proxy.exceptionList = ["localhost", "127.0.0.1", "*.local"]
            settings.proxySettings = proxy
        }
        return settings
    }
}

enum PacketTunnelError: Error {
    case deallocated
}
