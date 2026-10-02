import AppKit
import SwiftUI

@main
struct PrizmXApp: App {
    @State private var appModel = AppModel()

    init() {
        Analytics.start()
    }

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
                NodeSelectPane()
            }
            .environment(appModel)
            // Below 540 pt the toolbar pushes the search field into overflow.
            .frame(minWidth: 540, minHeight: 480)
        }
        .defaultSize(width: 600, height: 560)
        .defaultLaunchBehavior(.suppressed)

        Window("Inspector", id: AppWindowID.inspector) {
            InspectorPane()
                .environment(appModel)
                .background(FullScreenPrimaryWindow())
        }
        .defaultSize(width: 1100, height: 700)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarMenu()
                .environment(appModel)
        } label: {
            MenuBarStatusLabel()
                .environment(appModel)
                .onAppear { appModel.applyLaunchPolicy() }
        }
        .menuBarExtraStyle(.menu)
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
        guard let window else { return }
        let next = window.collectionBehavior
            .union([.fullScreenPrimary, .fullScreenAllowsTiling])
            .subtracting(.fullScreenAuxiliary)
        // Assigning the same value still refreshes the titlebar. Collapse
        // updates this view, so an unconditional write flashes the toolbar.
        guard next != window.collectionBehavior else { return }
        window.collectionBehavior = next
    }
}
