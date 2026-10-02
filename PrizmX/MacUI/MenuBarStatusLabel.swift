import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

/// Menu-bar extra label. SwiftUI is the only writer of the status-item image.
/// Catalog assets already encode the looks — do not bake pixels onto `NSStatusBarButton`.
struct MenuBarStatusLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        icon
            .accessibilityLabel(Text(accessibilityTitle))
            .help(accessibilityTitle)
            .background(MenuBarShortcutBridge())
    }

    /// The label keeps only its first Image (a VStack keeps only its first
    /// Text), so the rate column is composited into the icon image.
    /// Only this label reads the per-second rates; the dropdown must not.
    @ViewBuilder
    private var icon: some View {
        if appModel.showsMenuBarSpeed, let asset = NSImage(named: spec.assetName) {
            Image(nsImage: MenuBarSpeedImage.make(
                icon: asset,
                isTemplate: spec.renderingMode == .template,
                upload: appModel.dashboard.uploadSpeedString,
                download: appModel.dashboard.downloadSpeedString
            ))
        } else {
            Image(spec.assetName)
                .renderingMode(spec.renderingMode)
        }
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

/// Status-item image: the icon with upload over download to its right.
enum MenuBarSpeedImage {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let height: CGFloat = 22
    private static let lineHeight: CGFloat = 10.5
    private static let gap: CGFloat = 2
    private static let arrowWidth = ceil(max(width("↑"), width("↓")))
    /// Widest string `ByteRateFormatter` can produce, so the status item keeps
    /// one width and never nudges its menu-bar neighbours.
    private static let valueWidth = ceil(
        ["B/s", "KB/s", "MB/s", "GB/s"]
            .flatMap { unit in ["1000 \(unit)", "99.9 \(unit)"] }
            .map(width)
            .max() ?? 0
    )

    static func make(icon: NSImage, isTemplate: Bool, upload: String, download: String) -> NSImage {
        let textX = icon.size.width + gap
        let size = NSSize(width: textX + arrowWidth + valueWidth, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            // Runs at draw time under the menu bar's appearance, so a colored
            // icon picks its light/dark variant and `labelColor` matches the
            // bar. A template image is tinted by the system: draw it black.
            let color: NSColor = isTemplate ? .black : .labelColor
            icon.draw(in: NSRect(
                x: 0,
                y: (height - icon.size.height) / 2,
                width: icon.size.width,
                height: icon.size.height
            ))
            drawLine(arrow: "↑", value: upload, x: textX, y: height / 2, color: color)
            drawLine(arrow: "↓", value: download, x: textX, y: height / 2 - lineHeight, color: color)
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    /// Arrow left-aligned, value right-aligned, so both columns line up.
    private static func drawLine(arrow: String, value: String, x: CGFloat, y: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (arrow as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        let valueX = x + arrowWidth + valueWidth - width(value)
        (value as NSString).draw(at: NSPoint(x: valueX, y: y), withAttributes: attributes)
    }

    private static func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Lives on the always-mounted menu-bar label so shortcuts and dropdown hooks
/// work while the menu is closed.
private struct MenuBarShortcutBridge: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var dropdownHooks: MenuBarDropdownHooks?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: AppEvent.toggleVPN)) { _ in
                appModel.tunModeEnabled.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: AppEvent.presentNodePicker)) { _ in
                appModel.presentNodePicker(using: openWindow)
            }
            .onAppear {
                if dropdownHooks == nil {
                    dropdownHooks = MenuBarDropdownHooks(appModel: appModel)
                }
            }
    }
}

#Preview("Menu Bar Label") {
    MenuBarStatusLabel()
        .environment(AppModel.preview)
        .padding()
}
