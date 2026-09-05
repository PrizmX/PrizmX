@preconcurrency import Foundation
@preconcurrency import NetworkExtension
import os
import PrizmXConfig
import PrizmXCore
import PrizmXProtocols

/// macOS Transparent Proxy entry point. The system delivers L4 flows
/// (`NEAppProxyTCPFlow` / `NEAppProxyUDPFlow`); there is no userspace TCP stack.
final class AppProxyProvider: NETransparentProxyProvider {
    private var engine: Engine?
    private let log = Logger(subsystem: "app.prizmx", category: "AppProxy")

    override func startProxy(
        options: [String: Any]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { [weak self] in
            guard let self else {
                completionHandler(AppProxyError.deallocated)
                return
            }
            do {
                try await self.bootstrap(options: options)
                completionHandler(nil)
            } catch {
                TunnelLog.write(.error, "startProxy failed: \(error.localizedDescription)")
                self.log.error("startProxy failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        engine?.stopURLTest()
        engine = nil
        TunnelLog.write(.info, "proxy stopped reason=\(reason.rawValue)")
        log.info("proxy stopped reason=\(reason.rawValue, privacy: .public)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let engine else { return false }
        if let tcp = flow as? NEAppProxyTCPFlow {
            guard let endpoint = FlowEndpoint.make(from: tcp) else { return false }
            Task { await self.handleTCP(tcp, endpoint: endpoint, engine: engine) }
            return true
        }
        if let udp = flow as? NEAppProxyUDPFlow {
            Task { await AppProxyUDPRelay.run(flow: udp, engine: engine) }
            return true
        }
        return false
    }

    private func bootstrap(options: [String: Any]?) async throws {
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let boot = ExtensionBootstrap(
            providerConfiguration: proto?.providerConfiguration,
            options: options
        )
        TunnelLog.write(
            .info,
            "proxy starting configBytes=\(boot.configText?.utf8.count ?? 0) appDNS=\(boot.systemDNS) pinned=\(boot.pinnedNodeAddresses.count)"
        )

        let engine = try boot.makeEngine()
        TunnelLog.write(
            .info,
            "engine ready rules=\(engine.router.rules.count) nodes=\(engine.nodeManager.nodesByID.count) groups=\(engine.nodeManager.groupsByName.count)"
        )
        engine.startURLTest()
        self.engine = engine

        try await setTunnelNetworkSettings(Self.makeNetworkSettings())
        TunnelLog.write(.info, "proxy started (transparent)")
        log.info("proxy started (transparent)")
    }

    private func handleTCP(
        _ flow: NEAppProxyTCPFlow,
        endpoint: Endpoint,
        engine: Engine
    ) async {
        do {
            try await Self.open(flow)
            let stream = AppProxyTCPStream(flow: flow, endpoint: endpoint)
            await EngineTCPRelay.pipe(stream: stream, engine: engine)
        } catch {
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
        }
    }

    private static func open(_ flow: NEAppProxyFlow) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.open(withLocalEndpoint: nil) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Outbound TCP/UDP to the public internet; RFC1918 / loopback / link-local
    /// stay on the physical interface so LAN and the proxy's own sockets are not
    /// captured. The Network Extension process is also exempt from its own rules.
    public static func makeNetworkSettings() -> NETransparentProxyNetworkSettings {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            Self.outboundRule(hostname: "0.0.0.0", prefix: 0, match: .TCP),
            Self.outboundRule(hostname: "0.0.0.0", prefix: 0, match: .UDP),
            Self.outboundRule(hostname: "::", prefix: 0, match: .TCP),
            Self.outboundRule(hostname: "::", prefix: 0, match: .UDP),
        ]
        settings.excludedNetworkRules = [
            Self.exclude(hostname: "10.0.0.0", prefix: 8),
            Self.exclude(hostname: "172.16.0.0", prefix: 12),
            Self.exclude(hostname: "192.168.0.0", prefix: 16),
            Self.exclude(hostname: "127.0.0.0", prefix: 8),
            Self.exclude(hostname: "169.254.0.0", prefix: 16),
            Self.exclude(hostname: "224.0.0.0", prefix: 4),
            Self.exclude(hostname: "255.255.255.255", prefix: 32),
            Self.exclude(hostname: "::1", prefix: 128),
            Self.exclude(hostname: "fc00::", prefix: 7),
            Self.exclude(hostname: "fe80::", prefix: 10),
            Self.exclude(hostname: "ff00::", prefix: 8),
        ]
        return settings
    }

    private static func outboundRule(
        hostname: String,
        prefix: Int,
        match: NENetworkRule.`Protocol`
    ) -> NENetworkRule {
        NENetworkRule(
            remoteNetwork: NWHostEndpoint(hostname: hostname, port: "0"),
            remotePrefix: prefix,
            localNetwork: nil,
            localPrefix: 0,
            protocol: match,
            direction: .outbound
        )
    }

    private static func exclude(hostname: String, prefix: Int) -> NENetworkRule {
        NENetworkRule(
            destinationNetwork: NWHostEndpoint(hostname: hostname, port: "0"),
            prefix: prefix,
            protocol: .any
        )
    }
}

enum AppProxyError: Error {
    case deallocated
}

enum FlowEndpoint {
    static func make(from flow: NEAppProxyTCPFlow) -> Endpoint? {
        make(remote: flow.remoteEndpoint, hostname: flow.remoteHostname)
    }

    static func make(remote: NWEndpoint, hostname: String?) -> Endpoint? {
        guard let host = remote as? NWHostEndpoint,
              let port = UInt16(host.port)
        else { return nil }
        let name = hostname.flatMap { $0.isEmpty ? nil : $0 } ?? host.hostname
        return Endpoint(hostname: name, port: port)
    }
}

/// Adapts `NEAppProxyTCPFlow` to `InboundStream` for `EngineTCPRelay`.
final class AppProxyTCPStream: InboundStream, @unchecked Sendable {
    let endpoint: Endpoint
    private let flow: NEAppProxyTCPFlow

    init(flow: NEAppProxyTCPFlow, endpoint: Endpoint) {
        self.flow = flow
        self.endpoint = endpoint
    }

    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            flow.readData { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.write(data) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func close() async {
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}
