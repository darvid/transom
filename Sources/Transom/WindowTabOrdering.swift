import CoreGraphics

struct WindowTabOrdering: Equatable {
    var windowIDs: [CGWindowID]
    var profileIDsByWindowID: [CGWindowID: String]

    static func resolved(
        previousOrder: [CGWindowID],
        previousProfileIDs: [CGWindowID: String],
        liveWindowIDsInDiscoveryOrder: [CGWindowID],
        discoveredProfileIDs: [CGWindowID: String],
        savedProfileOrder: [String]
    ) -> WindowTabOrdering {
        let liveWindowIDs = Set(liveWindowIDsInDiscoveryOrder)
        let hadPreviousOrder = !previousOrder.isEmpty
        var nextOrder = previousOrder.filter { liveWindowIDs.contains($0) }
        for id in liveWindowIDsInDiscoveryOrder where !nextOrder.contains(id) {
            nextOrder.append(id)
        }

        var nextProfileIDs = previousProfileIDs.filter { liveWindowIDs.contains($0.key) }
        nextProfileIDs.merge(discoveredProfileIDs) { _, new in new }

        // Browser window discovery can resolve or revise profiles over several
        // polls. Re-sorting a visible strip on those discoveries makes tabs
        // shuffle and then snap back. Apply the saved profile order only before
        // a visible order exists; after that, keep tab positions stable unless
        // the user explicitly reorders them.
        if !hadPreviousOrder, liveWindowIDs.allSatisfy({ nextProfileIDs[$0] != nil }) {
            let profileRanks = Dictionary(
                savedProfileOrder.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            nextOrder = nextOrder.enumerated().sorted { lhs, rhs in
                let leftRank = nextProfileIDs[lhs.element].flatMap { profileRanks[$0] } ?? Int.max
                let rightRank = nextProfileIDs[rhs.element].flatMap { profileRanks[$0] } ?? Int.max
                return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
            }.map(\.element)
        }

        return WindowTabOrdering(
            windowIDs: nextOrder,
            profileIDsByWindowID: nextProfileIDs
        )
    }
}
