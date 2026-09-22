import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

final class BrowserWindowDiscovery {
    let registry: BrowserRegistry
    private let accessibility = AccessibilityController()
    private var profileAssignments: [WindowIdentity: BrowserProfile] = [:]
    private var contentWindowIdentities = Set<WindowIdentity>()
    private var recovery = WindowDiscoveryRecovery()
    private let logger = Logger(subsystem: "com.transom.app", category: "WindowDiscovery")
    private var lastDiagnostic = ""

    init(registry: BrowserRegistry = BrowserRegistry()) {
        self.registry = registry
    }

    func refreshBrowsers() {
        registry.refresh()
        var refreshedAssignments: [WindowIdentity: BrowserProfile] = [:]
        for (identity, profile) in profileAssignments {
            if let refreshed = registry.browsers
                .first(where: { $0.kind == identity.browser })?
                .profiles.first(where: { $0.id == profile.id })
            {
                refreshedAssignments[identity] = refreshed
            }
        }
        profileAssignments = refreshedAssignments
    }

    func discover() -> [BrowserWindow] {
        guard accessibility.isTrusted else {
            recovery = WindowDiscoveryRecovery()
            profileAssignments.removeAll()
            contentWindowIdentities.removeAll()
            logTransition("Accessibility permission unavailable")
            return []
        }

        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let rawWindows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            let windows = recovery.resolve(
                visibleWindows: nil, observed: [], now: ProcessInfo.processInfo.systemUptime
            )
            logTransition("WindowServer snapshot failed; retained=\(recovery.retainedCount), expired=\(recovery.expiredCount)")
            return windows
        }

        var candidates = rawWindows.compactMap(candidate(from:))
        let listedIDs = Set(candidates.map {
            WindowIdentity(id: $0.id, pid: $0.pid, browser: $0.browser.kind)
        })
        let missingIDs = recovery.cachedIdentities.subtracting(listedIDs)
        if !missingIDs.isEmpty {
            // The on-screen-only snapshot can omit a window for one poll.
            // Corroborate removals with an independent full WindowServer list;
            // never restore windows explicitly marked off-screen or minimized.
            if let fullList = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] {
                let corroborated = fullList.filter {
                    ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
                }.compactMap(candidate(from:))
                let recovered = corroborated.filter {
                    missingIDs.contains(WindowIdentity(id: $0.id, pid: $0.pid, browser: $0.browser.kind))
                }
                if !recovered.isEmpty {
                    let byID = Dictionary(uniqueKeysWithValues: (candidates + recovered).map { ($0.id, $0) })
                    // Preserve the full snapshot's front-to-back order when
                    // repairing the fast snapshot, not the recovery order.
                    let orderedIDs = fullList.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
                    candidates = orderedIDs.compactMap { byID[$0] }
                    logger.notice("Repaired visible-window snapshot: omitted=\(missingIDs.count), recovered=\(recovered.count)")
                } else {
                    logger.notice("WindowServer confirms missing candidates: missing=\(missingIDs.count), rawOnScreen=\(rawWindows.count), rawAll=\(fullList.count)")
                }
            } else {
                // Both sources are uncertain. Apply the bounded recovery path
                // instead of treating an unconfirmed absence as a closure.
                let windows = recovery.resolve(visibleWindows: nil, observed: [], now: ProcessInfo.processInfo.systemUptime)
                logTransition("WindowServer confirmation failed; retained=\(recovery.retainedCount), expired=\(recovery.expiredCount)")
                return windows
            }
        }
        let candidatesByPID = Dictionary(grouping: candidates, by: \.pid)
        var result: [BrowserWindow] = []
        let visibleWindows = candidates.map {
            WindowDiscoveryRecovery.VisibleWindow(
                identity: WindowIdentity(id: $0.id, pid: $0.pid, browser: $0.browser.kind), frame: $0.frame
            )
        }
        let liveIdentities = Set(visibleWindows.map(\.identity))

        for (pid, processCandidates) in candidatesByPID {
            let elements = accessibility.windows(for: pid)
            let elementByWindowID = matchingElements(
                for: processCandidates,
                in: elements
            )
            guard let browser = processCandidates.first?.browser else { continue }
            let argumentProfile = ProcessArguments.profile(
                from: ProcessArguments.arguments(for: pid),
                browser: browser
            )
            let canUseArgumentProfile = browser.family == .firefox
                || processCandidates.count == 1

            for candidate in processCandidates {
                guard let element = elementByWindowID[candidate.id] else { continue }
                let identity = WindowIdentity(
                    id: candidate.id,
                    pid: pid,
                    browser: browser.kind
                )
                guard accessibility.document(of: element) != nil
                    || contentWindowIdentities.contains(identity)
                else {
                    continue
                }
                contentWindowIdentities.insert(identity)

                let accessibilityTitle = accessibility.title(of: element)
                let title = accessibilityTitle.isEmpty
                    ? candidate.title
                    : accessibilityTitle
                let profile = BrowserProfileLoader.matchingProfile(
                    forWindowTitle: title,
                    in: browser.profiles
                ) ?? BrowserProfileLoader.matchingProfile(
                    forWindowTitle: candidate.title,
                    in: browser.profiles
                ) ?? profileAssignments[identity]
                    ?? (canUseArgumentProfile ? argumentProfile : nil)
                    ?? (browser.profiles.count == 1 ? browser.profiles[0] : nil)
                if let profile {
                    profileAssignments[identity] = profile
                }

                result.append(
                    BrowserWindow(
                        id: candidate.id,
                        pid: pid,
                        browser: browser,
                        title: title,
                        profile: profile,
                        frame: accessibility.frame(of: element) ?? candidate.frame,
                        element: element
                    )
                )
            }
        }

        profileAssignments = profileAssignments.filter {
            liveIdentities.contains($0.key)
        }
        contentWindowIdentities.formIntersection(liveIdentities)

        let windows = recovery.resolve(
            visibleWindows: visibleWindows, observed: result, now: ProcessInfo.processInfo.systemUptime
        )
        logTransition("Visible candidates=\(candidates.count), matched=\(result.count), retained=\(recovery.retainedCount), expired=\(recovery.expiredCount)")
        return windows
    }

    private func logTransition(_ diagnostic: String) {
        guard diagnostic != lastDiagnostic else { return }
        lastDiagnostic = diagnostic
        logger.notice("\(diagnostic, privacy: .public)")
    }

    private func candidate(from dictionary: [String: Any]) -> BrowserWindowCandidate? {
        guard
            (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let pidNumber = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
            let idNumber = dictionary[kCGWindowNumber as String] as? NSNumber,
            let bounds = dictionary[kCGWindowBounds as String] as? [String: Any],
            let x = (bounds["X"] as? NSNumber)?.doubleValue,
            let y = (bounds["Y"] as? NSNumber)?.doubleValue,
            let width = (bounds["Width"] as? NSNumber)?.doubleValue,
            let height = (bounds["Height"] as? NSNumber)?.doubleValue,
            width >= 200,
            height >= 160
        else {
            return nil
        }

        let pid = pid_t(pidNumber.int32Value)
        guard
            pid != getpid(),
            let runningApplication = NSRunningApplication(processIdentifier: pid),
            let browser = registry.browser(for: runningApplication)
        else {
            return nil
        }

        return BrowserWindowCandidate(
            id: CGWindowID(idNumber.uint32Value),
            pid: pid,
            browser: browser,
            title: dictionary[kCGWindowName as String] as? String ?? "",
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func matchingElements(
        for candidates: [BrowserWindowCandidate],
        in elements: [AXUIElement]
    ) -> [CGWindowID: AXUIElement] {
        var result: [CGWindowID: AXUIElement] = [:]
        var usedElements = Set<CFHashCode>()

        func assign(_ element: AXUIElement, to candidate: BrowserWindowCandidate) {
            result[candidate.id] = element
            usedElements.insert(CFHash(element))
        }

        func isAvailable(_ element: AXUIElement) -> Bool {
            !usedElements.contains(CFHash(element))
        }

        for candidate in candidates {
            if let element = elements.first(where: {
                isAvailable($0) && accessibility.windowNumber(of: $0) == candidate.id
            }) {
                assign(element, to: candidate)
            }
        }

        for candidate in candidates where result[candidate.id] == nil {
            guard !candidate.title.isEmpty else { continue }
            if let element = elements.first(where: {
                isAvailable($0) && accessibility.title(of: $0) == candidate.title
            }) {
                assign(element, to: candidate)
            }
        }

        for candidate in candidates where result[candidate.id] == nil {
            let nearest = elements
                .filter(isAvailable)
                .compactMap { element -> (AXUIElement, CGFloat)? in
                    guard let frame = accessibility.frame(of: element) else { return nil }
                    let distance = abs(frame.minX - candidate.frame.minX)
                        + abs(frame.minY - candidate.frame.minY)
                        + abs(frame.width - candidate.frame.width)
                        + abs(frame.height - candidate.frame.height)
                    return (element, distance)
                }
                .filter { $0.1 <= 12 }
                .min { $0.1 < $1.1 }
            if let nearest {
                assign(nearest.0, to: candidate)
            }
        }

        return result
    }
}

private struct BrowserWindowCandidate {
    let id: CGWindowID
    let pid: pid_t
    let browser: InstalledBrowser
    let title: String
    let frame: CGRect
}
