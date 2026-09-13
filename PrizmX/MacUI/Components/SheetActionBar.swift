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

/// Fitted confirmation / message sheet matching ProfileNameSheet.
struct ConfirmSheet: View {
    var title: String
    var message: String
    var doneTitle: String = "OK"
    var showsCancel: Bool = true
    var onCancel: () -> Void = {}
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            SheetActionBar(doneTitle: doneTitle, onDone: onDone) {
                if showsCancel {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 360)
        .presentationSizing(.fitted)
    }
}
