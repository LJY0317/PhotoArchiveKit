enum ReviewKeyboardFocus: Hashable {
    case none
    case search
    case sidebar
    case detail
}

enum ReviewSearchReturnTarget: Equatable {
    case sidebar(itemID: String?)
    case detail(itemID: String?, copyID: String?)
}

struct ReviewKeyboardFocusState {
    private(set) var focus: ReviewKeyboardFocus = .sidebar
    private(set) var searchReturnTarget: ReviewSearchReturnTarget?

    mutating func focus(_ target: ReviewKeyboardFocus) {
        focus = target
        if target != .search {
            searchReturnTarget = nil
        }
    }

    mutating func enterSearch(returningTo target: ReviewSearchReturnTarget) {
        searchReturnTarget = target
        focus = .search
    }

    mutating func beginDirectSearch() {
        searchReturnTarget = nil
        focus = .search
    }

    mutating func endSearch() {
        if focus == .search {
            focus = .none
        }
    }

    mutating func takeSearchReturnTarget() -> ReviewSearchReturnTarget? {
        defer { searchReturnTarget = nil }
        return searchReturnTarget
    }
}
