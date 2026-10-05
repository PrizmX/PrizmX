import AppKit
import SwiftUI
import PrizmXProtocols
import PrizmXServices
import PrizmXUIEngine

struct RulesPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var search = ""
    @State private var selectedRuleID: RuleRow.ID?
    @State private var editor: OverlayRule?
    /// Not observed: a cache read in `body`, refreshed when its inputs change.
    @State private var rowBuilder = RuleRowBuilder()

    var body: some View {
        let rows = rowBuilder.rows(
            rules: appModel.dashboard.profiles.rules,
            localIDs: overlay.rules.map(\.id),
            search: search
        )
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
                NativeTable(rows: rows, columns: Self.columns, selection: $selectedRuleID) { row in
                    var items = [NativeTableMenuItem("Copy") { copyRule(row) }]
                    if let id = row.overlayID {
                        items.append(NativeTableMenuItem("Edit…") { editor = overlayRule(id: id) })
                        items.append(NativeTableMenuItem("Delete") { deleteLocal(id: id) })
                    }
                    return items
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

    private static let columns: [NativeTableColumn<RuleRow>] = [
        .init("number", "#", width: 40, color: { _ in .secondaryLabelColor }) { "\($0.number)" },
        .init("type", "Type", width: 140) { $0.type },
        .init("payload", "Payload", width: 320, minWidth: 120, flexible: true, font: NativeTableFont.mono) { $0.payload },
        .init("policy", "Policy", width: 120) { $0.policy },
        .init("source", "Source", width: 80, color: { $0.isLocal ? .labelColor : .secondaryLabelColor }) {
            $0.isLocal ? "Local" : "Profile"
        },
    ]

    private var overlay: ProfileOverlay { appModel.dashboard.profiles.overlay }

    private var selectedLocalID: UUID? {
        if case .local(let id) = selectedRuleID { id } else { nil }
    }

    private var policyNames: [String] {
        var names = ["DIRECT", "REJECT"]
        names.append(contentsOf: appModel.nodeList.policyGroupSections.map(\.id))
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
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

    private func copyRule(_ row: RuleRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "\(row.type),\(row.payload),\(row.policy)",
            forType: .string
        )
    }
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

            Section("DNS") {
                Toggle(isOn: $appModel.overrideDNSEnabled) {
                    Text("Override DNS")
                    Text("Also resolve proxy servers with public and system DNS, and prefer addresses that worked before, instead of the profile's DNS alone. Leave off unless your provider asks for it.")
                }
                LabeledContent {
                    Button("Clear") { appModel.clearDNSCache() }
                } label: {
                    Text("DNS Cache")
                    Text("Forget cached DNS answers and reconnect. Refreshing the active subscription does this too.")
                }
            }

            Section("Appearance") {
                Picker("Connected Icon", selection: $appModel.menuBarConnectedStyle) {
                    ForEach(MenuBarConnectedStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .help("Off is a dimmed outline and System Proxy a full outline. TUN fills the core; this only changes its color.")

                Toggle(isOn: $appModel.menuBarSpeedEnabled) {
                    Text("Show Network Speed")
                    Text("Upload and download rates beside the menu bar icon while proxying.")
                }
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

            Section("Privacy") {
                Toggle(isOn: $appModel.analyticsEnabled) {
                    Text("Share Anonymous Usage Data")
                    Text("App launches, versions, and whether TUN or System Proxy is on. No profiles, nodes or traffic.")
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
