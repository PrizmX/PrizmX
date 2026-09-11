import Charts
import SwiftUI
import PrizmXServices
import PrizmXUIComponents

/// One named bucket for stacked download / upload bars.
struct TrafficCategory: Identifiable, Hashable {
    var id: String
    var name: String
    var downloadBytes: UInt64
    var uploadBytes: UInt64
}

/// Horizontal stacked bars: download vs upload by category.
struct TrafficBarChart: View {
    var categories: [TrafficCategory]
    var emptySystemImage: String = "chart.bar"
    var emptyDescription: String = "Traffic by app will appear here."

    var body: some View {
        if categories.isEmpty {
            ContentUnavailableView {
                Label("No Traffic", systemImage: emptySystemImage)
            } description: {
                Text(emptyDescription)
            }
            .frame(minHeight: 120)
        } else {
            Chart(plottable) { item in
                BarMark(
                    x: .value("Bytes", item.bytes),
                    y: .value("Name", item.name)
                )
                .foregroundStyle(by: .value("Direction", item.direction))
            }
            .chartForegroundStyleScale([
                "Down": WidgetChrome.trafficDownload,
                "Up": WidgetChrome.trafficUpload
            ])
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(ByteRateFormatter.byteCount(UInt64(max(0, bytes))))
                        }
                    }
                }
            }
            .accessibilityLabel(Text("Traffic by category"))
        }
    }

    private var plottable: [BarRow] {
        categories.flatMap { category in
            [
                BarRow(id: "\(category.id)-down", name: category.name, direction: "Down", bytes: Double(category.downloadBytes)),
                BarRow(id: "\(category.id)-up", name: category.name, direction: "Up", bytes: Double(category.uploadBytes))
            ]
        }
    }
}

private struct BarRow: Identifiable {
    var id: String
    var name: String
    var direction: String
    var bytes: Double
}
