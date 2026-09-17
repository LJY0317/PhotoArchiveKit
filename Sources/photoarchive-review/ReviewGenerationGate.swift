struct ReviewGenerationGate {
    private(set) var current = 0

    mutating func begin() -> Int {
        current += 1
        return current
    }

    func accepts(_ generation: Int) -> Bool {
        generation == current
    }
}

struct ReviewReloadApplicationGate {
    private var generations = ReviewGenerationGate()
    private(set) var isLoading = false

    mutating func begin() -> Int {
        isLoading = true
        return generations.begin()
    }

    @discardableResult
    mutating func invalidate() -> Bool {
        let interruptedReload = isLoading
        _ = generations.begin()
        isLoading = false
        return interruptedReload
    }

    mutating func completeIfCurrent(_ generation: Int) -> Bool {
        guard generations.accepts(generation) else { return false }
        isLoading = false
        return true
    }
}

func selectedRootsNeedInitialScan(
    selected: Set<String>,
    completed: Set<String>
) -> Bool {
    !selected.isEmpty && !selected.isSubset(of: completed)
}

func reviewSelectionNeedsCurrentComparison(
    selected: Set<String>,
    completed: Set<String>,
    snapshot: Set<String>
) -> Bool {
    !selected.isEmpty
        && selected.isSubset(of: completed)
        && !selected.isSubset(of: snapshot)
}
