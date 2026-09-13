import AppKit
import SwiftUI
import PrizmXProtocols
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
                        Label("No Devices", systemImage: SidebarItem.lan.systemImage)
                    } description: {
                        Text("LAN clients appear once they send traffic through this Mac.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("LAN Off", systemImage: SidebarItem.lan.systemImage)
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
                ConsoleEmptyState(
                    title: "No Rules",
                    systemImage: SidebarItem.rules.systemImage,
                    description: search.isEmpty
                        ? (appModel.dashboard.profiles.lastError
                            ?? "Import a profile, then set it active in Profiles.")
                        : "No rules match this filter."
                )
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
        .navigationTitle("Rules \(rows.count)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IconControlGroup {
                    Button("Add Rule", systemImage: "plus") {
                        editor = OverlayRule(type: .domainSuffix, payload: "", policy: "DIRECT")
                    }
                    .disabled(appModel.dashboard.profiles.activeProfile == nil)
                    .help("Add a local rule in front of the profile rules.")
                    Button("Delete", systemImage: "minus") {
                        deleteSelected()
                    }
                    .disabled(selectedLocalID == nil)
                    .help("Delete")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $search, prompt: "Search rules")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(item: $editor) { rule in
            OverlayRuleEditor(
                title: overlay.rules.contains(where: { $0.id == rule.id }) ? "Edit Rule" : "Add Rule",
                policies: policyNames,
                initial: rule
            ) { saved in
                upsertLocal(saved)
            }
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
    var item: SidebarItem

    var body: some View {
        ConsoleEmptyState(
            title: item.title,
            systemImage: item.systemImage,
            description: item.placeholderSummary ?? "This page is not available yet."
        )
        .navigationTitle(item.title)
    }
}

struct SettingsPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("General") {
                LaunchAtLoginToggle()
                Toggle(isOn: $appModel.menuBarOnly) {
                    Text("Menu Bar Only")
                    Text("Hide the Dock icon and keep PrizmX in the menu bar.")
                }
            }

            Section("Appearance") {
                Picker("Connected Icon", selection: $appModel.menuBarConnectedStyle) {
                    ForEach(MenuBarConnectedStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .help("Idle stays gray. This only changes the connected proxy icon.")
            }

            Section("Events") {
                Picker(selection: $appModel.eventsLogLevel) {
                    ForEach(TunnelLog.Level.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                } label: {
                    Text("Log Level")
                    Text("Records this level and above. Clear Events to drop older lines.")
                }
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
        .navigationTitle("Settings")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func labeledShortcut(_ name: String, _ keys: String) -> some View {
        LabeledContent(name) {
            Text(keys)
                .foregroundStyle(.secondary)
        }
    }
}

extension TunnelLog.Level {
    var title: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warn: "Warning"
        case .error: "Error"
        }
    }
}

#Preview("Settings") {
    SettingsPane()
        .environment(AppModel.preview)
        .frame(width: 520, height: 480)
}
