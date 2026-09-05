import PrizmXNodes
import PrizmXProtocols
import PrizmXRules

extension RouteRule {
    var displayType: String {
        switch matcher {
        case .domain: "DOMAIN"
        case .domainSuffix: "DOMAIN-SUFFIX"
        case .domainKeyword: "DOMAIN-KEYWORD"
        case .ipv4, .ipv4CIDR: "IP-CIDR"
        case .ipv6, .ipv6CIDR: "IP-CIDR6"
        case .geoIP: "GEOIP"
        case .geosite: "GEOSITE"
        case .matchAll: "MATCH"
        }
    }

    var displayPayload: String {
        switch matcher {
        case .domain(let value), .domainSuffix(let value), .domainKeyword(let value):
            return value
        case .ipv4(let address):
            return address.description
        case .ipv4CIDR(let address, let prefix):
            return "\(address)/\(prefix)"
        case .ipv6(let address):
            return address.description
        case .ipv6CIDR(let address, let prefix):
            return "\(address)/\(prefix)"
        case .geoIP(let code):
            return code
        case .geosite(let tag):
            return tag
        case .matchAll:
            return "*"
        }
    }

    var displayPolicy: String {
        switch policy {
        case .direct: "DIRECT"
        case .reject: "REJECT"
        case .proxy(let group): group
        }
    }
}

extension PolicyGroup.Mode {
    var displayName: String {
        switch self {
        case .select: "select"
        case .urlTest: "url-test"
        }
    }
}
