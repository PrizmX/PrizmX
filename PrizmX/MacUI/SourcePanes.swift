import AppKit
import SwiftUI
import PrizmXServices

struct AppsPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var selectedID: String?
    @State private var sortOrder: [KeyPathComparator<AppModel.AppRosterRow>] = [
        KeyPathComparator(\.downloadBytes, order: .reverse)
    ]

    var body: some View {
        let rows = displayRows
        Group {
            if rows.isEmpty && search.isEmpty {
                ConsoleEmptyState(
                    title: "No Apps",
                    systemImage: SidebarItem.apps.systemImage,
                    description: emptyDescription
                )
            } else {
                Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
                    TableColumn("App", value: \.name) { (row: AppModel.AppRosterRow) in
                        HStack(spacing: 6) {
                            AppIconView(
                                bundleID: row.bundleID,
                                executablePath: row.executablePath,
                                size: 16
                            )
                            Text(row.name)
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Sessions", value: \.sessions) { row in
                        Text("\(row.sessions)")
                            .font(.body.monospacedDigit())
                    }
                    .width(80)
                    TableColumn("↓", value: \.downloadBytes) { row in
                        Text(ByteRateFormatter.byteCount(row.downloadBytes))
                            .font(.body.monospacedDigit())
                    }
                    .width(80)
                    TableColumn("↑", value: \.uploadBytes) { row in
                        Text(ByteRateFormatter.byteCount(row.uploadBytes))
                            .font(.body.monospacedDigit())
                    }
                    .width(80)
                    TableColumn("Rate", value: \.bytesPerSecond) { row in
                        Text(rateLabel(row.bytesPerSecond))
                            .font(.body.monospacedDigit())
                    }
                    .width(90)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                        Button("Open in Inspector") {
                            appModel.presentInspectorForApp(key: row.id, using: openWindow)
                        }
                        if let bundleID = row.bundleID {
                            Button("Copy Bundle ID") { copy(bundleID) }
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first {
                        appModel.presentInspectorForApp(key: id, using: openWindow)
                    }
                }
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView {
                            Label("No Apps", systemImage: SidebarItem.apps.systemImage)
                        } description: {
                            Text("No apps match this filter.")
                        }
                    }
                }
            }
        }
        .navigationTitle("Apps")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $search, prompt: "Search apps")
            }
        }
    }

    private var displayRows: [AppModel.AppRosterRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = appModel.appRosterRows.sorted(using: sortOrder)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var emptyDescription: String {
        if !appModel.tunModeEnabled {
            return "Turn on TUN to attribute local apps."
        }
        return "Process-level traffic appears when TUN captures local apps."
    }

    private func rateLabel(_ bytesPerSecond: Double) -> String {
        bytesPerSecond > 0
            ? ByteRateFormatter.string(fromBytesPerSecond: bytesPerSecond)
            : "—"
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct LANPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedID: String?
    @State private var sortOrder: [KeyPathComparator<AppModel.LANClientRow>] = [
        KeyPathComparator(\.downloadBytes, order: .reverse)
    ]

    var body: some View {
        let rows = appModel.lanClientRows.sorted(using: sortOrder)

        VStack(alignment: .leading, spacing: 0) {
            header
            if appModel.allowLANEnabled {
                Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
                    TableColumn("Device", value: \.name) { (row: AppModel.LANClientRow) in
                        HStack(spacing: 6) {
                            Image(systemName: row.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                            Text(row.name)
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Type", value: \.kindTitle) { row in
                        Text(row.kindTitle)
                            .foregroundStyle(.secondary)
                    }
                    .width(90)
                    TableColumn("Address", value: \.address) { row in
                        Text(row.address)
                            .font(.body.monospaced())
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Sessions", value: \.sessions) { row in
                        Text("\(row.sessions)")
                            .font(.body.monospacedDigit())
                    }
                    .width(80)
                    TableColumn("↓", value: \.downloadBytes) { row in
                        Text(ByteRateFormatter.byteCount(row.downloadBytes))
                            .font(.body.monospacedDigit())
                    }
                    .width(80)
                    TableColumn("↑", value: \.uploadBytes) { row in
                        Text(ByteRateFormatter.byteCount(row.uploadBytes))
                            .font(.body.monospacedDigit())
                    }
                    .width(80)
                }
                .tableStyle(.inset)
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView {
                            Label("No Devices", systemImage: SidebarItem.lan.systemImage)
                        } description: {
                            Text("LAN clients appear once they send traffic through this Mac.")
                        }
                    }
                }
            } else {
                ConsoleEmptyState(
                    title: "LAN Off",
                    systemImage: SidebarItem.lan.systemImage,
                    description: "Turn on Allow LAN to proxy other devices on this network."
                )
            }
        }
        .navigationTitle("LAN")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appModel.lanAddressLabel)
                    .font(.title2.monospacedDigit())
                    .textSelection(.enabled)
                Text(headerCaption)
                    .foregroundStyle(appModel.mixedPortListenError == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Copy") {
                guard let endpoint = appModel.lanCopyEndpoint else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(endpoint, forType: .string)
            }
            .disabled(appModel.lanCopyEndpoint == nil)
            .help("Copy HTTP/SOCKS address")
        }
        .padding(20)
    }

    private var headerCaption: String {
        if let error = appModel.mixedPortListenError {
            return error
        }
        if !appModel.allowLANEnabled {
            return "Other devices can use this Mac as HTTP/SOCKS."
        }
        return "Other devices set this as HTTP/SOCKS proxy."
    }
}

#Preview("Apps") {
    AppsPane()
        .environment(AppModel.preview)
        .frame(width: 720, height: 420)
}

#Preview("LAN") {
    LANPane()
        .environment(AppModel.preview)
        .frame(width: 720, height: 420)
}
