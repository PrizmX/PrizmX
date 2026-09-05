import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PrizmXServices
import PrizmXUIEngine

/// Rounded card: table header + rows + plus/minus bar, like Login Items.
private struct LoginItemsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            )
    }
}

/// System Settings “Login Items” style: grouped Form + inset table + plus/minus bar.
struct ProfilesSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?
    @State private var lastSelectedID: UUID?
    @State private var renameText = ""
    @State private var isRenamePresented = false
    @State private var isNewPresented = false
    @State private var isURLPresented = false
    @State private var isDeletePresented = false
    @State private var newName = "New Profile"
    @State private var urlName = ""
    @State private var urlString = ""
    @State private var isImportingURL = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Profiles")
                    .font(.headline)
                Text("These configs are used when PrizmX connects.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LoginItemsCard {
                VStack(spacing: 0) {
                    Table(store.profiles, selection: $selectedID) {
                        TableColumn("Item") { (profile: ProxyProfile) in
                            Label {
                                Text(profile.name)
                            } icon: {
                                Image(
                                    systemName: profile.subscriptionURL == nil
                                        ? "doc.fill" : "link.circle.fill"
                                )
                                .symbolRenderingMode(.hierarchical)
                            }
                        }
                        TableColumn("Kind") { profile in
                            Text(kind(for: profile))
                        }
                        .width(140)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                    .id(store.activeProfileID)
                    .frame(minHeight: 200, maxHeight: 280)
                    .clipped()
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let id = ids.first {
                            Button("Set Active") { apply(id) }
                            Button("Rename…") { beginRename(id) }
                            Button("Show in Finder") { revealInFinder(id) }
                            Button("Export…") { export(id) }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                selectedID = id
                                isDeletePresented = true
                            }
                        }
                    }

                    plusMinusBar
                }
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetActionBar(onDone: applyAndDismiss) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.directoryURL])
                }
                .buttonStyle(.bordered)
                Button("Set Active") {
                    if let selectedID {
                        apply(selectedID)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(selectedID == nil || selectedID == store.activeProfileID)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            selectedID = appModel.dashboard.profiles.activeProfileID
            lastSelectedID = selectedID
        }
        .onChange(of: selectedID) { _, newValue in
            if let newValue { lastSelectedID = newValue }
        }
        .alert("Rename Profile", isPresented: $isRenamePresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renameSelected() }
        }
        .alert("New Profile", isPresented: $isNewPresented) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createProfile() }
        }
        .alert("Delete Profile", isPresented: $isDeletePresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("This removes the profile from PrizmX. The action cannot be undone.")
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isURLPresented) {
            urlSheet
        }
    }

    private var store: ProfileStore { appModel.dashboard.profiles }

    private var selectedProfile: ProxyProfile? {
        store.profiles.first { $0.id == selectedID }
    }

    /// Table can clear selection when the minus button is clicked; keep the last row.
    private var actionProfileID: UUID? { selectedID ?? lastSelectedID }

    private var plusMinusBar: some View {
        HStack(spacing: 0) {
            Menu {
                Button("New…") {
                    newName = "New Profile"
                    isNewPresented = true
                }
                Button("Import…") { importFromFile() }
                Button("From URL…") {
                    urlName = ""
                    urlString = ""
                    isURLPresented = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 24)
            }
            .menuIndicator(.hidden)
            .help("Add")

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 14)

            Button(action: removeSelected) {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(actionProfileID == nil)
            .help("Remove")

            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var urlSheet: some View {
        Form {
            Section {
                TextField("Name", text: $urlName)
                TextField("Subscription URL", text: $urlString)
                    .textContentType(.URL)
            } header: {
                Text("Install from URL")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 180)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetActionBar(
                doneTitle: "Install",
                doneEnabled: !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isImportingURL,
                onDone: { Task { await importFromURL() } }
            ) {
                Button("Cancel") { isURLPresented = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func kind(for profile: ProxyProfile) -> String {
        if profile.id == store.activeProfileID {
            return "Active"
        }
        switch profile.format {
        case .clash: return "Clash"
        case .singbox: return "sing-box"
        case .unknown: return profile.subscriptionURL == nil ? "Local" : "Subscription"
        }
    }

    private func applyAndDismiss() {
        if let selectedID {
            apply(selectedID)
        }
        dismiss()
    }

    private func apply(_ id: UUID) {
        do {
            try store.selectActiveProfile(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginRename(_ id: UUID) {
        selectedID = id
        renameText = store.profiles.first { $0.id == id }?.name ?? ""
        isRenamePresented = true
    }

    private func renameSelected() {
        guard let selectedID else { return }
        do {
            try store.rename(id: selectedID, to: renameText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createProfile() {
        let profile = ProxyProfile(name: newName, rawConfig: Self.emptyClashConfig)
        do {
            try store.upsert(profile)
            selectedID = profile.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeSelected() {
        guard let id = actionProfileID else { return }
        selectedID = id
        isDeletePresented = true
    }

    private func revealInFinder(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: id)])
    }

    private func deleteSelected() {
        guard let selectedID = actionProfileID else { return }
        do {
            try store.remove(id: selectedID)
            self.selectedID = store.activeProfileID
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.configTypes
        panel.title = "Import Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent
            let profile = ProxyProfile(name: name, rawConfig: text)
            try store.upsert(profile)
            selectedID = profile.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(_ id: UUID) {
        guard let profile = store.profiles.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export Profile"
        panel.nameFieldStringValue = "\(profile.name).yaml"
        panel.allowedContentTypes = [.yaml, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profile.rawConfig.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFromURL() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorMessage = "Enter a valid URL."
            return
        }
        isImportingURL = true
        defer { isImportingURL = false }
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("PrizmX/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let text = ProfileStore.decodeSubscriptionBody(data), !text.isEmpty else {
                errorMessage = "The download did not contain a readable profile."
                return
            }
            let name = urlName.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = ProxyProfile(
                name: name.isEmpty ? (url.host ?? "Subscription") : name,
                subscriptionURL: url,
                lastUpdated: Date(),
                rawConfig: text
            )
            try store.upsert(profile)
            selectedID = profile.id
            isURLPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let emptyClashConfig = """
    proxies: []
    proxy-groups: []
    rules:
      - MATCH,DIRECT
    """

    private static var configTypes: [UTType] {
        var types: [UTType] = [.yaml, .json, .plainText]
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        if let conf = UTType(filenameExtension: "conf") { types.append(conf) }
        return types
    }
}

#Preview("Profiles") {
    ProfilesSheet()
        .environment(AppModel.preview)
}
