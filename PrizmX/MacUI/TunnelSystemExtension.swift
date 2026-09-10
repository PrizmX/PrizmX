import Foundation
import SystemExtensions
import PrizmXProtocols

/// Activates the Developer ID Packet Tunnel system extension before NEVPN start.
enum TunnelSystemExtension {
    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "app.prizmx.macos") + ".packet-tunnel"
    }

    @MainActor
    static func activate() async throws {
        try await Activator.shared.activate()
    }
}

@MainActor
private final class Activator: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = Activator()
    private var continuation: CheckedContinuation<Void, Error>?

    func activate() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: TunnelSystemExtension.identifier,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        TunnelLog.write(.info, "system extension waiting for user approval")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        TunnelLog.write(.info, "system extension ready result=\(result.rawValue)")
        continuation?.resume()
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        TunnelLog.write(.error, "system extension failed: \(error.localizedDescription)")
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
