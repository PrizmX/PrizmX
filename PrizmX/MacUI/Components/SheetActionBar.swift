import AppKit
import SwiftUI

/// Bottom button row matching system alerts: hairline separator, same
/// `windowBackgroundColor` above and below it.
struct SheetActionBar<Leading: View>: View {
    var doneTitle: String = "Done"
    var doneEnabled: Bool = true
    var onDone: () -> Void
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                leading()
                Spacer(minLength: 12)
                Button(doneTitle, action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!doneEnabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
    }
}

extension SheetActionBar where Leading == EmptyView {
    init(doneTitle: String = "Done", doneEnabled: Bool = true, onDone: @escaping () -> Void) {
        self.init(doneTitle: doneTitle, doneEnabled: doneEnabled, onDone: onDone) {
            EmptyView()
        }
    }
}
