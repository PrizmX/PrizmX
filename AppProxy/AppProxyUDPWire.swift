import Foundation
import Network

/// Creates outbound UDP sockets. Isolated so `Network.NWEndpoint` does not
/// collide with `NetworkExtension.NWEndpoint` in the flow files.
enum AppProxyUDPWire {
    static func connect(host: String, port: UInt16) -> NWConnection? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.udp
        parameters.preferNoProxies = true
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        return connection
    }
}
