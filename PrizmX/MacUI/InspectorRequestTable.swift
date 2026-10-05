import AppKit
import SwiftUI
import PrizmXServices

/// Inspector request table on `NativeTable`.
///
/// SwiftUI `Table` rebuilt the hosting views of every changed row on each 1s
/// poll; with a full history most visible rows are open flows whose bytes
/// move, so All Apps spent the main thread tearing views down.
struct InspectorRequestTable: View {
    var rows: [InspectorRequest]
    @Binding var selection: InspectorRequest.ID?
    @Binding var sortOrder: [KeyPathComparator<InspectorRequest>]

    var body: some View {
        NativeTable(rows: rows, columns: Self.columns, selection: $selection, sortOrder: $sortOrder)
    }

    private static let secondary: (InspectorRequest) -> NSColor = { _ in .secondaryLabelColor }

    private static let columns: [NativeTableColumn<InspectorRequest>] = [
        .init("id", "ID", width: 50, font: NativeTableFont.digits, color: secondary, sort: .by(\.sortSerial)) { $0.idLabel },
        .init("time", "Time", width: 150, font: NativeTableFont.digits, sort: .by(\.timestamp)) { $0.timeLabel },
        .init("app", "App", width: 160, minWidth: 120, icon: { icon(for: $0) }, sort: .by(\.appName)) { $0.appName },
        .init("status", "Status", width: 90, sort: .by(\.statusLabel)) { $0.statusLabel },
        .init("policy", "Policy", width: 200, minWidth: 140, sort: .by(\.routeLabel)) { $0.routeLabel },
        .init("rule", "Rule", width: 180, minWidth: 120, color: secondary, sort: .by(\.ruleLabel)) { $0.ruleLabel },
        .init("down", "↓", width: 70, font: NativeTableFont.digits, sort: .by(\.downloadBytes)) {
            ByteRateFormatter.byteCount($0.downloadBytes)
        },
        .init("up", "↑", width: 70, font: NativeTableFont.digits, sort: .by(\.uploadBytes)) {
            ByteRateFormatter.byteCount($0.uploadBytes)
        },
        .init("duration", "Duration", width: 80, font: NativeTableFont.digits, sort: .by(\.sortDuration)) { $0.durationLabel },
        .init("protocol", "Protocol", width: 70, sort: .by(\.protocolLabel)) { $0.protocolLabel },
        .init("url", "URL", width: 320, minWidth: 160, flexible: true, font: NativeTableFont.mono, sort: .by(\.url)) { $0.url },
    ]

    private static func icon(for request: InspectorRequest) -> NSImage? {
        if request.isLANClient {
            return NSImage(
                systemSymbolName: request.placeholderSystemImage ?? LANDevice.Kind.unknown.systemImage,
                accessibilityDescription: nil
            )
        }
        return AppIcon.resolvedNSImage(bundleID: request.appBundleID, executablePath: request.appExecutablePath)
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
    }
}
