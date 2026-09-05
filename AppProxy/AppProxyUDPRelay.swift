@preconcurrency import Foundation
@preconcurrency import NetworkExtension
import PrizmXCore
import PrizmXNodes
import PrizmXProtocols

/// Relays one `NEAppProxyUDPFlow` through DIRECT / SS-UDP / VLESS-UDP.
enum AppProxyUDPRelay {
    static func run(flow: NEAppProxyUDPFlow, engine: Engine) async {
        do {
            try await open(flow)
        } catch {
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
            return
        }
        let state = UDPFlowState(flow: flow, engine: engine)
        await state.pump()
        await state.stop()
    }

    private static func open(_ flow: NEAppProxyUDPFlow) async throws {
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
}

private actor UDPFlowState {
    private let flow: NEAppProxyUDPFlow
    private let engine: Engine
    private var sessions: [String: any FlowUDPSession] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(flow: NEAppProxyUDPFlow, engine: Engine) {
        self.flow = flow
        self.engine = engine
    }

    func pump() async {
        while !Task.isCancelled {
            let datagrams: ([Data], [NWEndpoint])
            do {
                datagrams = try await readDatagrams()
            } catch {
                break
            }
            if datagrams.0.isEmpty { break }
            for (payload, remote) in zip(datagrams.0, datagrams.1) {
                await ingest(payload: payload, remote: remote)
            }
        }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }

    func stop() async {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for session in sessions.values {
            await session.close()
        }
        sessions.removeAll()
    }

    private func ingest(payload: Data, remote: NWEndpoint) async {
        guard let destination = FlowEndpoint.make(remote: remote, hostname: nil) else { return }
        let key = destination.description
        if sessions[key] == nil {
            switch engine.router.match(endpoint: destination) {
            case .reject:
                return
            case .direct:
                await openDirect(key: key, destination: destination, remote: remote)
            case .proxy(let group):
                await openProxy(
                    key: key,
                    destination: destination,
                    remote: remote,
                    group: group
                )
            }
        }
        guard let session = sessions[key] else { return }
        await session.send(payload, destination: destination)
    }

    private func openDirect(key: String, destination: Endpoint, remote: NWEndpoint) async {
        guard let connection = AppProxyUDPWire.connect(
            host: destination.host.description,
            port: destination.port
        ) else { return }
        let session = DirectFlowUDPSession(connection: connection, flow: flow, remote: remote)
        sessions[key] = session
        tasks[key] = Task { await session.pump() }
    }

    private func openProxy(
        key: String,
        destination: Endpoint,
        remote: NWEndpoint,
        group: String
    ) async {
        switch engine.nodeManager.selectedLeaf(inGroup: group) {
        case .direct:
            await openDirect(key: key, destination: destination, remote: remote)
            return
        case .reject, nil:
            return
        case .node(let node):
            switch node.protocolConfig {
        case .direct:
            await openDirect(key: key, destination: destination, remote: remote)
        case .vless:
            do {
                let outbound = try engine.dispatch(target: destination, command: .udp)
                try await outbound.open()
                let session = StreamFlowUDPSession(outbound: outbound, flow: flow, remote: remote)
                sessions[key] = session
                tasks[key] = Task { await session.pump() }
            } catch {
                return
            }
        case .trojan, .anytls:
            return
        case .shadowsocks(let server, let password, let cipher):
            guard let connection = AppProxyUDPWire.connect(
                host: server.host.description,
                port: server.port
            ) else { return }
            let session = ShadowsocksFlowUDPSession(
                connection: connection,
                preSharedKey: cipher.masterKey(fromPassword: password),
                cipher: cipher,
                flow: flow,
                remote: remote
            )
            sessions[key] = session
            tasks[key] = Task { await session.pump() }
            }
        }
    }

    private func readDatagrams() async throws -> ([Data], [NWEndpoint]) {
        try await withCheckedThrowingContinuation { continuation in
            flow.readDatagrams { datagrams, endpoints, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (datagrams ?? [], endpoints ?? []))
            }
        }
    }
}

private protocol FlowUDPSession: AnyObject, Sendable {
    func send(_ payload: Data, destination: Endpoint) async
    func close() async
}

private final class DirectFlowUDPSession: FlowUDPSession, @unchecked Sendable {
    private let connection: NWConnection
    private let flow: NEAppProxyUDPFlow
    private let remote: NWEndpoint

    init(connection: NWConnection, flow: NEAppProxyUDPFlow, remote: NWEndpoint) {
        self.connection = connection
        self.flow = flow
        self.remote = remote
    }

    func send(_ payload: Data, destination _: Endpoint) async {
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    func pump() async {
        while !Task.isCancelled {
            guard let data = await connection.receiveDatagram(), !data.isEmpty else { return }
            await writeBack(data)
        }
    }

    func close() async {
        connection.cancel()
    }

    private func writeBack(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            flow.writeDatagrams([data], sentBy: [remote]) { _ in
                continuation.resume()
            }
        }
    }
}

private final class StreamFlowUDPSession: FlowUDPSession, @unchecked Sendable {
    private let outbound: any OutboundConnection
    private let flow: NEAppProxyUDPFlow
    private let remote: NWEndpoint

    init(outbound: any OutboundConnection, flow: NEAppProxyUDPFlow, remote: NWEndpoint) {
        self.outbound = outbound
        self.flow = flow
        self.remote = remote
    }

    func send(_ payload: Data, destination _: Endpoint) async {
        try? await outbound.writeAll(UDPOverStreamFrame.encode(payload))
    }

    func pump() async {
        var decoder = UDPOverStreamFrame.Decoder()
        do {
            while !Task.isCancelled {
                let chunk = try await outbound.readData(upTo: 16 * 1024)
                if chunk.isEmpty { break }
                for payload in decoder.feed(chunk) {
                    await writeBack(payload)
                }
            }
        } catch {
            // Closed.
        }
        await outbound.close()
    }

    func close() async {
        await outbound.close()
    }

    private func writeBack(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            flow.writeDatagrams([data], sentBy: [remote]) { _ in
                continuation.resume()
            }
        }
    }
}

private final class ShadowsocksFlowUDPSession: FlowUDPSession, @unchecked Sendable {
    private let connection: NWConnection
    private let preSharedKey: [UInt8]
    private let cipher: ShadowsocksCipher
    private let flow: NEAppProxyUDPFlow
    private let remote: NWEndpoint

    init(
        connection: NWConnection,
        preSharedKey: [UInt8],
        cipher: ShadowsocksCipher,
        flow: NEAppProxyUDPFlow,
        remote: NWEndpoint
    ) {
        self.connection = connection
        self.preSharedKey = preSharedKey
        self.cipher = cipher
        self.flow = flow
        self.remote = remote
    }

    func send(_ payload: Data, destination: Endpoint) async {
        guard let packet = try? ShadowsocksUDP.encode(
            cipher: cipher,
            preSharedKey: preSharedKey,
            destination: destination,
            payload: payload
        ) else { return }
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    func pump() async {
        while !Task.isCancelled {
            guard let data = await connection.receiveDatagram(), !data.isEmpty else { return }
            guard let decoded = try? ShadowsocksUDP.decode(
                cipher: cipher,
                preSharedKey: preSharedKey,
                packet: data
            ) else { continue }
            await writeBack(decoded.payload)
        }
    }

    func close() async {
        connection.cancel()
    }

    private func writeBack(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            flow.writeDatagrams([data], sentBy: [remote]) { _ in
                continuation.resume()
            }
        }
    }
}
