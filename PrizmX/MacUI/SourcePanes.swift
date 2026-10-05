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
                NativeTable(
                    rows: rows,
                    columns: Self.columns,
                    selection: $selectedID,
                    sortOrder: $sortOrder,
                    contextMenu: { row in
                        var items = [NativeTableMenuItem("Open in Inspector") {
                            appModel.presentInspectorForApp(key: row.id, using: openWindow)
                        }]
                        if let bundleID = row.bundleID {
                            items.append(NativeTableMenuItem("Copy Bundle ID") { copy(bundleID) })
                        }
                        return items
                    },
                    primaryAction: { row in
                        appModel.presentInspectorForApp(key: row.id, using: openWindow)
                    }
                )
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

    private static let columns: [NativeTableColumn<AppModel.AppRosterRow>] = [
        .init("app", "App", width: 240, minWidth: 120, flexible: true, icon: { row in
            AppIcon.resolvedNSImage(bundleID: row.bundleID, executablePath: row.executablePath)
                ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        }, sort: .by(\.name)) { $0.name },
        .init("sessions", "Sessions", width: 80, font: NativeTableFont.digits, sort: .by(\.sessions)) { "\($0.sessions)" },
        .init("down", "↓", width: 80, font: NativeTableFont.digits, sort: .by(\.downloadBytes)) {
            ByteRateFormatter.byteCount($0.downloadBytes)
        },
        .init("up", "↑", width: 80, font: NativeTableFont.digits, sort: .by(\.uploadBytes)) {
            ByteRateFormatter.byteCount($0.uploadBytes)
        },
        .init("rate", "Rate", width: 90, font: NativeTableFont.digits, sort: .by(\.bytesPerSecond)) {
            rateLabel($0.bytesPerSecond)
        },
    ]

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

    private static func rateLabel(_ bytesPerSecond: Double) -> String {
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
                NativeTable(rows: rows, columns: Self.columns, selection: $selectedID, sortOrder: $sortOrder)
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

    private static let columns: [NativeTableColumn<AppModel.LANClientRow>] = [
        .init("device", "Device", width: 200, minWidth: 120, flexible: true, icon: { row in
            NSImage(systemSymbolName: row.systemImage, accessibilityDescription: nil)
        }, sort: .by(\.name)) { $0.name },
        .init("type", "Type", width: 90, color: { _ in .secondaryLabelColor }, sort: .by(\.kindTitle)) { $0.kindTitle },
        .init("address", "Address", width: 160, minWidth: 120, font: NativeTableFont.mono, sort: .by(\.address)) { $0.address },
        .init("sessions", "Sessions", width: 80, font: NativeTableFont.digits, sort: .by(\.sessions)) { "\($0.sessions)" },
        .init("down", "↓", width: 80, font: NativeTableFont.digits, sort: .by(\.downloadBytes)) {
            ByteRateFormatter.byteCount($0.downloadBytes)
        },
        .init("up", "↑", width: 80, font: NativeTableFont.digits, sort: .by(\.uploadBytes)) {
            ByteRateFormatter.byteCount($0.uploadBytes)
        },
    ]

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
