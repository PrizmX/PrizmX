import Foundation
import PrizmXServices
import PrizmXUIEngine

extension AppModel {
    struct AppRosterRow: Identifiable, Hashable {
        var id: String
        var name: String
        var bundleID: String?
        var executablePath: String?
        var sessions: Int
        var downloadBytes: UInt64
        var uploadBytes: UInt64
        var bytesPerSecond: Double
    }

    struct LANClientRow: Identifiable, Hashable {
        var id: String
        var name: String
        var address: String
        var kindTitle: String
        var systemImage: String
        var sessions: Int
        var downloadBytes: UInt64
        var uploadBytes: UInt64
    }

    /// Local processes that produced attributed traffic this session.
    var appRosterRows: [AppRosterRow] {
        let metrics = dashboard.vpn.lastMetrics
        var names = metrics.appNames
        var bundleIDs: [String: String] = [:]
        var paths: [String: String] = [:]
        var sessions: [String: Int] = [:]
        var flowUp: [String: UInt64] = [:]
        var flowDown: [String: UInt64] = [:]

        func accumulate(_ flow: FlowRecord) {
            guard let attribution = flow.attribution else { return }
            let key = attribution.accountingKey
            if names[key] == nil { names[key] = attribution.processName }
            if bundleIDs[key] == nil, let bundleID = attribution.bundleID, !bundleID.isEmpty {
                bundleIDs[key] = bundleID
            }
            if paths[key] == nil { paths[key] = attribution.executablePath }
            flowUp[key, default: 0] &+= flow.uplinkBytes
            flowDown[key, default: 0] &+= flow.downlinkBytes
        }

        for flow in inspectorFlows {
            accumulate(flow)
            if !flow.closed, let key = flow.attribution?.accountingKey {
                sessions[key, default: 0] += 1
            }
        }

        var keys = Set(metrics.appBytes.keys)
        keys.formUnion(sessions.keys)
        keys.formUnion(flowUp.keys)

        return keys.map { key in
            let bytes = metrics.appBytes[key]
            let bundleID = bundleIDs[key] ?? (key.contains(".") ? key : nil)
            return AppRosterRow(
                id: key,
                name: names[key] ?? key,
                bundleID: bundleID,
                executablePath: paths[key],
                sessions: sessions[key] ?? 0,
                downloadBytes: bytes?.down ?? flowDown[key] ?? 0,
                uploadBytes: bytes?.up ?? flowUp[key] ?? 0,
                bytesPerSecond: appByteRates[key] ?? 0
            )
        }
    }

    /// Remote mixed-port clients (non-loopback, non-FakeIP, no local process).
    var lanClientRows: [LANClientRow] {
        var sessions: [String: Int] = [:]
        var up: [String: UInt64] = [:]
        var down: [String: UInt64] = [:]

        for flow in inspectorFlows {
            guard flow.attribution == nil else { continue }
            guard let host = Self.lanClientAddress(flow.sourceHost) else { continue }
            up[host, default: 0] &+= flow.uplinkBytes
            down[host, default: 0] &+= flow.downlinkBytes
            if !flow.closed {
                sessions[host, default: 0] += 1
            }
        }

        return Set(up.keys).union(down.keys).union(sessions.keys)
            .map { host in
                let device = lanDeviceByAddress[host] ?? LANDevice(
                    address: host,
                    name: host,
                    kind: .unknown
                )
                return LANClientRow(
                    id: host,
                    name: device.name,
                    address: host,
                    kindTitle: device.kind.title,
                    systemImage: device.kind.systemImage,
                    sessions: sessions[host] ?? 0,
                    downloadBytes: down[host] ?? 0,
                    uploadBytes: up[host] ?? 0
                )
            }
    }

    var lanBindHost: String {
        let ip = networkLink.lanIPv4
        return ip == "—" ? "0.0.0.0" : ip
    }

    var lanHTTPEndpoint: String {
        "\(lanBindHost):\(inboundListen.systemProxyHTTPPort)"
    }

    var lanSOCKSEndpoint: String {
        "\(lanBindHost):\(inboundListen.systemProxySOCKSPort)"
    }

    var lanCopyEndpoint: String? {
        guard allowLANEnabled else { return nil }
        if inboundListen.systemProxyHTTPPort == inboundListen.systemProxySOCKSPort {
            return lanHTTPEndpoint
        }
        return "HTTP \(lanHTTPEndpoint)\nSOCKS \(lanSOCKSEndpoint)"
    }

    var lanAddressLabel: String {
        if !allowLANEnabled { return "Off" }
        if inboundListen.systemProxyHTTPPort == inboundListen.systemProxySOCKSPort {
            return lanHTTPEndpoint
        }
        return "HTTP \(lanHTTPEndpoint)   SOCKS \(lanSOCKSEndpoint)"
    }

    /// Home LAN card value: host only; the card already shows Port.
    var lanCardAddress: String {
        if !allowLANEnabled { return "Off" }
        return lanBindHost
    }

    /// Non-loopback, non-FakeIP inbound address for the LAN roster.
    static func lanClientAddress(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        if let percent = host.firstIndex(of: "%") {
            host = String(host[..<percent])
        }
        if host.lowercased().hasPrefix("::ffff:") {
            host = String(host.dropFirst(7))
        }
        let lower = host.lowercased()
        if lower == "::1" || lower == "localhost" { return nil }
        if host == "127.0.0.1" || host.hasPrefix("127.") { return nil }
        if host.hasPrefix("198.18.") || host.hasPrefix("198.19.") { return nil }
        return host
    }

    func ingestAppByteRates(_ metrics: VPNMetrics, now: Date = .now) {
        if let last = lastAppByteSample {
            let dt = now.timeIntervalSince(last.at)
            if dt >= 0.5 {
                var next: [String: Double] = [:]
                for (key, count) in metrics.appBytes {
                    let previous = last.bytes[key] ?? TrafficByteCount()
                    let delta = (count.up &- previous.up) &+ (count.down &- previous.down)
                    next[key] = Double(delta) / dt
                }
                if next != appByteRates {
                    appByteRates = next
                }
            }
        }
        lastAppByteSample = (now, metrics.appBytes)
    }

    func noteLANDevices(in flows: [FlowRecord]) {
        for flow in flows {
            guard let host = Self.lanClientAddress(flow.sourceHost) else { continue }
            if lanDeviceByAddress[host] == nil {
                lanDeviceByAddress[host] = LANDevice(address: host, name: host, kind: .unknown)
            }
            guard lanResolveAttempted.insert(host).inserted else { continue }
            Task { await resolveLANDevice(host) }
        }
    }

    private func resolveLANDevice(_ address: String) async {
        guard let host = await PhysicalPTRLookup.hostname(for: address) else { return }
        let name = LANDevice.displayName(fromHost: host, fallback: address)
        lanDeviceByAddress[address] = LANDevice(
            address: address,
            name: name,
            kind: .infer(from: name)
        )
    }
}
