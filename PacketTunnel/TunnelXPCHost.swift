import Foundation
import PrizmXConfig
import PrizmXProtocols

/// Serves the app over the Mach service named by `NEMachServiceName`. A
/// connection is refused unless the peer is the app signed by this team.
final class TunnelXPCHost: NSObject, NSXPCListenerDelegate, TunnelXPCService, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: TunnelXPC.machServiceName)
    private let metrics: @Sendable () -> Data?

    init(metrics: @escaping @Sendable () -> Data?) {
        self.metrics = metrics
        super.init()
    }

    func start() {
        listener.delegate = self
        listener.resume()
        TunnelLog.write(.info, "xpc: listening on \(TunnelXPC.machServiceName)")
    }

    func stop() {
        listener.invalidate()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.setCodeSigningRequirement(TunnelXPC.appRequirement)
        connection.exportedInterface = NSXPCInterface(with: TunnelXPCService.self)
        connection.exportedObject = self
        connection.invalidationHandler = {
            TunnelLog.write(.debug, "xpc: app connection ended")
        }
        connection.resume()
        TunnelLog.write(.info, "xpc: app connected")
        return true
    }

    func fetchMetrics(reply: @escaping (Data?) -> Void) {
        reply(metrics())
    }
}
