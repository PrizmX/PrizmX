import Foundation
import Observation
import PrizmXUIComponents

enum HomeWidgetID: String, CaseIterable, Codable, Identifiable {
    case outbound
    case capture
    case subscription
    case node
    case latency
    case connections
    case upload
    case download
    case totalTraffic
    case ranking

    var id: String { rawValue }

    var size: WidgetSize {
        switch self {
        case .latency, .connections, .upload, .download:
            return .small
        case .outbound, .capture, .subscription, .node, .totalTraffic:
            return .medium
        case .ranking:
            return .large
        }
    }
}

struct PlacedWidget: Identifiable, Hashable {
    var id: HomeWidgetID
    var column: Int
    var row: Int
    var size: WidgetSize
}

@Observable
final class HomeWidgetLayout {
    private static let defaultsKey = "homeWidgetOrder"

    var order: [HomeWidgetID] {
        didSet { persist() }
    }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        var parsed = stored.compactMap(HomeWidgetID.init(rawValue:))
        for id in HomeWidgetID.allCases where !parsed.contains(id) {
            parsed.append(id)
        }
        order = parsed
    }

    func move(_ dragged: HomeWidgetID, before target: HomeWidgetID) {
        guard dragged != target else { return }
        guard let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        let item = order.remove(at: from)
        // After removal the target shifts left by one when dragging forward.
        order.insert(item, at: from < to ? to - 1 : to)
    }

    func packed(columns: Int = WidgetGrid.columns) -> [PlacedWidget] {
        var grid: [[Bool]] = []

        func ensureRows(_ count: Int) {
            while grid.count < count {
                grid.append(Array(repeating: false, count: columns))
            }
        }

        func canPlace(column: Int, row: Int, width: Int, height: Int) -> Bool {
            guard column + width <= columns else { return false }
            ensureRows(row + height)
            for rowIndex in row..<(row + height) {
                for columnIndex in column..<(column + width) {
                    if grid[rowIndex][columnIndex] { return false }
                }
            }
            return true
        }

        func occupy(column: Int, row: Int, width: Int, height: Int) {
            for rowIndex in row..<(row + height) {
                for columnIndex in column..<(column + width) {
                    grid[rowIndex][columnIndex] = true
                }
            }
        }

        var placed: [PlacedWidget] = []
        for id in order {
            let width = id.size.columns
            let height = id.size.rows
            var row = 0
            var done = false
            while !done, row < 64 {
                for column in 0...(columns - width) {
                    if canPlace(column: column, row: row, width: width, height: height) {
                        occupy(column: column, row: row, width: width, height: height)
                        placed.append(PlacedWidget(id: id, column: column, row: row, size: id.size))
                        done = true
                        break
                    }
                }
                if !done { row += 1 }
            }
        }
        return placed
    }

    private func persist() {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.defaultsKey)
    }
}
