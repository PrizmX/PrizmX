import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

/// Console: Home + Sources / Routing / Debug + More, Inspector pops out.
struct SurgeStyleMainWindow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "PRIZMX_BARE_SIDEBAR") {
                plainSidebar
            } else {
                fullSidebar
            }
            #else
            fullSidebar
            #endif
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 520)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            if appModel.selectedSidebarItem != .rules && appModel.selectedSidebarItem != .policies {
                ToolbarItem(placement: .primaryAction) {
                    InspectorToolbarButton()
                }
            }
        }
        .sheet(item: $appModel.presentedMoreSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet()
                    .environment(appModel)
            case .profiles:
                ProfilesSheet()
                    .environment(appModel)
            case .events:
                EventsSheet()
            }
        }
        .onChange(of: appModel.dashboard.status) { _, _ in
            appModel.refreshSessionClock()
        }
        .onAppear {
            appModel.refreshSessionClock()
        }
    }

    // MARK: - Sidebar

    private var fullSidebar: some View {
        @Bindable var appModel = appModel
        return List(selection: $appModel.selectedSidebarItem) {
            sidebarRow(.home)

            Section("Sources") {
                sidebarRow(.apps)
                sidebarRow(.lan)
            }
            Section("Routing") {
                sidebarRow(.policies)
                sidebarRow(.rules)
            }
            Section("Debug") {
                sidebarRow(.capture)
                sidebarRow(.decrypt)
                sidebarRow(.rewrite)
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom) {
            moreBar
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
    }

    /// Debug bisection (`PRIZMX_BARE_SIDEBAR=1`): no selection, no More bar.
    private var plainSidebar: some View {
        List {
            Text("Home")
            Text("Policies")
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(item)
    }

    private var moreBar: some View {
        Button {
            appModel.selectedSidebarItem = .more
        } label: {
            Label(SidebarItem.more.title, systemImage: SidebarItem.more.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(appModel.selectedSidebarItem == .more ? Color.white : Color.primary)
        .background {
            if appModel.selectedSidebarItem == .more {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PRIZMX_BARE_DETAIL") {
            Color.clear
        } else {
            detailContent
        }
        #else
        detailContent
        #endif
    }

    @ViewBuilder
    private var detailContent: some View {
        switch appModel.selectedSidebarItem {
        case .home:
            HomePane()
        case .apps:
            AppsPane()
        case .lan:
            LANPane()
        case .policies:
            PoliciesPane()
        case .rules:
            RulesPane()
        case .capture:
            ComingSoonPane(
                title: SidebarItem.capture.title,
                systemImage: SidebarItem.capture.systemImage,
                summary: "Filters and recording for the Inspector window."
            )
        case .decrypt:
            ComingSoonPane(
                title: SidebarItem.decrypt.title,
                systemImage: SidebarItem.decrypt.systemImage,
                summary: "HTTPS decryption and certificate trust. Inspector shows headers and bodies once this is wired."
            )
        case .rewrite:
            ComingSoonPane(
                title: SidebarItem.rewrite.title,
                systemImage: SidebarItem.rewrite.systemImage,
                summary: "URL, header, and body rewrite rules."
            )
        case .more:
            MorePane()
        }
    }
}

struct AppCommands: Commands {
    var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("VPN") {
            Button(appModel.isVPNOn ? "Disconnect" : "Connect") {
                appModel.tunModeEnabled.toggle()
            }
            .keyboardShortcut(".", modifiers: .command)

            Button("Select Node…") {
                appModel.presentNodePicker(using: openWindow)
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandGroup(after: .windowList) {
            Button("Main Console") {
                appModel.presentMain(using: openWindow)
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("Inspector") {
                appModel.presentInspector(using: openWindow)
            }
            .keyboardShortcut("i", modifiers: .command)
        }
    }
}

#Preview("Main Window") {
    SurgeStyleMainWindow()
        .environment(AppModel.preview)
        .frame(width: 980, height: 640)
}
