import Foundation
import PrizmXServices

/// What the Inspector shows, derived from the flow history: the request
/// table (scope, filter, selected group, sort) and the group sidebar.
///
/// Built once per change of its inputs, not on every view access. Rows whose
/// flow did not change are reused, so a 1s poll over a full history rebuilds
/// only the flows that moved and runs one filter / group / sort pass.
struct InspectorRowBuilder {
    struct Input {
        var flows: [FlowRecord]
        var scope: InspectorScope
        var filter: String
        var grouping: InspectorGrouping
        /// Empty is All Apps / All Hosts.
        var selectedGroup: String
        var sortOrder: [KeyPathComparator<InspectorRequest>]
        var lanDevices: [String: LANDevice]
        var serials: [UUID: UInt64]
    }

    struct Output: Equatable {
        /// Scope, filter and selected group applied, sorted.
        var rows: [InspectorRequest] = []
        var groups: [InspectorGroupRow] = []
        /// Scope and filter applied, every group (the All row).
        var allCount = 0
    }

    private struct Cached {
        var flow: FlowRecord
        var lanAddress: String?
        var lanDevice: LANDevice?
        var request: InspectorRequest
    }

    private var cache: [UUID: Cached] = [:]

    mutating func build(_ input: Input) -> Output {
        var next: [UUID: Cached] = [:]
        next.reserveCapacity(input.flows.count)
        let all = input.flows.map { flow -> InspectorRequest in
            let hit = cache[flow.id].flatMap { $0.flow == flow ? $0 : nil }
            let lanAddress = hit.map(\.lanAddress) ?? AppModel.lanClientAddress(flow.sourceHost)
            let lanDevice = lanAddress.flatMap { input.lanDevices[$0] }
            let serial = flow.serial ?? input.serials[flow.id]
            if let hit, hit.lanDevice == lanDevice, hit.request.serial == serial {
                next[flow.id] = hit
                return hit.request
            }
            let request = InspectorRequest(flow: flow, lanDevice: lanDevice, fallbackSerial: input.serials[flow.id])
            next[flow.id] = Cached(flow: flow, lanAddress: lanAddress, lanDevice: lanDevice, request: request)
            return request
        }
        cache = next

        // Surge: Recent is every request, Active only filters to open ones.
        let query = input.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = all.filter { request in
            (input.scope == .recent || !request.closed) && (query.isEmpty || request.matches(query))
        }
        func key(_ request: InspectorRequest) -> String {
            input.grouping == .app ? request.accountingKey : request.hostLabel
        }
        let selected = input.selectedGroup
        let rows = selected.isEmpty ? visible : visible.filter { key($0) == selected }
        return Output(
            rows: rows.sorted(using: input.sortOrder),
            groups: Self.groups(visible, all: all, selected: selected, grouping: input.grouping, key: key),
            allCount: visible.count
        )
    }

    /// Sidebar rows, by name. The selected group stays listed (at 0) while the
    /// scope / filter has no rows for it, so the selection does not fall back
    /// to All; its title and icon come from any request of the group.
    private static func groups(
        _ visible: [InspectorRequest],
        all: [InspectorRequest],
        selected: String,
        grouping: InspectorGrouping,
        key: (InspectorRequest) -> String
    ) -> [InspectorGroupRow] {
        var counts: [String: Int] = [:]
        var samples: [String: InspectorRequest] = [:]
        for request in visible {
            let group = key(request)
            counts[group, default: 0] += 1
            if samples[group] == nil { samples[group] = request }
        }
        if !selected.isEmpty, counts[selected] == nil {
            counts[selected] = 0
            samples[selected] = all.first { key($0) == selected }
        }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { group in
            let sample = samples[group]
            return InspectorGroupRow(
                id: group,
                title: grouping == .app ? sample?.appName ?? group : group,
                count: counts[group] ?? 0,
                bundleID: sample?.appBundleID,
                executablePath: sample?.appExecutablePath,
                placeholderSystemImage: sample?.placeholderSystemImage
            )
        }
    }
}
