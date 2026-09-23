import SwiftUI
import PrizmXServices
import PrizmXUIComponents
import PrizmXUIEngine

/// Menu-bar extra label. SwiftUI is the only writer of the status-item image.
/// Catalog assets already encode the looks — do not bake pixels onto `NSStatusBarButton`.
struct MenuBarStatusLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Image(spec.assetName)
            .renderingMode(spec.renderingMode)
            .accessibilityLabel(Text(accessibilityTitle))
            .help(accessibilityTitle)
            .background(MenuBarShortcutBridge())
    }

    private var spec: MenuBarIconSpec {
        MenuBarIconSpec(
            state: appModel.menuBarSessionState,
            connectedStyle: appModel.menuBarConnectedStyle
        )
    }

    private var accessibilityTitle: String {
        "PrizmX, \(appModel.menuBarSessionState.title)"
    }
}

private struct MenuBarIconSpec {
    var assetName: String
    var renderingMode: Image.TemplateRenderingMode

    init(state: MenuBarSessionState, connectedStyle: MenuBarConnectedStyle) {
        switch state {
        case .idle:
            assetName = "MenuBarPrismIdle"
            renderingMode = .original
        case .systemProxy:
            // Template so it stays distinct from idle gray and TUN purple
            // without a fourth catalog image.
            assetName = "MenuBarPrism"
            renderingMode = .template
        case .tun:
            if connectedStyle == .monochrome {
                assetName = "MenuBarPrism"
                renderingMode = .template
            } else {
                assetName = "MenuBarPrismOn"
                renderingMode = .original
            }
        case .capture:
            assetName = "MenuBarPrismOn"
            renderingMode = .original
        }
    }
}

/// Menu-bar panel. Avoid grouped Form here: MenuBarExtra cannot measure its height.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PrizmX")
                        .font(.headline)
                    if let caption = statusCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if appModel.menuPanelPresented {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(sessionUptime(from: appModel.sessionStartedAt, now: context.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // Popover closed: render a frozen value so no 1s
                        // scheduler runs in the always-mounted panel graph.
                        Text(sessionUptime(from: appModel.sessionStartedAt, now: .now))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle(
                    appModel.isVPNOn ? "Connected" : "Disconnected",
                    isOn: $appModel.tunModeEnabled
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(appModel.isVPNOn ? "Disconnect" : "Connect")
            }

            Picker("Mode", selection: $appModel.outboundMode) {
                ForEach(OutboundMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("System Proxy", isOn: $appModel.systemProxyEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("HTTP, HTTPS, and SOCKS via mixed-port")

            Divider()

            Button {
                appModel.presentMain(using: openWindow, selecting: .profiles)
            } label: {
                LabeledContent("Profile", value: appModel.dashboard.activeProfileName)
            }
            .buttonStyle(.plain)

            Button {
                appModel.presentNodePicker(using: openWindow)
            } label: {
                LabeledContent("Node", value: appModel.dashboard.activeNodeName)
            }
            .buttonStyle(.plain)

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Upload")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appModel.dashboard.uploadSpeedString)
                    .font(.body.monospacedDigit())
                Spacer(minLength: 8)
                Text("Download")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appModel.dashboard.downloadSpeedString)
                    .font(.body.monospacedDigit())
            }
            TrafficWaveform(
                points: appModel.dashboard.speedHistory,
                series: .both,
                splitAxis: true
            )
            .frame(height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Divider()

            Button("Open Console…") { appModel.presentMain(using: openWindow, selecting: .home) }
            Button("Inspector…") { appModel.presentInspector(using: openWindow) }
            Button("Settings…") { appModel.presentSettings(using: openWindow) }
            Button("Quit PrizmX", role: .destructive) { appModel.quit() }
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: true)
        .onChange(of: appModel.dashboard.status) { _, _ in
            appModel.refreshSessionClock()
        }
    }

    /// Transition feedback while the system applies the toggle.
    private var statusCaption: String? {
        switch appModel.dashboard.status {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .disconnecting: "Disconnecting…"
        default: nil
        }
    }
}

/// Session uptime shown under the menu-bar title (`h:mm:ss`, `mm:ss`).
private func sessionUptime(from start: Date?, now: Date) -> String {
    guard let start else { return "— — : — —" }
    let total = max(0, Int(now.timeIntervalSince(start)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

/// Lives on the always-mounted menu-bar label so shortcuts work when the popover is closed.
private struct MenuBarShortcutBridge: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: AppEvent.toggleVPN)) { _ in
                appModel.tunModeEnabled.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: AppEvent.presentNodePicker)) { _ in
                appModel.presentNodePicker(using: openWindow)
            }
    }
}

#Preview("Menu Bar Panel") {
    MenuBarPanel()
        .environment(AppModel.preview)
}

#Preview("Menu Bar Label") {
    MenuBarStatusLabel()
        .environment(AppModel.preview)
        .padding()
}
