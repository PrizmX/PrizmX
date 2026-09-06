import PrizmXNodes

extension PolicyGroup.Mode {
    var displayName: String {
        switch self {
        case .select: "select"
        case .urlTest: "url-test"
        case .fallback: "fallback"
        case .loadBalance: "load-balance"
        }
    }
}
