import AppKit
import SwiftUI
import PrizmXMacUI

@main
struct PrizmXApp: App {
    @State private var appModel: AppModel

    init() {
        Analytics.start()
        let config = MacHostConfiguration(
            capabilities: .community,
            analytics: MacAnalyticsAdapter(
                isEnabled: { Analytics.isEnabled },
                setEnabled: { Analytics.setEnabled($0) },
                updateProxyState: { tun, systemProxy in
                    Analytics.updateProxyState(tun: tun, systemProxy: systemProxy)
                }
            ),
            activateTunnelExtension: {
                try await TunnelSystemExtension.activate()
            },
            needsTunnelExtensionUpgrade: {
                TunnelSystemExtension.needsUpgrade
            },
            prepareSystemProxyHelper: {
                await ProxyHelperSetup.prepare()
            },
            plugins: MacHostPlugins(
                settingsGeneralExtra: { AnyView(ProxyHelperRow()) }
            )
        )
        _appModel = State(initialValue: AppModel(configuration: config))
    }

    var body: some Scene {
        Window("PrizmX", id: AppWindowID.main) {
            SurgeStyleMainWindow()
                .environment(appModel)
                .onAppear { appModel.applyLaunchPolicy() }
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(appModel.menuBarOnly ? .suppressed : .presented)
        .commands {
            AppCommands(appModel: appModel)
        }

        Window("Select Node", id: AppWindowID.nodePicker) {
            NavigationStack {
                NodeSelectPane()
            }
            .environment(appModel)
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
    }
}
