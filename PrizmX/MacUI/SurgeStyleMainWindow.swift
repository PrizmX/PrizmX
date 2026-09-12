import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

/// Console: Home + Sources / Routing / Advanced / System, Inspector pops out.
struct SurgeStyleMainWindow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            sidebarColumn
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 520)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            if !appModel.selectedSidebarItem.ownsTrailingInspector {
                ToolbarItemGroup(placement: .primaryAction) {
                    ErrorToolbarButton()
                    InspectorToolbarButton()
                }
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

    @ViewBuilder
    private var sidebarColumn: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PRIZMX_BARE_SIDEBAR") {
            plainSidebar
        } else {
            fullSidebar
        }
        #else
        fullSidebar
        #endif
    }

    private var fullSidebar: some View {
        @Bindable var appModel = appModel
        return List(selection: $appModel.selectedSidebarItem) {
            sidebarRow(.home)

            Section("SOURCES") {
                sidebarRow(.apps)
                sidebarRow(.lan)
            }
            Section("ROUTING") {
                sidebarRow(.profiles)
                sidebarRow(.policies)
                sidebarRow(.rules)
            }
            Section("ADVANCED") {
                sidebarRow(.module)
                sidebarRow(.scripts)
            }
            Section("SYSTEM") {
                sidebarRow(.settings)
                sidebarRow(.events)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
    }

    /// Debug bisection (`PRIZMX_BARE_SIDEBAR=1`): no selection.
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
            .disabled(!item.isEnabled)
            .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
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
        case .profiles:
            ProfilesPane()
        case .events:
            EventsPane()
        case .settings:
            SettingsPane()
        case .module, .scripts:
            ComingSoonPane(item: appModel.selectedSidebarItem)
        }
    }
}

struct AppCommands: Commands {
    var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                appModel.presentSettings(using: openWindow)
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
