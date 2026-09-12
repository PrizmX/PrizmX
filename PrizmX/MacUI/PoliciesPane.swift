import AppKit
import SwiftUI
import PrizmXConfig
import PrizmXNodes
import PrizmXServices
import PrizmXUIEngine

/// Policy groups from the active profile, with member nodes on the right.
struct PoliciesPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedGroupID: String?
    @State private var selectedNodeID: String?
    @State private var editor: OverlayGroup?

    var body: some View {
        @Bindable var nodeList = appModel.nodeList
        // Touch nodeManager so Observation re-renders when a profile rebuilds it.
        // (`let _ =`, not `_ =`: ViewBuilder treats bare assignments as views.)
        let _ = appModel.dashboard.profiles.nodeManager
        let groups = nodeList.policyGroupSections

        Group {
            if groups.isEmpty {
                ConsoleEmptyState(
                    title: "No Policies",
                    systemImage: SidebarItem.policies.systemImage,
                    description: appModel.dashboard.profiles.lastError
                        ?? "Import a profile, then set it active in Profiles."
                )
            } else {
                HSplitView {
                    groupList(groups)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    memberTable(groups)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationTitle("Policies")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IconControlGroup {
                    Button("Add Group", systemImage: "plus") {
                        editor = OverlayGroup(name: "Local", members: ["DIRECT"])
                    }
                    .disabled(appModel.dashboard.profiles.activeProfile == nil)
                    .help("Add a local policy group. Remote groups stay read-only.")
                    Button("Delete", systemImage: "minus") {
                        deleteSelectedLocalGroup()
                    }
                    .disabled(selectedLocalGroup == nil)
                    .help("Delete")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Ping All", systemImage: "gauge.with.dots.needle.67percent") {
                    guard !nodeList.isPinging else { return }
                    Task { await nodeList.pingAllNodes() }
                }
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(
                    .variableColor.iterative.dimInactiveLayers,
                    options: .repeating.speed(0.8),
                    isActive: nodeList.isPinging
                )
                .help(nodeList.isPinging ? "Testing delay…" : "Concurrent delay test")
                .allowsHitTesting(!nodeList.isPinging)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $nodeList.searchText, prompt: "Filter nodes")
            }
            ConsoleInspectorToolbar()
        }
        .sheet(item: $editor) { group in
            OverlayGroupEditor(
                title: overlay.groups.contains(where: { $0.id == group.id }) ? "Edit Group" : "Add Group",
                memberChoices: memberChoices,
                initial: group
            ) { saved in
                upsertLocal(saved)
            }
        }
        .onAppear {
            nodeList.grouping = .policy
            if selectedGroupID == nil {
                selectedGroupID = groups.first?.id
            }
        }
        .onChange(of: appModel.dashboard.profiles.activeProfileID) { _, _ in
            selectedGroupID = appModel.nodeList.policyGroupSections.first?.id
        }
    }

    private func groupList(_ groups: [PolicyGroupSection]) -> some View {
        Table(groups, selection: $selectedGroupID) {
            TableColumn("Group") { (group: PolicyGroupSection) in
                HStack(alignment: .center, spacing: 8) {
                    PolicyGroupIcon(
                        url: appModel.dashboard.profiles.nodeManager?.group(named: group.id)?.iconURL
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.title)
                            if isLocal(group.id) {
                                Text("Local")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(groupSubtitle(group))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let local = overlay.groups.first(where: { $0.name == id }) {
                Button("Edit…") { editor = local }
                Button("Delete", role: .destructive) { deleteLocal(local.id) }
            }
        }
    }

    private func memberTable(_ groups: [PolicyGroupSection]) -> some View {
        let members = filteredMembers(groups.first { $0.id == selectedGroupID }?.members ?? [])
        return Group {
            if members.isEmpty {
                ContentUnavailableView {
                    Label("No Members", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(
                        appModel.nodeList.searchText.isEmpty
                            ? "Select a policy group."
                            : "No members match this filter."
                    )
                }
            } else {
                Table(members, selection: $selectedNodeID) {
                    TableColumn("Member") { (member: PolicyMember) in
                        HStack {
                            if member.id == selectedID(in: selectedGroupID) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .frame(width: 14)
                            } else {
                                Color.clear.frame(width: 14)
                            }
                            Text(member.name)
                        }
                    }
                    TableColumn("Type") { member in
                        Text(member.kindLabel)
                            .foregroundStyle(member.isUnsupported ? Color.orange : Color.primary)
                    }
                    .width(110)
                    TableColumn("Latency") { member in
                        if let node = member.node, appModel.nodeList.hasPingResult(for: node) {
                            let ms = appModel.nodeList.latency(for: node)
                            Text(LatencyFormat.label(ms))
                                .foregroundStyle(LatencyFormat.color(ms))
                                .monospacedDigit()
                        } else if member.node != nil, appModel.nodeList.isPinging {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .width(90)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let member = members.first(where: { $0.id == id }) {
                        Button("Select") { selectMember(member) }
                            .disabled(member.isUnsupported)
                        if let node = member.node {
                            Button("Ping") { Task { await appModel.nodeList.ping(node) } }
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first,
                       let member = members.first(where: { $0.id == id }),
                       !member.isUnsupported {
                        selectMember(member)
                    }
                }
            }
        }
    }

    private func filteredMembers(_ members: [PolicyMember]) -> [PolicyMember] {
        let query = appModel.nodeList.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return members }
        return members.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func selectedID(in groupID: String?) -> String? {
        guard let groupID else { return nil }
        return appModel.nodeList.selectedMemberID(inGroup: groupID)
    }

    private func selectMember(_ member: PolicyMember) {
        guard !member.isUnsupported, let groupID = selectedGroupID else { return }
        appModel.selectPolicyMember(member.id, inGroup: groupID)
    }

    private var overlay: ProfileOverlay { appModel.dashboard.profiles.overlay }

    private var selectedLocalGroup: OverlayGroup? {
        overlay.groups.first { $0.name == selectedGroupID }
    }

    private func isLocal(_ name: String) -> Bool {
        overlay.groups.contains { $0.name == name }
    }

    private var memberChoices: [String] {
        var names = ["DIRECT", "REJECT"]
        if let manager = appModel.dashboard.profiles.nodeManager {
            names.append(contentsOf: manager.nodesByID.keys.sorted())
            names.append(
                contentsOf: manager.groupsByName.keys.sorted().filter { name in
                    !(manager.group(named: name)?.nodeIDs == [name])
                }
            )
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func upsertLocal(_ group: OverlayGroup) {
        var next = overlay
        if let index = next.groups.firstIndex(where: { $0.id == group.id }) {
            next.groups[index] = group
        } else {
            next.groups.append(group)
        }
        appModel.saveOverlay(next)
        selectedGroupID = group.name
    }

    private func deleteSelectedLocalGroup() {
        guard let id = selectedLocalGroup?.id else { return }
        deleteLocal(id)
    }

    private func deleteLocal(_ id: UUID) {
        var next = overlay
        next.groups.removeAll { $0.id == id }
        appModel.saveOverlay(next)
        selectedGroupID = nil
    }

    private func groupSubtitle(_ group: PolicyGroupSection) -> String {
        let count = "\(group.members.count) members"
        if let mode = appModel.dashboard.profiles.nodeManager?.group(named: group.id)?.mode {
            return "\(mode.displayName) · \(count)"
        }
        return count
    }
}

private struct PolicyGroupIcon: View {
    var url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: SidebarItem.policies.systemImage)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: SidebarItem.policies.systemImage)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}

#Preview("Policies") {
    PoliciesPane()
        .environment(AppModel.preview)
        .frame(width: 720, height: 480)
}
