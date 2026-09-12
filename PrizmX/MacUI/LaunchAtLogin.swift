import ServiceManagement
import SwiftUI

/// Main-app login item. System Settings → General → Login Items is the source of truth.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled {
            switch status {
            case .enabled, .requiresApproval:
                return
            default:
                try SMAppService.mainApp.register()
            }
        } else if status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}

struct LaunchAtLoginToggle: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: SMAppService.Status = .notRegistered
    @State private var errorMessage: String?

    var body: some View {
        Toggle(isOn: Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: setEnabled
        )) {
            Text("Open at Login")
            Text(subtitle)
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private var subtitle: String {
        if let errorMessage { return errorMessage }
        if status == .requiresApproval {
            return "Allow PrizmX in System Settings → General → Login Items."
        }
        return "Start PrizmX when you log in."
    }

    private func refresh() {
        status = LaunchAtLogin.status
        if status == .enabled { errorMessage = nil }
    }

    private func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
        if enabled, status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
