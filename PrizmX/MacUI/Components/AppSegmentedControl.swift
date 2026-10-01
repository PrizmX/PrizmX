import AppKit
import SwiftUI

// One segmented style app-wide:
//
// - Content (panels, sidebars, Home cards): `AppSegmentedControl`.
// - Window toolbars: a `Picker` with `.appToolbarSegmentedStyle()`, which the
//   system draws as a toolbar control group.
//
// `AppSegmentedControl` is drawn to match the system `NSSegmentedControl`
// (macOS 26+: small / regular are rounded rectangles, large is a capsule),
// plus a selection that slides between segments, which the system control
// does not do (it updates each segment in place).

/// The app's segmented control. Geometry and colors follow
/// `NSSegmentedControl` as rendered on macOS 27: a `secondarySystemFill`
/// track, a thumb filling the selected segment (the accent color while the
/// window is active, gray otherwise), and 1 pt dividers between two
/// unselected segments.
struct AppSegmentedControl<Value: Hashable>: View {
    enum Size {
        /// Dense card headers and sidebars.
        case small
        /// Default in panels and forms.
        case regular
        /// A card's primary control (capsule).
        case large

        var height: CGFloat {
            switch self {
            case .small: 20
            case .regular: 24
            case .large: 28
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .small: 5
            case .regular: 6
            case .large: height / 2
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .small: NSFont.systemFontSize(for: .small)
            case .regular, .large: NSFont.systemFontSize(for: .regular)
            }
        }

        /// Horizontal space beside a title when segments hug their titles.
        var padding: CGFloat {
            switch self {
            case .small: 10
            case .regular: 12
            case .large: 14
            }
        }
    }

    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    var size: Size = .regular
    /// Equal-width segments across the proposed width (otherwise segments
    /// hug their titles).
    var fill = false

    /// Drives the thumb, so the animation stays inside this control instead
    /// of riding along with the binding into the rest of the app.
    @State private var shown: Value
    @Namespace private var thumb
    @Environment(\.appearsActive) private var appearsActive

    init(
        options: [(value: Value, title: String)],
        selection: Binding<Value>,
        size: Size = .regular,
        fill: Bool = false
    ) {
        self.options = options
        self._selection = selection
        self.size = size
        self.fill = fill
        self._shown = State(initialValue: selection.wrappedValue)
    }

    private static var slide: Animation { .snappy(duration: 0.25) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                segment(option, index: index)
            }
        }
        .frame(height: size.height)
        .background(shape.fill(Color(nsColor: .secondarySystemFill)))
        .onChange(of: selection) { _, value in
            guard value != shown else { return }
            withAnimation(Self.slide) { shown = value }
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: (value: Value, title: String), index: Int) -> some View {
        let selected = option.value == shown
        let next = options.indices.contains(index + 1) ? options[index + 1].value : nil
        let divides = next != nil && !selected && next != shown
        return Button {
            guard option.value != selection else { return }
            withAnimation(Self.slide) { shown = option.value }
            selection = option.value
        } label: {
            Text(option.title)
                .font(.system(size: size.fontSize))
                .foregroundStyle(selected && appearsActive ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, size.padding)
                .frame(maxWidth: fill ? .infinity : nil, maxHeight: .infinity)
                .contentShape(shape)
                .background {
                    if selected {
                        shape
                            .fill(appearsActive ? Color.accentColor : segmentThumbColor)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(segmentDividerColor)
                .frame(width: 1, height: size.height * 0.64)
                .offset(x: 0.5)
                .opacity(divides ? 1 : 0)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// Segmented `Picker` in a window toolbar.
    func appToolbarSegmentedStyle() -> some View {
        pickerStyle(.segmented).labelsHidden()
    }
}

/// Inactive thumb: over the `secondarySystemFill` track this composites to
/// the system's selected segment (black / white at 0.196 total alpha).
private let segmentThumbColor = Color(nsColor: NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.128)
})

/// Over the track this composites to the system divider (0.294 total alpha).
private let segmentDividerColor = Color(nsColor: NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.234)
})

private enum PreviewMode: String, CaseIterable {
    case rule = "Rule"
    case global = "Global"
    case direct = "Direct"
}

#Preview("App Segmented") {
    struct Demo: View {
        @State private var mode: PreviewMode = .rule
        var body: some View {
            VStack(spacing: 16) {
                AppSegmentedControl(options: PreviewMode.allCases.map { ($0, $0.rawValue) }, selection: $mode, size: .small)
                AppSegmentedControl(options: PreviewMode.allCases.map { ($0, $0.rawValue) }, selection: $mode, fill: true)
                AppSegmentedControl(options: PreviewMode.allCases.map { ($0, $0.rawValue) }, selection: $mode, size: .large, fill: true)
            }
            .padding(24)
            .frame(width: 320)
        }
    }
    return Demo()
}
