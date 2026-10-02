import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIComponents
import PrizmXUIEngine

/// Menu-bar dropdown, rendered as a native `NSMenu` (`.menuBarExtraStyle(.menu)`).
/// Only menu-representable views belong here: Button, Toggle (checkmark),
/// Picker / Menu (submenu), Divider, and Text (disabled info row). Anything
/// else is dropped, hence the chart placeholder below.
///
/// Whenever this body changes, SwiftUI re-applies every property of every
/// item, which resets the hover. Nothing read here may change per second:
/// live values go through `MenuBarDropdownHooks`, which touches only its row.
struct MenuBarMenu: View {
    /// Plain `String` (not localized) so the hooks can find the item by title.
    static let tunTitle = "TUN Mode"

    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var appModel = appModel

        Text(verbatim: MenuBarTrafficItem.placeholderTitle)

        Divider()

        // Uptime as of opening; the hooks advance it in place every second.
        Toggle(Self.tunTitle, isOn: $appModel.tunModeEnabled)
            .badge(Self.tunBadge(appModel, now: appModel.menuOpenedAt).map { Text(verbatim: $0) })
        Toggle("System Proxy", isOn: $appModel.systemProxyEnabled)

        Picker("Outbound Mode", selection: $appModel.outboundMode) {
            ForEach(OutboundMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }

        Divider()

        profileMenu
        policyMenu

        Divider()

        Button("Open Console…") { appModel.presentMain(using: openWindow, selecting: .home) }
            .keyboardShortcut("0", modifiers: .command)
        Button("Inspector…") { appModel.presentInspector(using: openWindow) }
            .keyboardShortcut("i", modifiers: .command)
        Button("Settings…") { appModel.presentSettings(using: openWindow) }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit PrizmX") { appModel.quit() }
            .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Profile / Policy

    private var profileMenu: some View {
        let store = appModel.dashboard.profiles
        return Menu("Profile: \(appModel.dashboard.activeProfileName)") {
            ForEach(store.profiles) { profile in
                Toggle(profile.name, isOn: Binding(
                    get: { profile.id == store.activeProfileID },
                    set: { isOn in if isOn { appModel.activateProfile(id: profile.id) } }
                ))
            }
            if !store.profiles.isEmpty {
                Divider()
            }
            Button("Manage Profiles…") {
                appModel.presentMain(using: openWindow, selecting: .profiles)
            }
        }
    }

    /// One submenu per `select` group, like the Policies pane.
    private var policyMenu: some View {
        let nodeList = appModel.nodeList
        return Menu("Node: \(appModel.dashboard.activeNodeName)") {
            ForEach(nodeList.policyGroupSections) { group in
                Menu(group.title) {
                    ForEach(group.members) { member in
                        Toggle(member.name, isOn: Binding(
                            get: { nodeList.selectedMemberID(inGroup: group.id) == member.id },
                            set: { isOn in
                                if isOn { appModel.selectPolicyMember(member.id, inGroup: group.id) }
                            }
                        ))
                        .disabled(member.isUnsupported)
                    }
                }
            }
            if !nodeList.policyGroupSections.isEmpty {
                Divider()
            }
            Button("Select Node…") { appModel.presentNodePicker(using: openWindow) }
                .keyboardShortcut("k", modifiers: .command)
        }
    }

    // MARK: - TUN badge

    /// Right side of TUN Mode: the transition while it flips, then the uptime.
    static func tunBadge(_ appModel: AppModel, now: Date) -> String? {
        switch appModel.dashboard.status {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        default:
            guard let start = appModel.sessionStartedAt else { return nil }
            return sessionUptime(from: start, now: now)
        }
    }
}

/// Session uptime (`h:mm:ss`, `mm:ss`).
private func sessionUptime(from start: Date, now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

/// The live chart row. SwiftUI's `.menu` style drops custom views, so it rides
/// on a placeholder item: when SwiftUI inserts that item, its `view` becomes a
/// hosting view. SwiftUI keeps the item, and the view, across later updates.
enum MenuBarTrafficItem {
    static let placeholderTitle = "Traffic"
    private static let width: CGFloat = 300

    /// True when `menu` is the dropdown and the chart was attached.
    static func attach(to menu: NSMenu, at index: Int, appModel: AppModel) -> Bool {
        guard menu.items.indices.contains(index) else { return false }
        let item = menu.items[index]
        guard item.title == placeholderTitle, item.view == nil else { return false }
        let host = NSHostingView(rootView: MenuBarTrafficChart().environment(appModel))
        host.frame.size = NSSize(width: width, height: host.fittingSize.height)
        host.autoresizingMask = [.width]
        item.view = host
        return true
    }
}

/// Live rates over the waveform. The hosting view outlives the open menu, so
/// the per-second rates are read only while the menu is on screen.
private struct MenuBarTrafficChart: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let live = appModel.menuOpen
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Upload")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(live ? appModel.dashboard.uploadSpeedString : "—")
                    .font(.body.monospacedDigit())
                Spacer(minLength: 8)
                Text("Download")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(live ? appModel.dashboard.downloadSpeedString : "—")
                    .font(.body.monospacedDigit())
            }
            TrafficWaveform(
                points: appModel.dashboard.speedHistory,
                series: .both,
                splitAxis: true
            )
            .frame(height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// AppKit side of the dropdown: attaches the chart and ticks the TUN uptime
/// badge in place. Observers run synchronously on the posting (main) thread,
/// so the chart is attached before the menu first draws; SwiftUI only inserts
/// the items after tracking has begun.
final class MenuBarDropdownHooks {
    private weak var appModel: AppModel?
    /// Known once the chart placeholder shows up in it.
    private weak var dropdown: NSMenu?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var badgeTimer: Timer?

    init(appModel: AppModel) {
        self.appModel = appModel
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: nil) { [weak self] note in
                let menu = note.object as? NSMenu
                let index = note.userInfo?["NSMenuItemIndex"] as? Int
                MainActor.assumeIsolated {
                    guard let self, let menu, let index else { return }
                    self.itemAdded(to: menu, at: index)
                }
            },
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let menu, Self.isRootPopup(menu) else { return }
                    self?.menuOpened()
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] note in
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let menu, Self.isRootPopup(menu) else { return }
                    self?.menuClosed()
                }
            }
        ]
    }

    deinit {
        badgeTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func itemAdded(to menu: NSMenu, at index: Int) {
        guard let appModel, MenuBarTrafficItem.attach(to: menu, at: index, appModel: appModel) else { return }
        dropdown = menu
    }

    private func menuOpened() {
        appModel?.menuDidOpen()
        guard badgeTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTunBadge() }
        }
        // Menu tracking spins the run loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        badgeTimer = timer
    }

    private func menuClosed() {
        badgeTimer?.invalidate()
        badgeTimer = nil
        appModel?.menuDidClose()
    }

    /// Sets only this item's badge. Also restores it within a second after a
    /// SwiftUI pass puts back the open-time value.
    private func tickTunBadge() {
        guard let appModel,
              let item = dropdown?.items.first(where: { $0.title == MenuBarMenu.tunTitle })
        else { return }
        let text = MenuBarMenu.tunBadge(appModel, now: .now)
        guard item.badge?.stringValue != text else { return }
        item.badge = text.map { NSMenuItemBadge(string: $0) }
    }

    /// The dropdown can't be told apart at tracking start (it has no items
    /// yet on first open); any root non-main menu counts, at the cost of a
    /// 1 Hz timer while a context menu is open.
    private static func isRootPopup(_ menu: NSMenu) -> Bool {
        menu !== NSApp.mainMenu && menu.supermenu == nil
    }
}
