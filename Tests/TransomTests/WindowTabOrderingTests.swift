import Testing
@testable import Transom

struct WindowTabOrderingTests {
    @Test func partialProfileDiscoveryKeepsExistingOrder() {
        let ordering = WindowTabOrdering.resolved(
            previousOrder: [1, 2, 3],
            previousProfileIDs: [1: "personal"],
            liveWindowIDsInDiscoveryOrder: [1, 2, 3],
            discoveredProfileIDs: [3: "work"],
            savedProfileOrder: ["work", "personal", "school"]
        )

        #expect(ordering.windowIDs == [1, 2, 3])
        #expect(ordering.profileIDsByWindowID == [1: "personal", 3: "work"])
    }

    @Test func initialCompleteProfileDiscoveryUsesSavedProfileOrder() {
        let ordering = WindowTabOrdering.resolved(
            previousOrder: [],
            previousProfileIDs: [:],
            liveWindowIDsInDiscoveryOrder: [1, 2, 3],
            discoveredProfileIDs: [1: "personal", 2: "school", 3: "work"],
            savedProfileOrder: ["work", "personal", "school"]
        )

        #expect(ordering.windowIDs == [3, 1, 2])
        #expect(ordering.profileIDsByWindowID == [1: "personal", 2: "school", 3: "work"])
    }

    @Test func completedProfileDiscoveryKeepsVisibleOrder() {
        let ordering = WindowTabOrdering.resolved(
            previousOrder: [1, 2, 3],
            previousProfileIDs: [1: "personal", 3: "work"],
            liveWindowIDsInDiscoveryOrder: [1, 2, 3],
            discoveredProfileIDs: [2: "school"],
            savedProfileOrder: ["work", "personal", "school"]
        )

        #expect(ordering.windowIDs == [1, 2, 3])
        #expect(ordering.profileIDsByWindowID == [1: "personal", 2: "school", 3: "work"])
    }

    @Test func closedWindowsAreRemovedAndNewWindowsAppendInDiscoveryOrder() {
        let ordering = WindowTabOrdering.resolved(
            previousOrder: [1, 2, 3],
            previousProfileIDs: [1: "personal", 2: "school", 3: "work"],
            liveWindowIDsInDiscoveryOrder: [3, 4],
            discoveredProfileIDs: [4: "personal"],
            savedProfileOrder: ["work", "personal", "school"]
        )

        #expect(ordering.windowIDs == [3, 4])
        #expect(ordering.profileIDsByWindowID == [3: "work", 4: "personal"])
    }
}
