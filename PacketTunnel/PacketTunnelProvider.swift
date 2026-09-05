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
    private var pumpTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
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
        let pinPreview = boot.pinnedNodeAddresses.map { "\($0.key)→\($0.value.map(\.description))" }.sorted().joined(separator: ",")
        TunnelLog.write(
            .info,
            "tunnel starting configBytes=\(boot.configText?.utf8.count ?? 0) fakeIP=\(useFakeIP) appDNS=\(systemDNS) pinned=\(pinPreview) selections=\(PolicySelectionStore.load())"
        )

        let engine = try boot.makeEngine()
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
            dnsPolicy: { host in engine.dnsPolicy(host: host) },
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

        // 3. Virtual NIC: FakeIP 198.18.0.0/16 only (Direct uses kernel).
        let settings = Self.makeNetworkSettings(useFakeIP: useFakeIP, dnsServers: systemDNS)
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
                TunnelLog.write(.info, "select \(group) → \(nodeID)")
                completionHandler?(try? TunnelIPC.encode(.success()))
            } catch {
                TunnelLog.write(.error, "select \(group) → \(nodeID) failed: \(error.localizedDescription)")
                completionHandler?(try? TunnelIPC.encode(.failure(error.localizedDescription)))
            }
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

    public static func makeNetworkSettings(
        useFakeIP: Bool,
        dnsServers: [String]?
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
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv4.excludedRoutes = [
                NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
                NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
                NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
                NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
                NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
                NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
                NEIPv4Route(destinationAddress: "255.255.255.255", subnetMask: "255.255.255.255"),
            ]
        }
        settings.ipv4Settings = ipv4

        let resolvers = useFakeIP
            ? ["198.18.0.2"]
            : (dnsServers?.isEmpty == false ? dnsServers! : ["114.114.114.114"])
        let dns = NEDNSSettings(servers: resolvers)
        // Empty string match domain = hijack every DNS query into the tunnel.
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }
}

enum PacketTunnelError: Error {
    case deallocated
}
