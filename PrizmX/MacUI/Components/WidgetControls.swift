import SwiftUI
import PrizmXUIComponents

/// Capsule chip picker sized for Home widgets (system segmented is too small).
struct WidgetCapsulePicker<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, compact ? 10 : 8)
                        .padding(.vertical, compact ? 5 : 6)
                        .frame(maxWidth: compact ? nil : .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? WidgetChrome.chipSelected : Color.clear)
                                .shadow(
                                    color: selected ? WidgetChrome.chipShadow : .clear,
                                    radius: 0.5,
                                    y: 0.5
                                )
                        }
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(WidgetChrome.chipTrack)
        }
        .accessibilityElement(children: .contain)
    }
}

struct WidgetIconButton: View {
    var systemImage: String
    var help: String
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}
