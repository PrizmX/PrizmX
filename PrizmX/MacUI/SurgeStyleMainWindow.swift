import AppKit
import SwiftUI
import PrizmXServices
import PrizmXUIEngine

/// Console: Home + Sources / Routing / Debug + More, Inspector pops out.
struct SurgeStyleMainWindow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            List(selection: $appModel.selectedSidebarItem) {
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                List(selection: $appModel.selectedSidebarItem) {
                    sidebarRow(.more)
                }
                .listStyle(.sidebar)
                .scrollDisabled(true)
                .frame(height: 36)
                .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 520)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "arrow.up.forward.app", action: openInspector)
                    .labelStyle(.iconOnly)
                    .help("Inspector")
            }
        }
        .sheet(isPresented: $appModel.isNodePickerPresented) {
            NavigationStack {
                NodeSelectPane(showsToolbar: true, showsDoneButton: true)
            }
            .environment(appModel)
            .frame(minWidth: 480, minHeight: 520)
        }
        .sheet(item: $appModel.presentedMoreSheet) { sheet in
            switch sheet {
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

    @ViewBuilder
    private var detail: some View {
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

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(item)
    }

    private func openInspector() {
        openWindow(id: AppWindowID.inspector)
        NSApp.activate(ignoringOtherApps: true)
        DockPolicy.apply(menuBarOnly: appModel.menuBarOnly)
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
                openWindow(id: AppWindowID.nodePicker)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandGroup(after: .windowList) {
            Button("Main Console") {
                openWindow(id: AppWindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("Inspector") {
                openWindow(id: AppWindowID.inspector)
                NSApp.activate(ignoringOtherApps: true)
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
