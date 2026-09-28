import AppKit
import SwiftUI
import PrizmXUIEngine

extension View {
    /// When a managed sidebar is collapsed, drop the auto system toggle so it
    /// is not torn down and re-created mid-animation (visible flicker); the
    /// caller supplies a stable custom toggle in the detail toolbar instead.
    ///
    /// The swap reconciles the window toolbar, so persistent icons must live
    /// on the detail pane (Rules, InspectorDetail), not on the split view.
    @ViewBuilder
    func hidingSystemSidebarToggle(_ hidden: Bool) -> some View {
        if hidden {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

/// Plus/minus (and similar) capsule on Profiles / Policies / Rules / Events.
struct IconControlGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ControlGroup(content: content)
            .controlGroupStyle(.navigation)
            .labelStyle(.iconOnly)
    }
}

/// In-toolbar search. Prefer this over `.searchable` in the main console —
/// `.searchable` installs a second bar with its own separator and material.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var width: CGFloat = 180

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSSearchField,
        context: Context
    ) -> CGSize? {
        let height = nsView.intrinsicContentSize.height
        guard let proposed = proposal.width, proposed.isFinite else {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: min(width, max(0, proposed)), height: height)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct ConsoleEmptyState: View {
    var title: String
    var systemImage: String
    var description: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InspectorToolbarButton: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Inspector", systemImage: "arrow.up.forward.app") {
            appModel.presentInspector(using: openWindow)
        }
        .labelStyle(.iconOnly)
        .help("Inspector")
    }
}

/// Hidden until `dashboard.lastError` is set. Sits left of Inspector.
struct ErrorToolbarButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var showsPopover = false

    var body: some View {
        if let error = appModel.dashboard.lastError {
            Button("Error", systemImage: "exclamationmark.triangle.fill") {
                showsPopover.toggle()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.orange)
            .help(error)
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    ScrollView {
                        Text(error)
                            .font(.body)
                            .textSelection(.enabled)
                            // Wrap at the popover width instead of truncating
                            // to one line; ScrollView caps long errors.
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                }
                .padding(16)
                .frame(width: 360)
            }
        }
    }
}
