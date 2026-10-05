import CoreGraphics

struct TabStripLayout: Equatable {
    struct Slot: Equatable {
        let index: Int
        let width: CGFloat
    }

    static let minimumTabWidth: CGFloat = 96
    static let maximumTabWidth: CGFloat = 180
    static let spacing: CGFloat = 3

    var visible: [Slot]
    var overflow: [Int]
    var ghosts: [Slot]

    static func compute(
        naturalWidths: [CGFloat],
        selectedIndex: Int?,
        ghostWidths: [CGFloat],
        availableWidth: CGFloat,
        overflowReservedWidth: CGFloat
    ) -> TabStripLayout {
        let natural = naturalWidths.map(clamped)
        var visibleIndices = Array(natural.indices)
        var overflow: [Int] = []
        var tabArea = availableWidth

        if minimumRowWidth(count: natural.count) > availableWidth {
            tabArea = max(0, availableWidth - overflowReservedWidth)
            let fit = max(1, Int(floor((tabArea + spacing) / (minimumTabWidth + spacing))))
            visibleIndices = Array(natural.indices.prefix(fit))
            if let selectedIndex, natural.indices.contains(selectedIndex),
               !visibleIndices.contains(selectedIndex), !visibleIndices.isEmpty
            {
                visibleIndices[visibleIndices.count - 1] = selectedIndex
            }
            overflow = natural.indices.filter { !visibleIndices.contains($0) }
        }

        let widths = fittedWidths(visibleIndices.map { natural[$0] }, into: tabArea)
        let visible = zip(visibleIndices, widths).map { Slot(index: $0, width: $1) }

        var ghosts: [Slot] = []
        if overflow.isEmpty {
            var used = rowWidth(widths)
            for (index, width) in ghostWidths.map(clamped).enumerated() {
                let needed = (used > 0 ? spacing : 0) + width
                guard used + needed <= availableWidth else { break }
                ghosts.append(Slot(index: index, width: width))
                used += needed
            }
        }
        return TabStripLayout(visible: visible, overflow: overflow, ghosts: ghosts)
    }

    static func labels(for profiles: [BrowserProfile?]) -> [String] {
        var occurrences: [String: Int] = [:]
        let totals = Dictionary(profiles.compactMap { $0?.id }.map { ($0, 1) }, uniquingKeysWith: +)
        return profiles.enumerated().map { index, profile in
            guard let profile else { return "Window \(index + 1)" }
            let occurrence = (occurrences[profile.id] ?? 0) + 1
            occurrences[profile.id] = occurrence
            guard (totals[profile.id] ?? 0) > 1, occurrence > 1 else {
                return profile.displayName
            }
            return "\(profile.displayName) \(occurrence)"
        }
    }

    private static func clamped(_ width: CGFloat) -> CGFloat {
        min(maximumTabWidth, max(minimumTabWidth, ceil(width)))
    }

    private static func minimumRowWidth(count: Int) -> CGFloat {
        CGFloat(count) * minimumTabWidth + CGFloat(max(0, count - 1)) * spacing
    }

    private static func rowWidth(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * spacing
    }

    private static func fittedWidths(_ widths: [CGFloat], into available: CGFloat) -> [CGFloat] {
        guard rowWidth(widths) > available else { return widths }
        var remaining = available - CGFloat(max(0, widths.count - 1)) * spacing
        var remainingCount = widths.count
        var cap = minimumTabWidth
        for width in widths.sorted() {
            let share = remaining / CGFloat(remainingCount)
            if width <= share {
                remaining -= width
                remainingCount -= 1
            } else {
                cap = share
                break
            }
        }
        cap = max(minimumTabWidth, floor(cap))
        return widths.map { min($0, cap) }
    }
}
