import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

/// First-run Home: add a profile, then pick how traffic is taken over.
/// Shown while no profile exists, and until Done after the first one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var appModel
    var onDone: () -> Void

    @State private var urlString = ""
    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var skippedCount = 0

    private var store: ProfileStore { appModel.dashboard.profiles }

    var body: some View {
        @Bindable var appModel = appModel

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to PrizmX")
                            .font(.title.weight(.semibold))
                        Text("Route your Mac's traffic with a Clash, Surge or sing-box profile.")
                            .foregroundStyle(.secondary)
                    }
                }

                step(1, "Add a profile") {
                    if let profile = store.activeProfile {
                        Label("Installed \(profile.name)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if skippedCount > 0 {
                            Text("\(skippedCount) entries PrizmX does not support were skipped. Profiles lists them.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            TextField("Subscription URL", text: $urlString)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.URL)
                                .onSubmit { Task { await install() } }
                            Button(isInstalling ? "Installing…" : "Install") {
                                Task { await install() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstalling || urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Button("Import a File…") { importFile() }
                            .buttonStyle(.link)
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }

                step(2, "Choose how traffic goes through PrizmX") {
                    Toggle(isOn: $appModel.systemProxyEnabled) {
                        Text("System Proxy")
                        Text("Apps that follow macOS proxy settings (browsers, most apps) use PrizmX.")
                    }
                    Toggle(isOn: $appModel.tunModeEnabled) {
                        Text("TUN Mode")
                        Text("Also captures apps that ignore proxy settings. The first time, macOS asks you to allow the PrizmX Tunnel system extension in System Settings.")
                    }
                }
                .disabled(store.activeProfile == nil)
                .opacity(store.activeProfile == nil ? 0.5 : 1)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Share anonymous usage data", isOn: $appModel.analyticsEnabled)
                        .toggleStyle(.checkbox)
                    Text("App launches, versions, and whether TUN or System Proxy is on. Never profiles, nodes or traffic. You can change this in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.activeProfile != nil {
                    HStack {
                        Spacer()
                        Button("Done", action: onDone)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private func step<Content: View>(
        _ number: Int,
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("\(number). \(title)").font(.headline)
        }
    }

    private func install() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else {
            errorMessage = "Enter an http or https URL."
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let warnings = try await store.installSubscription(from: url)
            skippedCount = warnings.count
            errorMessage = nil
            appModel.didChangeActiveProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFile() {
        do {
            guard let result = try ProfileFileIO.importFromOpenPanel(into: store) else { return }
            skippedCount = result.warnings.count
            errorMessage = nil
            appModel.didChangeActiveProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Welcome") {
    WelcomeView(onDone: {})
        .environment(AppModel.preview)
        .frame(width: 760, height: 640)
}
