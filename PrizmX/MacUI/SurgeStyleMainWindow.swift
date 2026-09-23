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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
                .hidingSystemSidebarToggle(isSidebarCollapsed)
                // Expanded: system toggle in the sidebar header, Inspector
                // to its left. Custom toggle is only used when collapsed.
                .toolbar {
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
        .toolbar {
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
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: appModel.dashboard.status) { _, _ in
            appModel.refreshSessionClock()
        }
        .onAppear {
            appModel.refreshSessionClock()
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
        return NativeSidebarList(selection: $appModel.selectedSidebarItem)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 360)
    }

    /// Debug bisection (`PRIZMX_BARE_SIDEBAR=1`): no selection.
    private var plainSidebar: some View {
        List {
            Text("Home")
            Text("Policies")
        }
        .consoleSidebarColumn()
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
