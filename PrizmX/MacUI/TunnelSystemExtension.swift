import AppKit
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
        let path = Bundle.main.bundleURL.path
        if !path.hasPrefix("/Applications/") {
            throw TunnelSystemExtensionError.notInApplications(path)
        }
        try await Activator.shared.activate()
    }
}

enum TunnelSystemExtensionError: Error, LocalizedError {
    case notInApplications(String)
    case needsUserApproval

    var errorDescription: String? {
        switch self {
        case .notInApplications(let path):
            if path.contains("/DerivedData/") {
                return "This process is still the DerivedData build. Use the PrizmX scheme "
                    + "(it installs to /Applications and launches that copy), quit any extra "
                    + "PrizmX instance, then enable TUN again."
            }
            return "Move PrizmX to /Applications before enabling TUN. "
                + "System extensions cannot load from a DMG, Downloads, or Xcode's build folder."
        case .needsUserApproval:
            return "Enable PrizmX Tunnel in System Settings → General → Login Items & Extensions → Network Extensions, then turn TUN on again."
        }
    }
}

@MainActor
private final class Activator: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = Activator()
    private var inFlight: Task<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func activate() async throws {
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task { @MainActor in
            try await self.submit()
        }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    private func submit() async throws {
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
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) {
            NSWorkspace.shared.open(url)
        }
        finish(throwing: TunnelSystemExtensionError.needsUserApproval)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        TunnelLog.write(.info, "system extension ready result=\(result.rawValue)")
        finish()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        TunnelLog.write(.error, "system extension failed: \(error.localizedDescription)")
        finish(throwing: error)
    }

    private func finish(throwing error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
