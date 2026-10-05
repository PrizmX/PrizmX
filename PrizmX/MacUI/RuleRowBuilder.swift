import Foundation
import PrizmXServices

/// One row of the Rules table: a compiled rule with its labels precomputed.
struct RuleRow: Identifiable, Equatable {
    /// Local rules by overlay ID; profile rules by position among the profile
    /// rules, so adding a local rule does not change every profile row's ID.
    enum ID: Hashable {
        case local(UUID)
        case profile(Int)
    }

    var id: ID
    var number: Int
    var type: String
    var payload: String
    var policy: String
    /// Lowercased type, payload and policy, matched by the search field.
    var searchText: String

    var overlayID: UUID? {
        if case .local(let id) = id { id } else { nil }
    }

    var isLocal: Bool { overlayID != nil }
}

/// What the Rules table shows: the active profile's compiled rules (local
/// overlay rules first), filtered by the search text.
///
/// Rows are built once per change of the rules and filtered once per change
/// of the query, so a body pass for a selection or toolbar change reuses
/// both. Profiles can expand to tens of thousands of rules.
final class RuleRowBuilder {
    private var rules: [RouteRule] = []
    private var localIDs: [UUID] = []
    private var all: [RuleRow] = []
    private var query = ""
    private var filtered: [RuleRow] = []

    func rows(rules: [RouteRule], localIDs: [UUID], search: String) -> [RuleRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rules != self.rules || localIDs != self.localIDs {
            self.rules = rules
            self.localIDs = localIDs
            all = Self.build(rules, localIDs: localIDs)
            filtered = Self.filter(all, query)
        } else if query != self.query {
            filtered = Self.filter(all, query)
        }
        self.query = query
        return filtered
    }

    private static func build(_ rules: [RouteRule], localIDs: [UUID]) -> [RuleRow] {
        rules.enumerated().map { index, rule in
            let type = rule.displayType
            let payload = rule.displayPayload
            let policy = rule.displayPolicy
            return RuleRow(
                id: index < localIDs.count ? .local(localIDs[index]) : .profile(index - localIDs.count),
                number: index + 1,
                type: type,
                payload: payload,
                policy: policy,
                searchText: "\(type)\n\(payload)\n\(policy)".lowercased()
            )
        }
    }

    private static func filter(_ rows: [RuleRow], _ query: String) -> [RuleRow] {
        guard !query.isEmpty else { return rows }
        // Both sides are lowercased: a literal search is ~4x faster than
        // `localizedCaseInsensitiveContains` over a long list.
        return rows.filter { $0.searchText.range(of: query, options: .literal) != nil }
    }
}
