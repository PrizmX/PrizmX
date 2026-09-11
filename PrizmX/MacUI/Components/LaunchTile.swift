import SwiftUI

/// Surge-style More entry: icon tile + title + caption. Not an InfoWidget.
struct LaunchTile: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color
    var enabled: Bool = true
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
    }
}

#Preview("Launch tiles") {
    HStack(alignment: .top, spacing: 32) {
        LaunchTile(
            title: "Settings",
            subtitle: "Appearance and shortcuts.",
            systemImage: "slider.horizontal.3",
            tint: .indigo
        )
        LaunchTile(
            title: "Profiles",
            subtitle: "Subscriptions and local configs.",
            systemImage: "doc.text.fill",
            tint: .blue
        )
        LaunchTile(
            title: "Scripts",
            subtitle: "Extend routing with JavaScript.",
            systemImage: "flask.fill",
            tint: .pink,
            enabled: false
        )
    }
    .padding(32)
    .frame(width: 720)
}
