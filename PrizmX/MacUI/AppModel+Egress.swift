import Foundation

// MARK: - External IP (egress) lookup

private let egressIPEndpoint = URL(string: "https://api.ipify.org")!
private let egressDetailEndpoint = URL(string: "https://ipwho.is/")!
private let egressUserAgent = "PrizmX/1.0 (macOS)"

/// Fresh session per lookup: `URLSession.shared` keep-alive would reuse the
/// connection dialed through the *previous* node, so the egress IP never
/// reflects a node switch.
private func makeEgressSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.httpAdditionalHeaders = ["Connection": "close"]
    return URLSession(configuration: config)
}

/// On-demand lookup for the External IP popover (ipwho.is).
struct EgressIPInfo: Equatable, Sendable {
    var address: String
    var city: String?
    var region: String?
    var country: String?
    var countryCode: String?
    var org: String?
    var fetchedAt: Date

    /// Regional-indicator pair for `countryCode` (`US` → 🇺🇸). Nil if unknown.
    var flagEmoji: String? { CountryFlag.emoji(for: countryCode) }
}

enum CountryFlag {
    static func emoji(for code: String?) -> String? {
        guard let code else { return nil }
        let letters = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard letters.count == 2,
              letters.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.uppercaseLetters.contains($0) })
        else { return nil }
        let regionalA: UInt32 = 0x1F1E6
        var flag = ""
        for scalar in letters.unicodeScalars {
            guard let tile = Unicode.Scalar(regionalA + (scalar.value - 65)) else { return nil }
            flag.unicodeScalars.append(tile)
        }
        return flag
    }
}

private struct IPWhoResponse: Decodable {
    var ipAddress: String?
    var success: Bool?
    var message: String?
    var city: String?
    var region: String?
    var country: String?
    var countryCode: String?
    var connection: Connection?

    struct Connection: Decodable {
        var org: String?
        var isp: String?
    }

    enum CodingKeys: String, CodingKey {
        case success, message, city, region, country, connection
        case ipAddress = "ip"
        case countryCode = "country_code"
    }
}

extension AppModel {
    /// Fast IP-only probe for the Home fact. Details (city / ISP) are fetched
    /// separately — both are third-party HTTPS lookups.
    func refreshEgressIP() async {
        var request = URLRequest(url: egressIPEndpoint)
        request.timeoutInterval = 8
        request.setValue(egressUserAgent, forHTTPHeaderField: "User-Agent")
        let session = makeEgressSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                egressIP = "—"
                return
            }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            egressIP = text.isEmpty ? "—" : text
        } catch {
            egressIP = "—"
        }
    }

    /// Geo / ASN lookup for the External IP popover. ipapi.co 403s client apps;
    /// ipwho.is is HTTPS and does not require a key.
    func refreshEgressDetails() async {
        egressLookupError = nil
        var request = URLRequest(url: egressDetailEndpoint)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(egressUserAgent, forHTTPHeaderField: "User-Agent")
        let session = makeEgressSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                egressLookupError = "Lookup failed (HTTP \(http.statusCode))."
                return
            }
            let decoded = try JSONDecoder().decode(IPWhoResponse.self, from: data)
            if decoded.success == false {
                egressLookupError = decoded.message ?? "Lookup failed."
                return
            }
            let address = decoded.ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !address.isEmpty { egressIP = address }
            let org = decoded.connection?.org ?? decoded.connection?.isp
            egressInfo = EgressIPInfo(
                address: address.isEmpty ? egressIP : address,
                city: decoded.city,
                region: decoded.region,
                country: decoded.country,
                countryCode: decoded.countryCode,
                org: org,
                fetchedAt: Date()
            )
        } catch {
            egressLookupError = error.localizedDescription
        }
    }

    /// IP number plus geo (flag). Details first; ipify if that fails.
    func refreshEgress() async {
        await refreshEgressDetails()
        if egressIP == "—" || egressIP.isEmpty {
            let previous = egressIP
            await refreshEgressIP()
            if egressIP != previous { egressInfo = nil }
        }
    }

    /// Wait for the new path / node to take, then lookup. Coalesces bursts.
    func scheduleEgressRefresh(after delay: Duration = .seconds(1.5)) {
        egressRefreshTask?.cancel()
        egressRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await refreshEgress()
        }
    }
}
