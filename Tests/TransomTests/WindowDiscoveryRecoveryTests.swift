import AppKit
import ApplicationServices
import Testing
@testable import Transom

struct WindowDiscoveryRecoveryTests {
    @Test func temporaryFailureKeepsIdentityAndTracksVisibleFrame() throws {
        let window = sampleWindow()
        var recovery = WindowDiscoveryRecovery()
        _ = recovery.resolve(visibleWindows: [visible(window)], observed: [window], now: 10)
        let movedFrame = CGRect(x: 100, y: 150, width: 900, height: 600)
        let retained = try #require(recovery.resolve(
            visibleWindows: [.init(identity: WindowIdentity(window), frame: movedFrame)],
            observed: [], now: 10.2
        ).first)
        #expect(retained.id == window.id)
        #expect(retained.profile == window.profile)
        #expect(retained.frame == movedFrame)
        #expect(CFEqual(retained.element, window.element))
        #expect(recovery.retainedCount == 1)
    }

    @Test func repeatedFailuresCannotExtendGracePeriod() {
        let window = sampleWindow()
        var recovery = WindowDiscoveryRecovery()
        _ = recovery.resolve(visibleWindows: [visible(window)], observed: [window], now: 10)
        #expect(recovery.resolve(visibleWindows: [visible(window)], observed: [], now: 10.9).count == 1)
        #expect(recovery.resolve(visibleWindows: [visible(window)], observed: [], now: 11.1).isEmpty)
        #expect(recovery.expiredCount == 1)
        #expect(recovery.resolve(visibleWindows: [visible(window)], observed: [window], now: 11.2).count == 1)
        #expect(recovery.expiredCount == 0)
        #expect(recovery.resolve(visibleWindows: [visible(window)], observed: [], now: 11.3).count == 1)
    }

    @Test func confirmedAbsenceDropsCacheImmediately() {
        let window = sampleWindow()
        var recovery = WindowDiscoveryRecovery()
        _ = recovery.resolve(visibleWindows: [visible(window)], observed: [window], now: 10)
        // Closed, minimized, or off-Space windows disappear from the visible list.
        #expect(recovery.resolve(visibleWindows: [], observed: [], now: 10.1).isEmpty)
        #expect(recovery.resolve(visibleWindows: [visible(window)], observed: [], now: 10.2).isEmpty)
    }

    @Test func missingSystemSnapshotIsBoundedAndPreservesStackOrder() {
        let first = sampleWindow(id: 1)
        let second = sampleWindow(id: 2)
        var recovery = WindowDiscoveryRecovery()
        let initial = recovery.resolve(visibleWindows: [visible(second), visible(first)],
                                       observed: [first, second], now: 10)
        #expect(initial.map(\.id) == [2, 1])
        #expect(recovery.resolve(visibleWindows: nil, observed: [], now: 10.2).map(\.id) == [2, 1])
        #expect(recovery.resolve(visibleWindows: nil, observed: [], now: 11.1).isEmpty)
    }

    @Test func differentProcessCannotInheritCachedWindow() {
        let original = sampleWindow(pid: 101)
        let reusedID = sampleWindow(pid: 102)
        var recovery = WindowDiscoveryRecovery()
        _ = recovery.resolve(visibleWindows: [visible(original)], observed: [original], now: 10)
        #expect(recovery.resolve(visibleWindows: [visible(reusedID)], observed: [], now: 10.1).isEmpty)
    }

    private func visible(_ window: BrowserWindow) -> WindowDiscoveryRecovery.VisibleWindow {
        .init(identity: WindowIdentity(window), frame: window.frame)
    }

    private func sampleWindow(id: CGWindowID = 1, pid: pid_t = 101) -> BrowserWindow {
        let profile = BrowserProfile(id: "Default", name: "Synthetic", color: .blue, directory: nil)
        let root = URL(fileURLWithPath: "/synthetic/browser")
        let browser = InstalledBrowser(kind: .chrome, family: .chromium, bundleIdentifier: "test.browser",
                                       applicationURL: root, executableURL: root, profileRoot: root, profiles: [profile])
        return BrowserWindow(id: id, pid: pid, browser: browser, title: "Synthetic",
                             profile: profile, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                             element: AXUIElementCreateApplication(pid))
    }
}
