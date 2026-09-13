import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

/// Console: Home + Sources / Routing / Advanced / System, Inspector pops out.
struct SurgeStyleMainWindow: View {
    @Environment(AppModel.self) private var appModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var isSidebarCollapsed: Bool {
        columnVisibility == .detailOnly
    }

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
                .hidingSystemSidebarToggle(isSidebarCollapsed)
                .toolbar {
                    // Expanded: system toggle stays; Inspector sits to its left.
                    if !isSidebarCollapsed {
                        ToolbarItem(placement: .automatic) {
                            InspectorToolbarButton()
                        }
                    }
                }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { windowToolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: appModel.dashboard.status) { _, _ in
            appModel.refreshSessionClock()
        }
        .onAppear {
            appModel.refreshSessionClock()
        }
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        if isSidebarCollapsed {
            ToolbarItem(placement: .navigation) {
                IconControlGroup {
                    InspectorToolbarButton()
                    sidebarToggleButton
                }
            }
        }
        if appModel.dashboard.lastError != nil {
            ToolbarItem(placement: .confirmationAction) {
                ErrorToolbarButton()
            }
        }
    }

    private var sidebarToggleButton: some View {
        Button("Toggle Sidebar", systemImage: "sidebar.left") {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
        .labelStyle(.iconOnly)
        .help("Toggle Sidebar")
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
        .consoleSidebarColumn()
    }

    /// Debug bisection (`PRIZMX_BARE_SIDEBAR=1`): no selection.
    private var plainSidebar: some View {
        List {
            Text("Home")
            Text("Policies")
        }
        .consoleSidebarColumn()
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

private extension View {
    @ViewBuilder
    func hidingSystemSidebarToggle(_ hidden: Bool) -> some View {
        if hidden {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }

    /// Wide enough for window controls + Inspector + the system sidebar toggle.
    func consoleSidebarColumn() -> some View {
        listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 360)
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
