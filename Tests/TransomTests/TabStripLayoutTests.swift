import AppKit
import Testing
@testable import Transom

struct TabStripLayoutTests {
    @Test func naturalWidthsAreKeptWhenTabsFit() {
        let layout = TabStripLayout.compute(
            naturalWidths: [100, 150, 60, 400],
            selectedIndex: 0,
            ghostWidths: [],
            availableWidth: 1000,
            overflowReservedWidth: 50
        )
        #expect(layout.visible.map(\.width) == [100, 150, 96, 180])
        #expect(layout.overflow.isEmpty)
    }

    @Test func tightRowsShrinkWiderTabsFirst() {
        let layout = TabStripLayout.compute(
            naturalWidths: [100, 180, 180],
            selectedIndex: 0,
            ghostWidths: [],
            availableWidth: 400,
            overflowReservedWidth: 50
        )
        let widths = layout.visible.map(\.width)
        #expect(widths[0] == 100)
        #expect(widths[1] == widths[2])
        #expect(widths.allSatisfy { $0 >= TabStripLayout.minimumTabWidth })
        #expect(widths.reduce(0, +) + 2 * TabStripLayout.spacing <= 400)
        #expect(layout.overflow.isEmpty)
    }

    @Test func overflowKeepsSelectedTabVisible() {
        let layout = TabStripLayout.compute(
            naturalWidths: Array(repeating: 150, count: 9),
            selectedIndex: 7,
            ghostWidths: [120],
            availableWidth: 400,
            overflowReservedWidth: 60
        )
        #expect(layout.visible.map(\.index) == [0, 1, 7])
        #expect(layout.overflow == [2, 3, 4, 5, 6, 8])
        #expect(layout.ghosts.isEmpty)
        #expect(layout.visible.allSatisfy { $0.width >= TabStripLayout.minimumTabWidth })
    }

    @Test func ghostsFillOnlyRemainingSpace() {
        let layout = TabStripLayout.compute(
            naturalWidths: [120, 120],
            selectedIndex: 1,
            ghostWidths: [110, 110, 110],
            availableWidth: 480,
            overflowReservedWidth: 50
        )
        #expect(layout.overflow.isEmpty)
        #expect(layout.ghosts.map(\.index) == [0, 1])
    }

    @Test func duplicateProfilesAreNumberedAndUnknownWindowsNamed() {
        let personal = BrowserProfile(id: "Default", name: "Personal", color: .systemPink, directory: nil)
        let work = BrowserProfile(id: "Profile 1", name: "Work", color: .systemBlue, directory: nil)
        let labels = TabStripLayout.labels(for: [personal, work, nil, personal])
        #expect(labels == ["Personal", "Work", "Window 3", "Personal 2"])
    }
}
