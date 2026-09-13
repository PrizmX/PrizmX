import Foundation

struct LANDevice: Hashable, Sendable {
    var address: String
    var name: String
    var kind: Kind

    enum Kind: String, Hashable, Sendable {
        case phone
        case tablet
        case computer
        case tv
        case unknown

        var title: String {
            switch self {
            case .phone: "Phone"
            case .tablet: "Tablet"
            case .computer: "Computer"
            case .tv: "TV"
            case .unknown: "Device"
            }
        }

        var systemImage: String {
            switch self {
            case .phone: "iphone"
            case .tablet: "ipad"
            case .computer: "laptopcomputer"
            case .tv: "tv"
            case .unknown: "desktopcomputer"
            }
        }

        static func infer(from name: String) -> Kind {
            let lowered = name.lowercased()
            if lowered.contains("iphone") || lowered.contains("android") || lowered.contains("pixel")
                || lowered.contains("galaxy") || lowered.contains("huawei") || lowered.contains("xiaomi")
                || lowered.contains("oneplus") || lowered.contains("oppo") || lowered.contains("vivo") {
                return .phone
            }
            if lowered.contains("ipad") {
                return .tablet
            }
            if lowered.contains("appletv") || lowered.contains("apple-tv") || lowered.contains("apple tv")
                || lowered.contains("bravia") || lowered.contains("chromecast") || lowered.contains("firetv") {
                return .tv
            }
            if lowered.contains("mac") || lowered.contains("imac") || lowered.contains("macbook")
                || lowered.contains("windows") || lowered.contains("desktop") || lowered.contains("laptop")
                || lowered.contains("pc-") || lowered.hasSuffix("-pc") {
                return .computer
            }
            return .unknown
        }
    }

    static func displayName(fromHost host: String, fallback address: String) -> String {
        var name = host
        if let percent = name.firstIndex(of: "%") {
            name = String(name[..<percent])
        }
        if name.hasSuffix(".") {
            name = String(name.dropLast())
        }
        for suffix in [".local", ".lan", ".home"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        if name.isEmpty || name == address { return address }
        return name
    }
}
