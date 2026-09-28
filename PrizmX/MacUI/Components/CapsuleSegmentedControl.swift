import AppKit
import SwiftUI

/// Capsule segmented control styled after the system apps' control, with a
/// sliding selection thumb. SwiftUI's `.segmented` picker renders an
/// NSSegmentedControl which switches instantly; this animates the thumb
/// left/right between segments instead.
struct CapsuleSegmentedControl<Option: Hashable & Identifiable>: View {
    var options: [Option]
    @Binding var selection: Option
    var title: (Option) -> String

    @Namespace private var thumb

    init(
        options: [Option],
        selection: Binding<Option>,
        title: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Option) -> some View {
        let selected = selection == option
        return Button {
            guard !selected else { return }
            // Critically damped: a bouncing spring visibly trails/overshoots
            // compared to the system segmented control.
            withAnimation(.snappy(duration: 0.22)) {
                selection = option
            }
        } label: {
            Text(title(option))
                .font(.callout)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3.5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private enum PreviewTab: String, CaseIterable, Identifiable {
    case app
    case host
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

#Preview("Capsule Segmented") {
    struct Demo: View {
        @State private var tab: PreviewTab = .app
        var body: some View {
            VStack(spacing: 16) {
                CapsuleSegmentedControl(
                    options: PreviewTab.allCases,
                    selection: $tab,
                    title: \.title
                )
                Text("Selected: \(tab.title)")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 260)
        }
    }
    return Demo()
}
