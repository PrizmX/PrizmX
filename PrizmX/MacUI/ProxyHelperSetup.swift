import ServiceManagement
import SwiftUI
import PrizmXServices

/// The privileged helper that writes System Proxy settings without an
/// administrator prompt each session. System Settings → General → Login
/// Items is the source of truth, like `LaunchAtLogin`.
enum ProxyHelperSetup {
    /// Registers the helper the first time System Proxy is used and points
    /// the user at Login Items once. Until it is allowed there, the proxy
    /// settings are written with an authorization prompt as before.
    static func prepare() {
        // A failure is logged by `ProxyHelper` with its status.
        if (try? ProxyHelper.registerIfNeeded()) == true, ProxyHelper.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

struct ProxyHelperRow: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: SMAppService.Status = .notRegistered
    @State private var errorMessage: String?

    var body: some View {
        LabeledContent {
            switch status {
            case .enabled:
                Text("Allowed").foregroundStyle(.secondary)
            case .requiresApproval:
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            default:
                Button("Install", action: install)
            }
        } label: {
            Text("System Proxy Helper")
            Text(subtitle)
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private var subtitle: String {
        if let errorMessage { return errorMessage }
        switch status {
        case .enabled:
            return "Turns System Proxy on and off without asking for your password."
        case .requiresApproval:
            return "Allow PrizmX in System Settings → General → Login Items so System Proxy stops asking for your password."
        default:
            return "Without it, macOS asks for your password the first time System Proxy changes after each launch."
        }
    }

    private func refresh() {
        status = ProxyHelper.status
        if status == .enabled { errorMessage = nil }
    }

    private func install() {
        errorMessage = nil
        do {
            try ProxyHelper.registerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
