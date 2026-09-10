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
