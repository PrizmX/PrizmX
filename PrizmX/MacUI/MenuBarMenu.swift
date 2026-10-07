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

        // Not a dependency on time: the hooks set the uptime in place when the
        // menu opens and every second while it is open.
        Toggle(Self.tunTitle, isOn: $appModel.tunModeEnabled)
            .badge(Self.tunBadge(appModel, now: .now).map { Text(verbatim: $0) })
        Toggle("System Proxy", isOn: $appModel.systemProxyEnabled)

        Picker("Outbound Mode", selection: $appModel.outboundMode) {
            ForEach(OutboundMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }

        Divider()

        profileMenu
        // Slot for the AppKit Node submenu (`MenuBarNodeMenu`): a SwiftUI
        // item per policy member costs ~30 KB, and profiles list thousands.
        Button(MenuBarNodeMenu.placeholderTitle) {}

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

    // MARK: - Profile

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

/// The Node submenu, one submenu per `select` group like the Policies pane.
/// Built in AppKit when it opens and a group's members only when that group
/// opens, so nothing per node stays resident. SwiftUI owns only the slot
/// item; its title and submenu are put back whenever a SwiftUI pass resets
/// them.
final class MenuBarNodeMenu: NSObject, NSMenuDelegate {
    static let placeholderTitle = "Node"

    private final class GroupMenu: NSMenu {
        var groupID = ""
    }

    private struct Choice {
        var groupID: String
        var memberID: String
    }

    private weak var appModel: AppModel?
    private weak var slot: NSMenuItem?
    private let menu = NSMenu()
    /// Snapshot taken when the submenu opens; group submenus read it.
    private var sections: [PolicyGroupSection] = []

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    /// True when `menu` holds the slot at `index`, which now hosts the submenu.
    func attach(to menu: NSMenu, at index: Int) -> Bool {
        guard menu.items.indices.contains(index),
              menu.items[index].title == Self.placeholderTitle
        else { return false }
        slot = menu.items[index]
        refreshSlot()
        return true
    }

    /// Re-applies the slot after any change to its item.
    func itemChanged(in menu: NSMenu, at index: Int) {
        guard let slot, menu.items.indices.contains(index), menu.items[index] === slot else { return }
        refreshSlot()
    }

    /// Writes only what differs, so the change notification it posts is a no-op.
    func refreshSlot() {
        guard let slot, let appModel else { return }
        let title = "Node: \(appModel.dashboard.activeNodeName)"
        if slot.title != title {
            slot.title = title
        }
        if slot.submenu !== menu {
            slot.submenu = menu
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let group = menu as? GroupMenu {
            fillMembers(of: group)
        } else if menu === self.menu {
            fillGroups()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        sections = []
    }

    private func fillGroups() {
        menu.removeAllItems()
        sections = appModel?.nodeList.policyGroupSections ?? []
        for section in sections {
            let item = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            let submenu = GroupMenu(title: section.title)
            submenu.groupID = section.id
            submenu.autoenablesItems = false
            submenu.delegate = self
            item.submenu = submenu
            menu.addItem(item)
        }
        if !sections.isEmpty {
            menu.addItem(.separator())
        }
        let picker = NSMenuItem(title: "Select Node…", action: #selector(selectNode), keyEquivalent: "k")
        picker.keyEquivalentModifierMask = .command
        picker.target = self
        menu.addItem(picker)
    }

    private func fillMembers(of group: GroupMenu) {
        group.removeAllItems()
        guard let appModel,
              let section = sections.first(where: { $0.id == group.groupID })
        else { return }
        let selected = appModel.nodeList.selectedMemberID(inGroup: section.id)
        for member in section.members {
            let item = NSMenuItem(title: member.name, action: #selector(selectMember(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Choice(groupID: section.id, memberID: member.id)
            item.state = member.id == selected ? .on : .off
            item.isEnabled = !member.isUnsupported
            group.addItem(item)
        }
    }

    @objc private func selectMember(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice,
              let appModel,
              appModel.nodeList.selectedMemberID(inGroup: choice.groupID) != choice.memberID
        else { return }
        appModel.selectPolicyMember(choice.memberID, inGroup: choice.groupID)
    }

    @objc private func selectNode() {
        NotificationCenter.default.post(name: AppEvent.presentNodePicker, object: nil)
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

/// AppKit side of the dropdown: attaches the chart and the Node submenu, and
/// ticks the TUN uptime badge in place. Observers run synchronously on the
/// posting (main) thread, so both are attached before the menu first draws;
/// SwiftUI only inserts the items after tracking has begun.
final class MenuBarDropdownHooks {
    private weak var appModel: AppModel?
    /// Known once the chart placeholder shows up in it.
    private weak var dropdown: NSMenu?
    private let nodeMenu: MenuBarNodeMenu
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var badgeTimer: Timer?

    init(appModel: AppModel) {
        self.appModel = appModel
        nodeMenu = MenuBarNodeMenu(appModel: appModel)
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
            // SwiftUI re-applies every item when the menu content changes.
            center.addObserver(forName: NSMenu.didChangeItemNotification, object: nil, queue: nil) { [weak self] note in
                let menu = note.object as? NSMenu
                let index = note.userInfo?["NSMenuItemIndex"] as? Int
                MainActor.assumeIsolated {
                    guard let self, let menu, let index else { return }
                    self.nodeMenu.itemChanged(in: menu, at: index)
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
        // The chart placeholder comes first and identifies the dropdown; other
        // menus (a "Node" table column's header menu) may reuse the title.
        if menu === dropdown, nodeMenu.attach(to: menu, at: index) { return }
        guard let appModel, MenuBarTrafficItem.attach(to: menu, at: index, appModel: appModel) else { return }
        dropdown = menu
    }

    private func menuOpened() {
        appModel?.menuDidOpen()
        nodeMenu.refreshSlot()
        tickTunBadge()
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
