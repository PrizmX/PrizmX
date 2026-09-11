import CoreLocation
import Foundation
import Network
import Observation
import SystemConfiguration
#if canImport(CoreWLAN)
import CoreWLAN
#endif

enum NetworkLinkKind: Equatable {
    case offline
    case wifi
    case ethernet
    case hotspot
    case other

    var systemImage: String {
        switch self {
        case .offline: "wifi.slash"
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .hotspot: "personalhotspot"
        case .other: "network"
        }
    }
}

/// Live label for the Home "Network" fact: Wi-Fi SSID, else the primary NIC.
///
/// macOS only returns `CWInterface.ssid()` after Location When In Use is
/// granted; CoreWLAN also has to be read on the main thread.
@MainActor
@Observable
final class NetworkLinkMonitor: NSObject, CLLocationManagerDelegate {
    private(set) var title = "—"
    private(set) var kind: NetworkLinkKind = .other
    var onChange: (@MainActor () -> Void)?
    private let monitor = NWPathMonitor()
    private let location = CLLocationManager()
    private var latestPath: NWPath?
    private var hasPublished = false

    override init() {
        super.init()
        location.delegate = self
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.apply(path)
            }
        }
        monitor.start(queue: .main)
        apply(monitor.currentPath)
    }

    deinit {
        monitor.cancel()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshTitle()
    }

    private func apply(_ path: NWPath) {
        latestPath = path
        if path.status == .satisfied, Self.usesWiFi(path) {
            requestSSIDAccessIfNeeded()
        }
        refreshTitle()
    }

    private func refreshTitle() {
        let snapshot = Self.snapshot(for: latestPath ?? monitor.currentPath)
        let changed = snapshot.title != title || snapshot.kind != kind
        title = snapshot.title
        kind = snapshot.kind
        if changed, hasPublished {
            onChange?()
        }
        hasPublished = true
    }

    private func requestSSIDAccessIfNeeded() {
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    nonisolated private static func usesWiFi(_ path: NWPath) -> Bool {
        path.usesInterfaceType(.wifi)
            || path.availableInterfaces.contains { $0.type == .wifi }
    }

    nonisolated private static func snapshot(for path: NWPath) -> (title: String, kind: NetworkLinkKind) {
        guard path.status == .satisfied else { return ("Offline", .offline) }
        let bsd = primaryBSDName() ?? path.availableInterfaces.first?.name
        let nicName = bsd.flatMap(localizedName(forBSD:))
        let kind = kind(for: path, localizedName: nicName)
        if kind == .hotspot {
            if usesWiFi(path), let ssid = wifiSSID(interface: bsd), !ssid.isEmpty {
                return (ssid, .hotspot)
            }
            return (nicName ?? bsd ?? "Hotspot", .hotspot)
        }
        if usesWiFi(path) {
            if let ssid = wifiSSID(interface: bsd), !ssid.isEmpty { return (ssid, .wifi) }
            return (bsd.map { "Wi-Fi (\($0))" } ?? "Wi-Fi", .wifi)
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return (nicName ?? bsd ?? "Ethernet", .ethernet)
        }
        if path.usesInterfaceType(.other), let bsd {
            return (nicName ?? bsd, .other)
        }
        return (bsd ?? "On", .other)
    }

    nonisolated private static func kind(for path: NWPath, localizedName: String?) -> NetworkLinkKind {
        if isHotspot(path: path, localizedName: localizedName) { return .hotspot }
        if usesWiFi(path) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .other
    }

    /// Cellular, iPhone USB, or a Wi-Fi personal hotspot.
    nonisolated private static func isHotspot(path: NWPath, localizedName: String?) -> Bool {
        if path.isExpensive { return true }
        let name = (localizedName ?? "").lowercased()
        if name.contains("iphone") || name.contains("ipad") { return true }
        if name.contains("personal hotspot") { return true }
        if name.contains("bluetooth pan") || name.contains("蓝牙") { return true }
        return false
    }

    /// `State:/Network/Global/IPv4` PrimaryInterface (en0, en1, …).
    nonisolated private static func primaryBSDName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "PrizmX.NetworkLink" as CFString, nil, nil) else {
            return nil
        }
        guard let info = SCDynamicStoreCopyValue(
            store,
            "State:/Network/Global/IPv4" as CFString
        ) as? [String: Any] else {
            return nil
        }
        return info["PrimaryInterface"] as? String
    }

    nonisolated private static func localizedName(forBSD bsd: String) -> String? {
        guard let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for interface in list {
            guard SCNetworkInterfaceGetBSDName(interface) as String? == bsd else { continue }
            return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
        }
        return nil
    }

    nonisolated private static func wifiSSID(interface bsd: String?) -> String? {
        #if canImport(CoreWLAN)
        let client = CWWiFiClient.shared()
        let wifi: CWInterface?
        if let bsd {
            wifi = client.interface(withName: bsd) ?? client.interface()
        } else {
            wifi = client.interface()
        }
        if let ssid = wifi?.ssid(), !ssid.isEmpty { return ssid }
        if let data = wifi?.ssidData(), let ssid = String(data: data, encoding: .utf8), !ssid.isEmpty {
            return ssid
        }
        return nil
        #else
        return nil
        #endif
    }
}
