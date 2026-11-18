import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

/// Owns the macOS status item and its AppKit dropdown menu directly, avoiding
/// SwiftUI `MenuBarExtra` item-array rebuilds and fullscreen Space issues.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private weak var appModel: AppModel?
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let rows: MenuBarDropdownItems
    nonisolated(unsafe) private var tickTimer: Timer?
    nonisolated(unsafe) private var eventObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var spaceObserver: NSObjectProtocol?
    private var lastAccessibilityTitle: String?
    private var temporarilyAccessory = false
    private var presentationObserver: NSKeyValueObservation?
    private var isTracking = false

    init(appModel: AppModel) {
        self.appModel = appModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rows = MenuBarDropdownItems(appModel: appModel)
        super.init()

        menu.delegate = self
        rows.install(in: menu)
        rows.refresh()

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        let center = NotificationCenter.default
        eventObservers = [
            center.addObserver(forName: AppEvent.toggleVPN, object: nil, queue: .main) { [weak appModel] _ in
                MainActor.assumeIsolated {
                    appModel?.tunModeEnabled.toggle()
                }
            },
            center.addObserver(forName: AppEvent.presentNodePicker, object: nil, queue: .main) { [weak appModel] _ in
                MainActor.assumeIsolated {
                    appModel?.presentNodePicker()
                }
            },
        ]
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menu.cancelTrackingWithoutAnimation()
            }
        }

        configureMenuPresentation()
        presentationObserver = NSApp.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            Task { @MainActor in self?.configureMenuPresentation() }
        }
        observeStatusIcon()
    }

    // On a normal desktop the status item owns the menu before mouse-down:
    // AppKit handles highlighting, tracking and Space transitions itself.
    // Reserve the pre-click activation-policy workaround for fullscreen only.
    private func configureMenuPresentation() {
        guard !isTracking, !temporarilyAccessory else { return }
        if NSApp.currentSystemPresentationOptions.contains(.fullScreen), NSApp.activationPolicy() == .regular {
            statusItem.menu = nil
            statusItem.button?.target = self
            statusItem.button?.action = #selector(statusItemClicked(_:))
        } else if statusItem.menu !== menu {
            statusItem.menu = menu
        }
    }

    deinit {
        tickTimer?.invalidate()
        eventObservers.forEach(NotificationCenter.default.removeObserver)
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    private func observeStatusIcon() {
        withObservationTracking {
            updateStatusIcon()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStatusIcon()
            }
        }
    }

    private func updateStatusIcon() {
        guard let appModel, let button = statusItem.button else { return }
        let spec = MenuBarIconSpec(
            state: appModel.menuBarSessionState,
            connectedStyle: appModel.menuBarConnectedStyle
        )
        if appModel.showsMenuBarSpeed, let asset = NSImage(named: spec.assetName) {
            button.image = MenuBarSpeedImage.make(
                icon: asset,
                isTemplate: spec.isTemplate,
                upload: appModel.dashboard.uploadSpeedString,
                download: appModel.dashboard.downloadSpeedString
            )
        } else if let asset = NSImage(named: spec.assetName)?.copy() as? NSImage {
            asset.isTemplate = spec.isTemplate
            button.image = asset
        }

        let title = "PrizmX, \(appModel.menuBarSessionState.title)"
        if lastAccessibilityTitle != title {
            lastAccessibilityTitle = title
            button.setAccessibilityLabel(title)
            button.toolTip = title
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard statusItem.menu == nil else { return }
        if appModel?.menuBarOnly == false, !NSApp.isActive, NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
            temporarilyAccessory = true
        }
        statusItem.menu = menu
        sender.performClick(nil)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isTracking = true
        appModel?.menuDidOpen()
        rows.refresh()
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rows.refresh()
                self?.rows.policyMenu.refreshOpenGroup()
            }
        }
        // Menu tracking spins the run loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isTracking = false
        tickTimer?.invalidate()
        tickTimer = nil
        rows.policyMenu.reset()
        appModel?.menuDidClose()
        if temporarilyAccessory {
            temporarilyAccessory = false
            if appModel?.menuBarOnly == false {
                NSApp.setActivationPolicy(.regular)
            }
        }
        configureMenuPresentation()
    }
}

private struct MenuBarIconSpec {
    var assetName: String
    var isTemplate: Bool

    /// States differ by shape as well as tone, so they stay apart on light,
    /// dark and wallpaper-tinted bars and in black and white: off is a dimmed
    /// outline, system proxy a full outline, TUN a filled core.
    init(state: MenuBarSessionState, connectedStyle: MenuBarConnectedStyle) {
        switch state {
        case .idle:
            assetName = "MenuBarPrismIdle"
            isTemplate = true
        case .systemProxy:
            assetName = "MenuBarPrism"
            isTemplate = true
        case .tun:
            if connectedStyle == .monochrome {
                assetName = "MenuBarPrismTun"
                isTemplate = true
            } else {
                assetName = "MenuBarPrismOn"
                isTemplate = false
            }
        case .capture:
            assetName = "MenuBarPrismOn"
            isTemplate = false
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
            .map { width($0) }
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
