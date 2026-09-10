import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

struct AppsPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MetricCard(title: "Traffic", systemImage: "chart.bar") {
                    TrafficBarChart(
                        categories: [],
                        emptySystemImage: SidebarItem.apps.systemImage,
                        emptyDescription: "Process-level traffic appears when TUN captures local apps."
                    )
                    .frame(minHeight: 180)
                }
            }
            .padding(20)
        }
        .navigationTitle("Apps")
    }
}

struct LANPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section {
                Toggle("Allow LAN", isOn: $appModel.allowLANEnabled)
                Text("Other devices can use this Mac as HTTP/SOCKS.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if appModel.allowLANEnabled {
                    ContentUnavailableView {
                        Label("No Devices", systemImage: "laptopcomputer.and.iphone")
                    } description: {
                        Text("LAN clients appear once they send traffic through this Mac.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("LAN Off", systemImage: "laptopcomputer.and.iphone")
                    } description: {
                        Text("Turn on Allow LAN to proxy other devices on this network.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("LAN")
    }
}

struct RulesPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var search = ""
    @State private var selectedRuleID: String?
    @State private var editor: OverlayRule?

    var body: some View {
        let rows = displayRules
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Rules", systemImage: SidebarItem.rules.systemImage)
                } description: {
                    Text(
                        search.isEmpty
                            ? (appModel.dashboard.profiles.lastError
                                ?? "Import a profile, then press Set Active in Profiles.")
                            : "No rules match this filter."
                    )
                }
            } else {
                Table(rows, selection: $selectedRuleID) {
                    TableColumn("#") { (row: DisplayRule) in
                        Text("\(row.number)")
                            .foregroundStyle(.secondary)
                    }
                    .width(40)
                    TableColumn("Type") { row in
                        Text(row.type)
                    }
                    .width(140)
                    TableColumn("Payload") { row in
                        Text(row.payload)
                            .font(.body.monospaced())
                    }
                    TableColumn("Policy") { row in
                        Text(row.policy)
                    }
                    .width(120)
                    TableColumn("Source") { row in
                        Text(row.isLocal ? "Local" : "Profile")
                            .foregroundStyle(row.isLocal ? .primary : .secondary)
                    }
                    .width(80)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                        Button("Copy") { copyRule(row) }
                        if row.isLocal {
                            Button("Edit…") { editor = overlayRule(id: row.overlayID) }
                            Button("Delete", role: .destructive) { deleteLocal(id: row.overlayID) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add Rule", systemImage: "plus") {
                    editor = OverlayRule(type: .domainSuffix, payload: "", policy: "DIRECT")
                }
                .disabled(appModel.dashboard.profiles.activeProfile == nil)
                .help("Add a local rule in front of the profile rules.")
                Button("Delete", systemImage: "minus") {
                    deleteSelected()
                }
                .disabled(selectedLocalID == nil)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $search, prompt: "Search rules")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                InspectorToolbarButton()
            }
        }
        .sheet(item: $editor) { rule in
            OverlayRuleEditor(
                title: overlay.rules.contains(where: { $0.id == rule.id }) ? "Edit Rule" : "Add Rule",
                policies: policyNames,
                initial: rule
            ) { saved in
                upsertLocal(saved)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(overlay.rules.count) local · \(rows.count) total")
                    .foregroundStyle(.secondary)
                Spacer()
                if let name = appModel.dashboard.profiles.activeProfileName {
                    Text(name)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var overlay: ProfileOverlay { appModel.dashboard.profiles.overlay }

    private var selectedLocalID: UUID? {
        displayRules.first { $0.id == selectedRuleID }?.overlayID
    }

    private var policyNames: [String] {
        var names = ["DIRECT", "REJECT"]
        names.append(contentsOf: appModel.nodeList.policyGroupSections.map(\.id))
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private var displayRules: [DisplayRule] {
        let localIDs = overlay.rules.map(\.id)
        let rules = appModel.dashboard.profiles.rules.enumerated().map { index, rule in
            let isLocal = index < localIDs.count
            return DisplayRule(
                id: isLocal ? localIDs[index].uuidString : "profile-\(index)",
                number: index + 1,
                type: rule.displayType,
                payload: rule.displayPayload,
                policy: rule.displayPolicy,
                isLocal: isLocal,
                overlayID: isLocal ? localIDs[index] : nil
            )
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rules }
        return rules.filter { row in
            row.type.localizedCaseInsensitiveContains(query)
                || row.payload.localizedCaseInsensitiveContains(query)
                || row.policy.localizedCaseInsensitiveContains(query)
        }
    }

    private func overlayRule(id: UUID?) -> OverlayRule? {
        guard let id else { return nil }
        return overlay.rules.first { $0.id == id }
    }

    private func upsertLocal(_ rule: OverlayRule) {
        var next = overlay
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) {
            next.rules[index] = rule
        } else {
            next.rules.append(rule)
        }
        appModel.saveOverlay(next)
    }

    private func deleteSelected() {
        deleteLocal(id: selectedLocalID)
    }

    private func deleteLocal(id: UUID?) {
        guard let id else { return }
        var next = overlay
        next.rules.removeAll { $0.id == id }
        appModel.saveOverlay(next)
        selectedRuleID = nil
    }

    private func copyRule(_ row: DisplayRule) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "\(row.type),\(row.payload),\(row.policy)",
            forType: .string
        )
    }
}

private struct DisplayRule: Identifiable {
    var id: String
    var number: Int
    var type: String
    var payload: String
    var policy: String
    var isLocal: Bool
    var overlayID: UUID?
}

struct ComingSoonPane: View {
    var title: String
    var systemImage: String
    var summary: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(summary)
        }
        .navigationTitle(title)
    }
}

struct MorePane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        moreGrid
            .navigationTitle("More")
    }

    private var moreGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 28) {
                    GridRow {
                        LaunchTile(
                            title: "Settings",
                            subtitle: "Appearance, capture, and shortcuts.",
                            systemImage: "slider.horizontal.3",
                            tint: .indigo
                        ) {
                            appModel.presentedMoreSheet = .settings
                        }
                        LaunchTile(
                            title: "Profiles",
                            subtitle: "Subscriptions and local configs.",
                            systemImage: "doc.text.fill",
                            tint: .blue
                        ) {
                            appModel.presentedMoreSheet = .profiles
                        }
                        LaunchTile(
                            title: "Events",
                            subtitle: "Tunnel runtime log.",
                            systemImage: "terminal.fill",
                            tint: .teal
                        ) {
                            appModel.presentedMoreSheet = .events
                        }
                        LaunchTile(
                            title: "Module",
                            subtitle: "Overlay snippets on the active profile.",
                            systemImage: "shippingbox.fill",
                            tint: .orange,
                            enabled: false
                        )
                    }
                }
                Divider()
                Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 28) {
                    GridRow {
                        LaunchTile(
                            title: "Scripts",
                            subtitle: "Extend routing with JavaScript.",
                            systemImage: "flask.fill",
                            tint: .pink,
                            enabled: false
                        )
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .leading)
        }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.headline)
                Text("Appearance, capture, and shortcuts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            SettingsForm()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetActionBar(onDone: { dismiss() })
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

struct SettingsPane: View {
    var body: some View {
        SettingsForm()
            .navigationTitle("Settings")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SettingsForm: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("Appearance") {
                Toggle("Menu Bar Only", isOn: $appModel.menuBarOnly)
                    .help("Hide the Dock icon and keep PrizmX in the menu bar.")
                Text(
                    "When enabled, PrizmX uses an accessory activation policy so it no longer occupies the Dock. Open the console from the menu-bar panel."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Connected Icon", selection: $appModel.menuBarConnectedStyle) {
                    ForEach(MenuBarConnectedStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .help("Idle stays gray. Capture always uses amber. This only changes the connected proxy icon.")
            }

            Section("Capture") {
                Toggle("System Proxy", isOn: $appModel.systemProxyEnabled)
                Toggle("TUN Mode", isOn: $appModel.tunModeEnabled)
                Toggle("Allow LAN", isOn: $appModel.allowLANEnabled)
                Toggle("HTTP Capture", isOn: $appModel.httpCaptureEnabled)
                    .help("Menu bar uses the capture tint when the proxy is also on. Tunnel wiring comes later.")
                Text(
                    "TUN captures domain traffic via FakeIP (198.18/16); DIRECT is spliced "
                        + "to the real IP in userspace. System Proxy listens on mixed-port \(TunnelProviderKeys.defaultMixedPort) "
                        + "(HTTP CONNECT and SOCKS5) and sets the macOS HTTP/HTTPS proxy. "
                        + "Allow LAN binds that port on all interfaces."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                labeledShortcut("Select node", "⌘K")
                labeledShortcut("Toggle VPN", "⌘.")
                labeledShortcut("Inspector", "⌘I")
                labeledShortcut("Main console", "⌘0")
                labeledShortcut("Settings", "⌘,")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "app.prizmx.macos")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func labeledShortcut(_ name: String, _ keys: String) -> some View {
        LabeledContent(name) {
            Text(keys)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Settings") {
    SettingsPane()
        .environment(AppModel.preview)
        .frame(width: 520, height: 480)
}
