import AppKit
import SwiftUI

@main
struct PrizmXApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        Window("PrizmX", id: AppWindowID.main) {
            SurgeStyleMainWindow()
                .environment(appModel)
                .onAppear { appModel.applyLaunchPolicy() }
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(appModel.menuBarOnly ? .suppressed : .presented)
        // App-wide commands live on the main window scene only; attaching the
        // same set to every scene would duplicate menu items.
        .commands {
            AppCommands(appModel: appModel)
        }

        Window("Select Node", id: AppWindowID.nodePicker) {
            NavigationStack {
                NodeSelectPane(showsToolbar: true, showsDoneButton: true)
            }
            .environment(appModel)
            .frame(minWidth: 420, minHeight: 480)
        }
        .defaultSize(width: 520, height: 560)
        .defaultLaunchBehavior(.suppressed)

        Window("Inspector", id: AppWindowID.inspector) {
            InspectorPane()
                .environment(appModel)
                .background(FullScreenPrimaryWindow())
        }
        .defaultSize(width: 1100, height: 700)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarPanel()
                .environment(appModel)
        } label: {
            MenuBarStatusLabel()
                .environment(appModel)
                .onAppear { appModel.applyLaunchPolicy() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPane()
                .environment(appModel)
                .frame(minWidth: 420, minHeight: 360)
        }
    }
}

/// Secondary SwiftUI windows default to zoom (+). Match the main window fullscreen traffic light.
private struct FullScreenPrimaryWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.apply(nsView.window)
    }

    private static func apply(_ window: NSWindow?) {
        window?.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])
        window?.collectionBehavior.remove(.fullScreenAuxiliary)
    }
}
