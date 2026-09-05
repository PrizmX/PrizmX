import SwiftUI

/// System GroupBox used as a titled metric / chart card.
struct MetricCard<Content: View>: View {
    var title: String
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }
}

/// Compact title + large value + optional caption inside a GroupBox.
struct MetricValueCard: View {
    var title: String
    var value: String
    var detail: String?
    var systemImage: String

    var body: some View {
        MetricCard(title: title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Metric cards") {
    HStack(alignment: .top) {
        MetricValueCard(
            title: "Download",
            value: "1.2 MB/s",
            detail: "482 MB",
            systemImage: "arrow.down"
        )
        MetricValueCard(
            title: "Upload",
            value: "86 KB/s",
            detail: "31 MB",
            systemImage: "arrow.up"
        )
    }
    .padding()
    .frame(width: 480)
}
