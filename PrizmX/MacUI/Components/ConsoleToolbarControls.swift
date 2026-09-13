import AppKit
import SwiftUI
import PrizmXUIEngine

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

/// Icon-only `NSSegmentedControl` with a per-segment tooltip.
/// SwiftUI `Picker` + `.help` applies one tip to the whole control.
struct ToolbarIconPicker<Value: Hashable>: NSViewRepresentable {
    struct Item {
        var value: Value
        var title: String
        var systemImage: String
    }

    @Binding var selection: Value
    var items: [Item]

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, items: items)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        apply(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.items = items
        apply(control)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSSegmentedControl,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }

    private func apply(_ control: NSSegmentedControl) {
        control.segmentCount = items.count
        for (index, item) in items.enumerated() {
            control.setImage(
                NSImage(systemSymbolName: item.systemImage, accessibilityDescription: item.title),
                forSegment: index
            )
            control.setLabel("", forSegment: index)
            control.setToolTip(item.title, forSegment: index)
            control.setSelected(item.value == selection, forSegment: index)
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<Value>
        var items: [Item]

        init(selection: Binding<Value>, items: [Item]) {
            self.selection = selection
            self.items = items
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard items.indices.contains(index) else { return }
            selection.wrappedValue = items[index].value
        }
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
                    Text(error)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                .padding(16)
                .frame(minWidth: 240)
            }
        }
    }
}
