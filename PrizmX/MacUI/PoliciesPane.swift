import AppKit
import SwiftUI
import PrizmXNodes
import PrizmXUIEngine

/// Policy groups from the active profile, with member nodes on the right.
struct PoliciesPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedGroupID: String?
    @State private var selectedNodeID: String?

    var body: some View {
        @Bindable var nodeList = appModel.nodeList
        // Touch nodeManager so Observation re-renders when a profile rebuilds it.
        // (`let _ =`, not `_ =`: ViewBuilder treats bare assignments as views.)
        let _ = appModel.dashboard.profiles.nodeManager
        let groups = nodeList.policyGroupSections

        HSplitView {
            groupList(groups)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            memberTable(groups)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Policies")
        .searchable(text: $nodeList.searchText, prompt: "Filter nodes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if nodeList.isPinging {
                    Button("Stop") { nodeList.cancelPing() }
                } else {
                    Button("Ping All", systemImage: "gauge.with.dots.needle.67percent") {
                        Task { await nodeList.pingAllNodes() }
                    }
                    .help("Concurrent delay test")
                }
            }
        }
        .onAppear {
            nodeList.grouping = .policy
            if selectedGroupID == nil {
                selectedGroupID = groups.first?.id
            }
        }
        .onChange(of: appModel.dashboard.profiles.activeProfileID) { _, _ in
            selectedGroupID = appModel.nodeList.sections.first?.id
        }
    }

    private func groupList(_ groups: [PolicyGroupSection]) -> some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No Policies", systemImage: SidebarItem.policies.systemImage)
                } description: {
                    Text(appModel.dashboard.profiles.lastError
                         ?? "Import a profile, then press Set Active in Profiles.")
                }
            } else {
                List(groups, selection: $selectedGroupID) { group in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                            Text(groupSubtitle(group))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        PolicyGroupIcon(url: appModel.dashboard.profiles.nodeManager?.group(named: group.id)?.iconURL)
                    }
                    .tag(group.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
                    }
                    .width(90)
                    TableColumn("Latency") { member in
                        if let node = member.node, appModel.nodeList.hasPingResult(for: node) {
                            Text(latencyLabel(appModel.nodeList.latency(for: node)))
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
                        if let node = member.node {
                            Button("Ping") { Task { await appModel.nodeList.ping(node) } }
                        }
                    }
                }
                .onChange(of: selectedNodeID) { _, newValue in
                    guard let newValue, let member = members.first(where: { $0.id == newValue }) else { return }
                    selectMember(member)
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
        guard let groupID = selectedGroupID else { return }
        // Persists PolicySelectionStore, updates the in-app NodeManager, and
        // notifies the running tunnel over IPC.
        appModel.dashboard.selectPolicyMember(member.id, inGroup: groupID)
    }

    private func groupSubtitle(_ group: PolicyGroupSection) -> String {
        let count = "\(group.members.count) members"
        if let mode = appModel.dashboard.profiles.nodeManager?.group(named: group.id)?.mode {
            return "\(mode.displayName) · \(count)"
        }
        return count
    }

    private func latencyLabel(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds >= 0, milliseconds <= 2_000 else {
            return "Timeout"
        }
        return "\(Int(milliseconds.rounded())) ms"
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
