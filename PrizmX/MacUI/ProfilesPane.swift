import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PrizmXConfig
import PrizmXServices
import PrizmXUIEngine

/// Full-bleed profile table, matching Rules / Policies.
struct ProfilesPane: View {
    @Environment(AppModel.self) private var appModel

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
    @State private var urlImportError: String?
    /// Entries the importer skipped, shown after an import and from the
    /// toolbar while the active profile has any.
    @State private var presentedWarnings: [ConfigWarning]?
    /// Warnings of a URL install, shown once its sheet is gone (two sheets
    /// cannot swap in one update).
    @State private var pendingWarnings: [ConfigWarning]?

    var body: some View {
        Group {
            if store.profiles.isEmpty {
                ConsoleEmptyState(
                    title: "No Profiles",
                    systemImage: SidebarItem.profiles.systemImage,
                    description: store.lastError ?? "Create, import, or install a subscription."
                )
            } else {
                profileTable
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IconControlGroup {
                    Menu {
                        Button("New…") {
                            newName = "New Profile"
                            isNewPresented = true
                        }
                        Button("Import…") { importFromFile() }
                        Button("From URL…") {
                            urlName = ""
                            urlString = ""
                            urlImportError = nil
                            isURLPresented = true
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuIndicator(.hidden)
                    .help("Add")
                    Button("Delete", systemImage: "minus") {
                        removeSelected()
                    }
                    .disabled(selectedID == nil)
                    .help("Remove")
                }
            }
            if !store.warnings.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Import Warnings", systemImage: "exclamationmark.triangle") {
                        presentedWarnings = store.warnings
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .help("\(store.warnings.count) entries of the active profile were not imported")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.directoryURL])
                }
                .labelStyle(.iconOnly)
                .help("Show in Finder")
            }
        }
        .onAppear {
            selectedID = appModel.dashboard.profiles.activeProfileID
            lastSelectedID = selectedID
        }
        .onChange(of: selectedID) { _, newValue in
            if let newValue { lastSelectedID = newValue }
        }
        .sheet(isPresented: $isRenamePresented) {
            ProfileNameSheet(
                title: "Rename Profile",
                doneTitle: "Rename",
                name: $renameText,
                onCancel: { isRenamePresented = false },
                onDone: renameSelected
            )
        }
        .sheet(isPresented: $isNewPresented) {
            ProfileNameSheet(
                title: "New Profile",
                doneTitle: "Create",
                name: $newName,
                onCancel: { isNewPresented = false },
                onDone: createProfile
            )
        }
        .sheet(isPresented: $isDeletePresented) {
            ConfirmSheet(
                title: "Delete Profile",
                message: "This removes the profile from PrizmX. The action cannot be undone.",
                doneTitle: "Delete",
                onCancel: { isDeletePresented = false },
                onDone: {
                    isDeletePresented = false
                    deleteSelected()
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            ConfirmSheet(
                title: "Error",
                message: errorMessage ?? "",
                showsCancel: false,
                onDone: { errorMessage = nil }
            )
        }
        .sheet(isPresented: Binding(
            get: { presentedWarnings != nil },
            set: { if !$0 { presentedWarnings = nil } }
        )) {
            ImportWarningsSheet(warnings: presentedWarnings ?? []) {
                presentedWarnings = nil
            }
        }
        .sheet(isPresented: $isURLPresented, onDismiss: {
            urlImportError = nil
            if let pendingWarnings {
                presentedWarnings = pendingWarnings
                self.pendingWarnings = nil
            }
        }) {
            InstallFromURLSheet(
                name: $urlName,
                urlString: $urlString,
                isImporting: isImportingURL,
                errorMessage: urlImportError,
                onCancel: { isURLPresented = false },
                onInstall: { Task { await importFromURL() } }
            )
        }
    }

    private var store: ProfileStore { appModel.dashboard.profiles }

    /// Minus is enabled from `selectedID`. `lastSelectedID` covers the case
    /// where the table clears selection as the toolbar button is pressed.
    private var actionProfileID: UUID? { selectedID ?? lastSelectedID }

    private var profileTable: some View {
        Table(store.profiles, selection: $selectedID) {
            TableColumn("Item") { (profile: ProxyProfile) in
                let isActive = profile.id == store.activeProfileID
                Label {
                    Text(profile.name)
                        .fontWeight(isActive ? .semibold : .regular)
                } icon: {
                    Image(systemName: profile.isSubscription ? "link.circle" : "doc.text")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
            }
            TableColumn("Kind") { profile in
                let isActive = profile.id == store.activeProfileID
                Text(ProfileListFormat.kind(profile, activeID: store.activeProfileID))
                    .fontWeight(isActive ? .semibold : .regular)
            }
            .width(150)
            TableColumn("Updated") { profile in
                Text(ProfileListFormat.updated(profile))
                    .foregroundStyle(profile.lastUpdated == nil ? .tertiary : .primary)
            }
            .width(100)
            TableColumn("Expires") { profile in
                Text(ProfileListFormat.expires(profile))
                    .foregroundStyle(ProfileListFormat.expiresStyle(profile))
            }
            .width(110)
            TableColumn("Usage") { profile in
                Text(ProfileListFormat.usage(profile))
                    .foregroundStyle(profile.usedBytes == nil ? .tertiary : .primary)
                    .monospacedDigit()
            }
            .width(140)
        }
        .tableStyle(.inset)
        .id(store.activeProfileID)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Button("Set Active") { apply(id) }
                    .disabled(id == store.activeProfileID)
                Button("Rename…") { beginRename(id) }
                Button("Show in Finder") { revealInFinder(id) }
                Button("Export…") { export(id) }
                Divider()
                Button("Delete…", role: .destructive) {
                    selectedID = id
                    isDeletePresented = true
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, id != store.activeProfileID {
                apply(id)
            }
        }
    }

    private func apply(_ id: UUID) {
        do {
            try store.selectActiveProfile(id: id)
            appModel.didChangeActiveProfile()
            errorMessage = nil
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
            isRenamePresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createProfile() {
        let profile = ProxyProfile(name: newName, rawConfig: ProfileFileIO.emptyClashConfig)
        do {
            try store.upsert(profile)
            selectedID = profile.id
            isNewPresented = false
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
        let previousActive = store.activeProfileID
        do {
            try store.remove(id: selectedID)
            self.selectedID = store.activeProfileID
            if store.activeProfileID != previousActive {
                appModel.didChangeActiveProfile()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFromFile() {
        do {
            if let result = try ProfileFileIO.importFromOpenPanel(into: store) {
                selectedID = result.id
                if !result.warnings.isEmpty { presentedWarnings = result.warnings }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(_ id: UUID) {
        guard let profile = store.profiles.first(where: { $0.id == id }) else { return }
        do {
            try ProfileFileIO.export(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFromURL() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            urlImportError = "Enter a valid URL."
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            urlImportError = "Enter an http or https URL."
            return
        }
        isImportingURL = true
        defer { isImportingURL = false }
        do {
            let warnings = try await store.installSubscription(from: url, name: urlName)
            selectedID = store.profiles.last?.id
            urlImportError = nil
            if !warnings.isEmpty { pendingWarnings = warnings }
            isURLPresented = false
        } catch {
            urlImportError = error.localizedDescription
        }
    }
}

private enum ProfileListFormat {
    static func kind(_ profile: ProxyProfile, activeID: UUID?) -> String {
        let label: String
        switch profile.format {
        case .clash: label = "Clash"
        case .singbox: label = "sing-box"
        case .unknown: label = profile.isSubscription ? "Subscription" : "Local"
        }
        if profile.id == activeID { return "\(label) (Active)" }
        return label
    }

    static func updated(_ profile: ProxyProfile) -> String {
        guard let date = profile.lastUpdated else { return "—" }
        return relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    static func expires(_ profile: ProxyProfile) -> String {
        guard let date = profile.expiresAt else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func expiresStyle(_ profile: ProxyProfile) -> AnyShapeStyle {
        guard let date = profile.expiresAt else { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(date < .now ? Color.orange : Color.primary)
    }

    static func usage(_ profile: ProxyProfile) -> String {
        guard let used = profile.usedBytes else { return "—" }
        let usedText = ByteRateFormatter.byteCount(used)
        if let total = profile.totalBytes, total > 0 {
            return "\(usedText) / \(ByteRateFormatter.byteCount(total))"
        }
        return usedText
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

enum ProfileFileIO {
    static let emptyClashConfig = """
    proxies: []
    proxy-groups: []
    rules:
      - MATCH,DIRECT
    """

    static func importFromOpenPanel(into store: ProfileStore) throws -> (id: UUID, warnings: [ConfigWarning])? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = configTypes
        panel.title = "Import Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try store.importProfile(text: text, name: url.deletingPathExtension().lastPathComponent)
    }

    static func export(_ profile: ProxyProfile) throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export Profile"
        // Match the extension to the actual format: exporting a sing-box
        // profile as ".yaml" misleads both users and other tools.
        let isSingbox = profile.format == .singbox
        panel.nameFieldStringValue = "\(profile.name).\(isSingbox ? "json" : "yaml")"
        panel.allowedContentTypes = isSingbox ? [.json] : [.yaml, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try profile.rawConfig.write(to: url, atomically: true, encoding: .utf8)
    }

    private static var configTypes: [UTType] {
        // Do not require a .yaml/.json suffix. Format is sniffed from content
        // (Clash YAML, then sing-box JSON) after the file is read.
        var types: [UTType] = [.item, .data, .yaml, .json, .plainText]
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        if let conf = UTType(filenameExtension: "conf") { types.append(conf) }
        return types
    }
}

/// What the importer skipped, grouped by kind. Skipped rules let traffic
/// fall through to later rules; skipped groups fail the rules that use them.
private struct ImportWarningsSheet: View {
    var warnings: [ConfigWarning]
    var onDone: () -> Void

    private static let order: [ConfigWarning.Kind] = [.group, .rule, .proxy, .dns]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Some Entries Were Not Imported").font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            List {
                ForEach(Self.order, id: \.self) { kind in
                    let items = warnings.filter { $0.kind == kind }
                    if !items.isEmpty {
                        Section("\(Self.title(kind)) (\(items.count))") {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, warning in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(warning.text)
                                        .font(.body.monospaced())
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    Text(warning.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 240)
            SheetActionBar(doneTitle: "OK", onDone: onDone)
        }
        .frame(width: 560, height: 460)
    }

    private var summary: String {
        let groups = warnings.filter { $0.kind == .group }.count
        let rules = warnings.filter { $0.kind == .rule }.count
        let proxies = warnings.filter { $0.kind == .proxy }.count
        let dns = warnings.filter { $0.kind == .dns }.count
        var parts: [String] = []
        if groups > 0 { parts.append("\(groups) group(s)") }
        if rules > 0 { parts.append("\(rules) rule(s)") }
        if proxies > 0 { parts.append("\(proxies) proxy(ies)") }
        if dns > 0 { parts.append("\(dns) DNS setting(s)") }
        return "PrizmX skipped \(parts.joined(separator: ", ")) it does not support. "
            + "Traffic that would match a skipped rule falls through to later rules; "
            + "rules that use a skipped group fail instead of going direct."
    }

    private static func title(_ kind: ConfigWarning.Kind) -> String {
        switch kind {
        case .group: "Policy Groups"
        case .rule: "Rules"
        case .proxy: "Proxies"
        case .dns: "DNS"
        }
    }
}

private struct ProfileNameSheet: View {
    var title: String
    var doneTitle: String
    @Binding var name: String
    var onCancel: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            }
            .padding(20)
            SheetActionBar(
                doneTitle: doneTitle,
                doneEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onDone: onDone
            ) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 360)
        .presentationSizing(.fitted)
    }
}

private struct InstallFromURLSheet: View {
    @Binding var name: String
    @Binding var urlString: String
    var isImporting: Bool
    var errorMessage: String?
    var onCancel: () -> Void
    var onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install from URL").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Subscription URL", text: $urlString)
                    .textContentType(.URL)
            }
            .formStyle(.grouped)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetActionBar(
                doneTitle: "Install",
                doneEnabled: !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isImporting,
                onDone: onInstall
            ) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

#Preview("Profiles") {
    ProfilesPane()
        .environment(AppModel.preview)
}
