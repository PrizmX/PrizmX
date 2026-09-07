import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIComponents
import PrizmXUIEngine

/// Menu-bar extra label.
/// SwiftUI `MenuBarExtra` snapshots the label as a **template** (alpha → system black/white).
/// Colored states replace that image on `NSStatusBarButton` with a baked non-template icon.
struct MenuBarStatusLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Image("MenuBarPrism")
            .renderingMode(.template)
            .accessibilityLabel(Text(accessibilityTitle))
            .help(accessibilityTitle)
            .background(MenuBarShortcutBridge())
            .background(MenuBarIconApplier(tint: menuBarTint))
    }

    /// `nil` = keep system black/white template. Otherwise bake this color into pixels.
    private var menuBarTint: NSColor? {
        if appModel.isVPNOn, appModel.httpCaptureEnabled {
            return NSColor(named: "MenuBarCapture")
        }
        if appModel.isVPNOn {
            switch appModel.menuBarConnectedStyle {
            case .monochrome:
                return nil
            case .accent:
                return NSColor(named: "AccentColor")
            }
        }
        return NSColor(named: "MenuBarIdle")
    }

    private var accessibilityTitle: String {
        "PrizmX \(appModel.dashboard.status.rawValue), download \(appModel.dashboard.downloadSpeedString), upload \(appModel.dashboard.uploadSpeedString)"
    }
}

private struct MenuBarIconApplier: NSViewRepresentable {
    var tint: NSColor?

    func makeNSView(context: Context) -> NSView {
        let view = MenuBarIconProbeView()
        view.iconTint = tint
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let probe = view as? MenuBarIconProbeView else { return }
        probe.iconTint = tint
        probe.applyIcon()
    }
}

private final class MenuBarIconProbeView: NSView {
    var iconTint: NSColor?
    private var isApplying = false
    private var imageObserver: NSKeyValueObservation?
    private var observedButton: NSStatusBarButton?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIcon()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyIcon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyIcon()
    }

    func applyIcon() {
        DispatchQueue.main.async { [weak self] in
            self?.applyIconNow()
        }
    }

    private func applyIconNow() {
        guard !isApplying else { return }
        guard let button = Self.statusButton(from: self) else { return }
        observeImageChanges(on: button)

        isApplying = true
        defer { isApplying = false }

        button.appearsDisabled = false
        button.contentTintColor = nil
        if let iconTint {
            button.image = Self.coloredPrism(tint: iconTint, appearance: button.effectiveAppearance)
        } else if let template = NSImage(named: "MenuBarPrism") {
            template.isTemplate = true
            button.image = template
        }
    }

    private func observeImageChanges(on button: NSStatusBarButton) {
        guard observedButton !== button else { return }
        observedButton = button
        imageObserver = button.observe(\.image, options: [.new]) { [weak self] _, _ in
            guard let self, !self.isApplying else { return }
            self.applyIconNow()
        }
    }

    private static func statusButton(from probe: NSView) -> NSStatusBarButton? {
        var current: NSView? = probe
        while let view = current {
            if let button = view as? NSStatusBarButton {
                return button
            }
            current = view.superview
        }
        for window in NSApp.windows {
            if let button = firstStatusButton(in: window.contentView) {
                return button
            }
        }
        if let items = NSStatusBar.system.value(forKey: "items") as? [NSStatusItem] {
            return items.compactMap(\.button).last
        }
        return nil
    }

    private static func firstStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let button = firstStatusButton(in: subview) {
                return button
            }
        }
        return nil
    }

    private static func coloredPrism(tint: NSColor, appearance: NSAppearance) -> NSImage {
        let fallback = NSImage(named: "MenuBarPrism") ?? NSImage(size: NSSize(width: 22, height: 22))
        let canvas = fallback.size.width > 0 ? fallback.size : NSSize(width: 22, height: 22)
        let image = NSImage(size: canvas, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                fallback.draw(in: rect)
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                context.setBlendMode(.sourceIn)
                context.setFillColor(tint.cgColor)
                context.fill(rect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Menu-bar panel. Avoid grouped Form here: MenuBarExtra cannot measure its height.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

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
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(sessionUptime(from: appModel.sessionStartedAt, now: context.date))
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
                .disabled(true)
                .help("Coming soon")

            Divider()

            Button {
                appModel.presentMain(using: openWindow, selecting: .more)
                appModel.presentedMoreSheet = .profiles
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

            LabeledContent("Download", value: appModel.dashboard.downloadSpeedString)
            LabeledContent("Upload", value: appModel.dashboard.uploadSpeedString)
            TrafficWaveform(points: appModel.dashboard.speedHistory)
                .frame(height: 56)

            Divider()

            Button("Open Console…") { appModel.presentMain(using: openWindow, selecting: .home) }
            Button("Inspector…") { appModel.presentInspector(using: openWindow) }
            Button("Settings…") { openSettings() }
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
