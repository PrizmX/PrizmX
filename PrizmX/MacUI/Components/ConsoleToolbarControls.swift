import AppKit
import SwiftUI

/// Native `NSSearchField` so the toolbar can keep system search chrome
/// without `.searchable` stealing the trailing-most slot.
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
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
