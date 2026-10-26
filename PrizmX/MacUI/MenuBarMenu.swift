import AppKit
import SwiftUI
import PrizmXNodes
import PrizmXServices
import PrizmXUIComponents
import PrizmXUIEngine

/// Menu-bar dropdown (`.menuBarExtraStyle(.menu)`). SwiftUI renders only the
/// chart placeholder; every other row is AppKit (`MenuBarDropdownItems`),
/// appended by the hooks. SwiftUI items get re-applied on every pass, which
/// swaps the submenus of Picker / Menu items (closing whatever submenu is
/// open) and clears what SwiftUI did not set, so no row may be SwiftUI's.
///
/// Known issue: an app-graph update makes MenuBarExtra replace the whole item
/// array (`setItemArray`), appended rows included; while the app is active,
/// opening a submenu triggers one. The open Policies submenus then close and
/// a pending one may show on its own. See `docs/menu-bar.md`.
struct MenuBarMenu: View {
    var body: some View {
        Text(verbatim: MenuBarTrafficItem.placeholderTitle)
    }
}

/// The live chart row. SwiftUI's `.menu` style drops custom views, so it rides
/// on a placeholder item: when SwiftUI inserts that item, its `view` becomes a
/// hosting view. SwiftUI keeps the item, and the view, across later updates.
enum MenuBarTrafficItem {
    static let placeholderTitle = "Traffic"
    private static let width: CGFloat = 300

    /// No-op once the chart is attached.
    static func attach(to item: NSMenuItem, appModel: AppModel) {
        guard item.view == nil else { return }
        let host = NSHostingView(rootView: MenuBarTrafficChart().environment(appModel))
        host.frame.size = NSSize(width: width, height: host.fittingSize.height)
        host.autoresizingMask = [.width]
        item.view = host
    }
}

/// The dropdown rows below the chart. Built once and kept across opens;
/// `refresh()` writes only what differs, so ticking it while the menu is
/// open leaves the hover alone.
final class MenuBarDropdownItems: NSObject, NSMenuDelegate {
    private weak var appModel: AppModel?
    private let openWindow: OpenWindowAction
    let policyMenu: MenuBarPolicyMenu
    private var items: [NSMenuItem] = []

    private let tunItem = NSMenuItem(title: "TUN Mode", action: #selector(toggleTun), keyEquivalent: "")
    private let proxyItem = NSMenuItem(title: "System Proxy", action: #selector(toggleProxy), keyEquivalent: "")
    private let outboundMenu = NSMenu()
    private let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
    private let profileMenu = NSMenu()

    init(appModel: AppModel, openWindow: OpenWindowAction) {
        self.appModel = appModel
        self.openWindow = openWindow
        policyMenu = MenuBarPolicyMenu(appModel: appModel)
        super.init()

        for mode in OutboundMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectOutbound(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            outboundMenu.addItem(item)
        }
        let outboundItem = NSMenuItem(title: "Outbound Mode", action: nil, keyEquivalent: "")
        outboundItem.submenu = outboundMenu
        profileMenu.delegate = self
        profileItem.submenu = profileMenu

        items = [
            .separator(),
            tunItem,
            proxyItem,
            outboundItem,
            .separator(),
            profileItem,
            policyMenu.item,
            .separator(),
            Self.command("Open Console…", "0", #selector(openConsole)),
            Self.command("Inspector…", "i", #selector(openInspector)),
            Self.command("Settings…", ",", #selector(openSettings)),
            .separator(),
            Self.command("Quit PrizmX", "q", #selector(quit)),
        ]
        for item in items + outboundMenu.items where item.action != nil {
            item.target = self
        }
    }

    private static func command(_ title: String, _ key: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        return item
    }

    /// True when the rows sit in no menu or in `menu`; moving them out of
    /// a menu on screen would orphan an open submenu.
    func isFree(for menu: NSMenu) -> Bool {
        tunItem.menu == nil || tunItem.menu === menu
    }

    /// Appends the rows after the chart, once per dropdown menu.
    func install(in menu: NSMenu) {
        guard tunItem.menu !== menu else { return }
        for item in items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    func refresh() {
        guard let appModel else { return }
        tunItem.setChecked(appModel.tunModeEnabled)
        tunItem.setBadgeText(Self.tunBadge(appModel, now: .now))
        proxyItem.setChecked(appModel.systemProxyEnabled)
        for item in outboundMenu.items {
            item.setChecked(item.representedObject as? String == appModel.outboundMode.rawValue)
        }
        profileItem.setTitleText("Profile: \(appModel.dashboard.activeProfileName)")
    }

    /// Right side of TUN Mode: the transition while it flips, then the uptime.
    private static func tunBadge(_ appModel: AppModel, now: Date) -> String? {
        switch appModel.dashboard.status {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        default:
            guard let start = appModel.sessionStartedAt else { return nil }
            return sessionUptime(from: start, now: now)
        }
    }

    // MARK: Profile submenu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === profileMenu, let appModel else { return }
        menu.removeAllItems()
        let store = appModel.dashboard.profiles
        for profile in store.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.setChecked(profile.id == store.activeProfileID)
            menu.addItem(item)
        }
        if !store.profiles.isEmpty {
            menu.addItem(.separator())
        }
        let manage = NSMenuItem(title: "Manage Profiles…", action: #selector(manageProfiles), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    // MARK: Actions

    @objc private func toggleTun() {
        appModel?.tunModeEnabled.toggle()
    }

    @objc private func toggleProxy() {
        appModel?.systemProxyEnabled.toggle()
    }

    @objc private func selectOutbound(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = OutboundMode(rawValue: raw)
        else { return }
        appModel?.outboundMode = mode
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let appModel,
              appModel.dashboard.profiles.activeProfileID != id
        else { return }
        appModel.activateProfile(id: id)
    }

    @objc private func manageProfiles() {
        appModel?.presentMain(using: openWindow, selecting: .profiles)
    }

    @objc private func openConsole() {
        appModel?.presentMain(using: openWindow, selecting: .home)
    }

    @objc private func openInspector() {
        appModel?.presentInspector(using: openWindow)
    }

    @objc private func openSettings() {
        appModel?.presentSettings(using: openWindow)
    }

    @objc private func quit() {
        appModel?.quit()
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

/// The Policies submenu, one submenu per policy group like the Policies pane.
/// Built when it first opens in a session and a group's members only when
/// that group opens (a SwiftUI item per member costs ~30 KB, and profiles
/// list thousands). Nothing is removed while the dropdown may still show it:
/// a submenu whose parent item goes away mid-open still appears, on its own,
/// shown and hidden with the app's activation. Stale rows are replaced when
/// the next session opens the submenu.
final class MenuBarPolicyMenu: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "Policies", action: nil, keyEquivalent: "")

    /// Carries its own snapshot: AppKit may reopen the Policies submenu without
    /// asking it to update, so a group must not depend on shared state that
    /// a close of its parent clears.
    private final class GroupMenu: NSMenu {
        var section = PolicyGroupSection(id: "", title: "", members: [])
        var latencyColumn = NSParagraphStyle()
    }

    private final class Choice {
        let groupID: String
        let memberID: String
        let name: String
        let node: OutboundNode?
        /// The latency text on screen, so a tick writes only what changed.
        var shownLatency: String?

        init(groupID: String, memberID: String, name: String, node: OutboundNode?) {
            self.groupID = groupID
            self.memberID = memberID
            self.name = name
            self.node = node
        }
    }

    private weak var appModel: AppModel?
    private let menu = NSMenu()
    /// Built in this session; `reset()` marks them stale.
    private var groupsAreCurrent = false
    /// On screen now; its latencies follow a running test.
    private weak var openGroup: GroupMenu?
    /// Runs while a test started here is in flight, so results land as they
    /// arrive rather than on the hooks' 1 Hz tick.
    nonisolated(unsafe) private var testTimer: Timer?

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.submenu = menu
    }

    deinit {
        testTimer?.invalidate()
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let group = menu as? GroupMenu {
            fillMembers(of: group)
        } else if menu === self.menu, !groupsAreCurrent {
            fillGroups()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let group = menu as? GroupMenu {
            openGroup = group
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === openGroup {
            openGroup = nil
        }
    }

    /// The dropdown closed: the groups go stale but stay in place.
    func reset() {
        stopTestTimer()
        openGroup = nil
        groupsAreCurrent = false
    }

    /// Ticked by the hooks while the dropdown is open.
    func refreshOpenGroup() {
        guard let group = openGroup, let appModel else { return }
        let nodeList = appModel.nodeList
        for item in group.items {
            (item.view as? MenuActionView)?.isEnabled = !nodeList.isPinging
        }
        for item in group.items {
            guard let choice = item.representedObject as? Choice else { continue }
            Self.applyLatency(item, choice: choice, nodeList: nodeList, column: group.latencyColumn)
        }
    }

    private func fillGroups() {
        groupsAreCurrent = true
        menu.removeAllItems()
        let sections = appModel?.nodeList.policyGroupSections ?? []
        for section in sections {
            let item = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            let submenu = GroupMenu(title: section.title)
            submenu.section = section
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
        guard let appModel else { return }
        let section = group.section
        let nodeList = appModel.nodeList
        let selected = nodeList.selectedMemberID(inGroup: section.id)
        group.latencyColumn = Self.latencyColumn(for: section.members.map(\.name))
        // AppKit sizes a row without its image attachment or the indent of
        // the check column; a tag past that width is not drawn at all.
        group.minimumWidth = (group.latencyColumn.tabStops.first?.location ?? 0) + Self.latencyColumnInset
        // Like Surge's Benchmark: on top, and pressing it keeps the menu open.
        if section.members.contains(where: { $0.node != nil }) {
            let test = NSMenuItem()
            let view = MenuActionView(title: "Test Latency", busyTitle: "Testing…")
            view.isEnabled = !nodeList.isPinging
            view.onPress = { [weak self, weak view] in
                view?.isEnabled = false
                self?.testGroup(section.id)
            }
            test.view = view
            group.addItem(test)
            group.addItem(.separator())
        }
        for member in section.members {
            let item = NSMenuItem(title: member.name, action: #selector(selectMember(_:)), keyEquivalent: "")
            item.target = self
            let choice = Choice(groupID: section.id, memberID: member.id, name: member.name, node: member.node)
            item.representedObject = choice
            item.state = member.id == selected ? .on : .off
            item.isEnabled = !member.isUnsupported
            Self.applyLatency(item, choice: choice, nodeList: nodeList, column: group.latencyColumn)
            group.addItem(item)
        }
    }

    private static let titleFont = NSFont.menuFont(ofSize: 0)
    private static let tagFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let tagHeight: CGFloat = 16
    private static let tagPadding: CGFloat = 7
    /// Room beside the tag column: the title's indent past a check column
    /// (about 30 pt) plus a right margin of the same weight.
    private static let latencyColumnInset: CGFloat = 48

    /// A right tab past the widest name, so the tags line up in a column.
    private static func latencyColumn(for names: [String]) -> NSParagraphStyle {
        let nameWidth = names.map { ($0 as NSString).size(withAttributes: [.font: titleFont]).width }.max() ?? 0
        let tagWidth = latencyTag(LatencyFormat.label(nil), color: .labelColor).size.width
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: ceil(nameWidth + 24 + tagWidth))]
        return style
    }

    /// A badge-like capsule in a color. `NSMenuItemBadge` takes none, so the
    /// tag is drawn into an image; the handler runs at draw time, under the
    /// menu's appearance. The text is pulled toward the label color to stay
    /// readable on the tinted fill (yellow on light, mostly).
    private static func latencyTag(_ text: String, color: NSColor) -> NSImage {
        let textSize = (text as NSString).size(withAttributes: [.font: tagFont])
        let size = NSSize(width: ceil(textSize.width) + tagPadding * 2, height: tagHeight)
        return NSImage(size: size, flipped: false) { rect in
            color.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let textColor = color.blended(withFraction: 0.3, of: .labelColor) ?? color
            (text as NSString).draw(
                at: NSPoint(x: tagPadding, y: (rect.height - textSize.height) / 2),
                withAttributes: [.font: tagFont, .foregroundColor: textColor]
            )
            return true
        }
    }

    /// The latency as a tag right of the name, in the Policies pane's colors
    /// (`LatencyFormat`); "…" while a test is on its way.
    private static func applyLatency(
        _ item: NSMenuItem,
        choice: Choice,
        nodeList: NodeListViewModel,
        column: NSParagraphStyle
    ) {
        guard let node = choice.node else { return }
        let latency: (text: String, color: NSColor)?
        if nodeList.hasPingResult(for: node) {
            let milliseconds = nodeList.latency(for: node)
            latency = (LatencyFormat.label(milliseconds), NSColor(LatencyFormat.color(milliseconds)))
        } else if nodeList.isPinging {
            latency = ("…", .secondaryLabelColor)
        } else {
            latency = nil
        }
        guard choice.shownLatency != latency?.text else { return }
        choice.shownLatency = latency?.text
        guard let latency else {
            item.attributedTitle = nil
            item.title = choice.name
            return
        }
        let title = NSMutableAttributedString(string: "\(choice.name)\t", attributes: [.font: titleFont])
        let attachment = NSTextAttachment()
        let tag = latencyTag(latency.text, color: latency.color)
        attachment.image = tag
        attachment.bounds = CGRect(
            x: 0,
            y: (titleFont.capHeight - tag.size.height) / 2,
            width: tag.size.width,
            height: tag.size.height
        )
        title.append(NSAttributedString(attachment: attachment))
        title.addAttribute(.paragraphStyle, value: column, range: NSRange(location: 0, length: title.length))
        item.attributedTitle = title
    }

    private func testGroup(_ groupID: String) {
        guard let appModel, !appModel.nodeList.isPinging else { return }
        Task { await appModel.nodeList.pingGroup(groupID) }
        stopTestTimer()
        // The first tick comes after the test has set `isPinging`; a test
        // that already ended still gets its results painted once.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshOpenGroup()
                if self.appModel?.nodeList.isPinging != true {
                    self.stopTestTimer()
                }
            }
        }
        // Menu tracking spins the run loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        testTimer = timer
    }

    private func stopTestTimer() {
        testTimer?.invalidate()
        testTimer = nil
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

/// Setters that write only what differs: an item change makes an open menu
/// lay out again.
private extension NSMenuItem {
    /// In an open menu, a badge replaced by another keeps the old capsule size
    /// until the next change ("40" for "40 ms"); one added fresh is sized for
    /// its own text, so the old badge goes first.
    func setBadgeText(_ text: String?) {
        guard badge?.stringValue != text else { return }
        badge = nil
        badge = text.map { NSMenuItemBadge(string: $0) }
    }

    func setTitleText(_ text: String) {
        if title != text {
            title = text
        }
    }

    func setChecked(_ checked: Bool) {
        let value: NSControl.StateValue = checked ? .on : .off
        if state != value {
            state = value
        }
    }
}

/// A menu row that runs its action without closing the menu (a plain item's
/// click ends tracking). Drawn to match a native row: same height, inset,
/// corner radius and accent highlight.
private final class MenuActionView: NSView {
    var onPress: (() -> Void)?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            label.stringValue = isEnabled ? title : busyTitle
            needsDisplay = true
        }
    }

    private let title: String
    private let busyTitle: String
    private let label = NSTextField(labelWithString: "")

    init(title: String, busyTitle: String) {
        self.title = title
        self.busyTitle = busyTitle
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        autoresizingMask = [.width]
        label.stringValue = title
        label.font = .menuFont(ofSize: 0)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var isHighlighted: Bool {
        isEnabled && enclosingMenuItem?.isHighlighted == true
    }

    override func draw(_ dirtyRect: NSRect) {
        label.textColor = !isEnabled ? .disabledControlTextColor
            : isHighlighted ? .selectedMenuItemTextColor : .labelColor
        guard isHighlighted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 8, yRadius: 8).fill()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onPress?()
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

/// AppKit side of the dropdown: attaches the chart and the rows below it, and
/// ticks them while the menu is open. Observers run synchronously on the
/// posting (main) thread, so the rows are in place before the menu first
/// draws; SwiftUI only inserts its placeholder after tracking has begun.
final class MenuBarDropdownHooks {
    private weak var appModel: AppModel?
    private let rows: MenuBarDropdownItems
    /// Known once the chart placeholder shows up in it.
    private weak var dropdown: NSMenu?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var tickTimer: Timer?
    /// Between a root menu's tracking start and end.
    private var isTracking = false

    init(appModel: AppModel, openWindow: OpenWindowAction) {
        self.appModel = appModel
        rows = MenuBarDropdownItems(appModel: appModel, openWindow: openWindow)
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
        tickTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The placeholder is the dropdown's only SwiftUI item, so it sits first;
    /// before the rows go in, it is alone (another menu may reuse the title).
    private func itemAdded(to menu: NSMenu, at index: Int) {
        guard let appModel, index == 0,
              menu.items.first?.title == MenuBarTrafficItem.placeholderTitle,
              menu === dropdown || menu.items.count == 1
        else { return }
        MenuBarTrafficItem.attach(to: menu.items[0], appModel: appModel)
        dropdown = menu
        // A new dropdown built while the old one is on screen waits for the
        // next open: the rows may be showing a submenu in the old one.
        guard !isTracking || rows.isFree(for: menu) else { return }
        rows.install(in: menu)
        rows.refresh()
    }

    private func menuOpened() {
        isTracking = true
        appModel?.menuDidOpen()
        if let dropdown {
            rows.install(in: dropdown)
        }
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

    private func menuClosed() {
        isTracking = false
        tickTimer?.invalidate()
        tickTimer = nil
        rows.policyMenu.reset()
        appModel?.menuDidClose()
    }

    /// The dropdown can't be told apart at tracking start (it has no items
    /// yet on first open); any root non-main menu counts, at the cost of a
    /// 1 Hz timer while a context menu is open.
    private static func isRootPopup(_ menu: NSMenu) -> Bool {
        menu !== NSApp.mainMenu && menu.supermenu == nil
    }
}
