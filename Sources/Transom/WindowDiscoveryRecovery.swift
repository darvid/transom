import Foundation
import CoreGraphics

struct WindowIdentity: Hashable {
    let id: CGWindowID
    let pid: pid_t
    let browser: BrowserKind

    init(id: CGWindowID, pid: pid_t, browser: BrowserKind) {
        self.id = id
        self.pid = pid
        self.browser = browser
    }

    init(_ window: BrowserWindow) {
        self.init(id: window.id, pid: window.pid, browser: window.browser.kind)
    }
}

struct WindowDiscoveryRecovery {
    struct VisibleWindow {
        let identity: WindowIdentity
        let frame: CGRect
    }

    private struct Entry {
        let window: BrowserWindow
        let observedAt: TimeInterval
    }

    var gracePeriod: TimeInterval = 1
    private var entries: [WindowIdentity: Entry] = [:]
    private var lastVisibleWindows: [VisibleWindow] = []
    private(set) var retainedCount = 0
    private(set) var expiredCount = 0

    var cachedIdentities: Set<WindowIdentity> { Set(entries.keys) }

    mutating func resolve(
        visibleWindows: [VisibleWindow]?,
        observed: [BrowserWindow],
        now: TimeInterval
    ) -> [BrowserWindow] {
        // nil means the system snapshot failed; [] confirms no visible windows.
        if let visibleWindows {
            lastVisibleWindows = visibleWindows
            let visibleIDs = Set(visibleWindows.map(\.identity))
            entries = entries.filter { visibleIDs.contains($0.key) }
        }
        let observedIDs = Set(observed.map(WindowIdentity.init))
        for window in observed {
            entries[WindowIdentity(window)] = Entry(window: window, observedAt: now)
        }
        retainedCount = 0
        expiredCount = 0
        return lastVisibleWindows.compactMap { visible in
            guard let entry = entries[visible.identity] else { return nil }
            if observedIDs.contains(visible.identity) { return entry.window }
            guard now - entry.observedAt <= gracePeriod else {
                expiredCount += 1
                return nil
            }
            retainedCount += 1
            let window = entry.window
            // Retention never renews the deadline. Use the current WindowServer
            // frame during AX outages so the overlay can still follow a drag.
            return BrowserWindow(
                id: window.id, pid: window.pid, browser: window.browser,
                title: window.title, profile: window.profile,
                frame: visible.frame, element: window.element
            )
        }
    }
}
