import Foundation
import os
import PrizmXProxyHelper
import SystemConfiguration

/// Root launchd daemon that writes System Configuration proxy settings for
/// the app (see `ProxyHelperXPC`). launchd starts it on the first connection;
/// it exits once idle so an updated app bundle runs its new binary next time.
private let log = Logger(subsystem: "app.prizmx", category: "ProxyHelper")

private final class HelperService: NSObject, NSXPCListenerDelegate, ProxyHelperXPCService, @unchecked Sendable {
    private static let idleExit: TimeInterval = 30

    /// Connections arrive on separate queues; System Configuration writes
    /// must not interleave.
    private let writeLock = NSLock()
    private let stateQueue = DispatchQueue(label: "app.prizmx.macos.helper.state")
    private var connections = 0
    private var idleGeneration = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(ProxyHelperXPC.appRequirement)
        connection.exportedInterface = NSXPCInterface(with: ProxyHelperXPCService.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        stateQueue.sync {
            connections += 1
            idleGeneration += 1
        }
        connection.resume()
        return true
    }

    func writeProxies(_ configs: [String: Data], reply: @escaping @Sendable (String?) -> Void) {
        guard let decoded = ProxyServiceWriter.decode(configs) else {
            reply("invalid proxy settings")
            return
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let prefs = SCPreferencesCreate(nil, "PrizmXHelper" as CFString, nil) else {
            reply("SCPreferencesCreate failed")
            return
        }
        let error = ProxyServiceWriter.write(decoded, to: prefs)
        if let error {
            log.error("write failed \(error, privacy: .public)")
        } else {
            log.info("wrote proxies for \(decoded.count) services")
        }
        reply(error)
    }

    func scheduleIdleExit() {
        stateQueue.async { [self] in
            guard connections == 0 else { return }
            let generation = idleGeneration
            stateQueue.asyncAfter(deadline: .now() + Self.idleExit) { [self] in
                guard connections == 0, idleGeneration == generation else { return }
                exit(0)
            }
        }
    }

    private func connectionEnded() {
        stateQueue.async { [self] in
            connections -= 1
            scheduleIdleExit()
        }
    }
}

private let service = HelperService()
private let listener = NSXPCListener(machServiceName: ProxyHelperXPC.machServiceName)
listener.delegate = service
listener.resume()
service.scheduleIdleExit()
dispatchMain()
