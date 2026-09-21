import AppKit

final class ContainerController {
    let browser: InstalledBrowser
    private let accessibility = AccessibilityController()
    private let shellPanel: NSPanel
    private let shellView: ContainerShellView
    private let tabPanel: NSPanel
    private let tabStrip: TabStripView
    private let resizeHandles: [ResizeHandleController]

    private(set) var windows: [BrowserWindow] = []
    private(set) var browserFrame: CGRect?
    private var selectedWindowID: CGWindowID?
    private var bottomWindowID: CGWindowID?
    private var stableWindowOrder: [CGWindowID] = []
    private var orderedProfileIDs: [CGWindowID: String] = [:]
    private var pendingAlignmentIDs = Set<CGWindowID>()
    private var pendingSelectionID: CGWindowID?
    private var pendingSelectionMatches = 0
    private var pendingSelectionDeadline = Date.distantPast
    private var lastOrderedSelectionID: CGWindowID?
    private var lastOrderedBrowserWasActive = false
    private var pendingInteractiveTilePlacement: PendingTilePlacement?
    private var recentPointerPlacementDeadline: Date?
    private var pointerDragWindowID: CGWindowID?
    private var pointerDragDeadline: Date?
    private var isVisible = false
    private var isManipulating = false

    init(browser: InstalledBrowser) {
        self.browser = browser
        shellView = ContainerShellView(frame: .zero)
        shellPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        shellPanel.isOpaque = false
        shellPanel.backgroundColor = .clear
        shellPanel.hasShadow = false
        shellPanel.hidesOnDeactivate = false
        shellPanel.ignoresMouseEvents = true
        shellPanel.level = .normal
        shellPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        shellPanel.isReleasedWhenClosed = false
        shellPanel.contentView = shellView

        tabPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tabPanel.isOpaque = false
        tabPanel.backgroundColor = .clear
        tabPanel.hasShadow = false
        tabPanel.hidesOnDeactivate = false
        tabPanel.ignoresMouseEvents = false
        tabPanel.becomesKeyOnlyIfNeeded = true
        tabPanel.acceptsMouseMovedEvents = true
        tabPanel.level = .normal
        tabPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        tabPanel.isReleasedWhenClosed = false

        tabStrip = TabStripView(browser: browser, frame: .zero)
        tabPanel.contentView = tabStrip

        resizeHandles = [
            ResizeHandleController(edge: .left),
            ResizeHandleController(edge: .right),
            ResizeHandleController(edge: .top),
            ResizeHandleController(edge: .bottom),
        ]

        tabStrip.onSelectWindow = { [weak self] id in
            self?.selectWindow(id)
        }
        tabStrip.onActivateBrowser = { [weak self] in
            guard let self, let window = self.selectedWindow else { return }
            self.accessibility.raise(window)
            self.show()
        }
        tabStrip.onMove = { [weak self] delta in
            self?.move(by: delta)
        }
        tabStrip.onMoveEnded = { [weak self] in
            self?.isManipulating = false
        }
        tabStrip.onReorderWindow = { [weak self] id, index in
            self?.reorderWindow(id, to: index)
        }
        for handle in resizeHandles {
            handle.onResize = { [weak self] edge, delta in
                self?.resize(edge: edge, by: delta)
            }
            handle.onResizeEnded = { [weak self] in
                self?.isManipulating = false
            }
        }
    }

    func update(windows newWindows: [BrowserWindow]) {
        let previouslyManagedWindowIDs = Set(windows.map(\.id))
        guard !newWindows.isEmpty else {
            windows = []
            browserFrame = nil
            bottomWindowID = nil
            stableWindowOrder = []
            orderedProfileIDs = [:]
            pendingAlignmentIDs = []
            pendingSelectionID = nil
            lastOrderedSelectionID = nil
            lastOrderedBrowserWasActive = false
            pendingInteractiveTilePlacement = nil
            recentPointerPlacementDeadline = nil
            pointerDragWindowID = nil
            pointerDragDeadline = nil
            hide()
            return
        }

        // Core Graphics reports windows front-to-back. Preserve that only
        // for native stacking and active-window detection; tab positions
        // must not change merely because a tab was selected.
        let frontmostWindowID = newWindows.first?.id
        bottomWindowID = newWindows.last?.id
        let liveWindowIDs = Set(newWindows.map(\.id))
        pendingAlignmentIDs.formIntersection(liveWindowIDs)
        stableWindowOrder.removeAll { !liveWindowIDs.contains($0) }
        for id in newWindows.map(\.id) where !stableWindowOrder.contains(id) {
            stableWindowOrder.append(id)
        }
        let resolvedProfiles = Dictionary(uniqueKeysWithValues: newWindows.compactMap { window in
            window.profile.map { (window.id, $0.id) }
        })
        let learnedProfile = resolvedProfiles.contains { orderedProfileIDs[$0.key] != $0.value }
        orderedProfileIDs = orderedProfileIDs.filter { liveWindowIDs.contains($0.key) }
        orderedProfileIDs.merge(resolvedProfiles) { _, new in new }
        if learnedProfile {
            let savedProfiles = AppSettings.shared.profileOrder(browser: browser.kind)
            let profileRanks = Dictionary(
                savedProfiles.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            stableWindowOrder = stableWindowOrder.enumerated().sorted { lhs, rhs in
                let leftRank = orderedProfileIDs[lhs.element].flatMap { profileRanks[$0] } ?? Int.max
                let rightRank = orderedProfileIDs[rhs.element].flatMap { profileRanks[$0] } ?? Int.max
                return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
            }.map(\.element)
        }
        let orderByID = Dictionary(
            uniqueKeysWithValues: stableWindowOrder.enumerated().map { ($0.element, $0.offset) }
        )
        windows = newWindows.sorted {
            orderByID[$0.id, default: .max] < orderByID[$1.id, default: .max]
        }

        if let browserFrame {
            pendingAlignmentIDs.formUnion(liveWindowIDs.subtracting(previouslyManagedWindowIDs))
            pendingAlignmentIDs.subtract(
                windows.lazy
                    .filter { $0.frame.distance(to: browserFrame) <= 3 }
                    .map(\.id)
            )
            alignPendingWindows(to: browserFrame)
        }

        if !isManipulating {
            if let pendingSelectionID,
               liveWindowIDs.contains(pendingSelectionID),
               Date() < pendingSelectionDeadline
            {
                selectedWindowID = pendingSelectionID
                pendingSelectionMatches = frontmostWindowID == pendingSelectionID
                    ? pendingSelectionMatches + 1 : 0
                // A single matching snapshot can precede a transient reordering
                // during browser activation. Require consecutive confirmations.
                if pendingSelectionMatches >= 3 {
                    self.pendingSelectionID = nil
                }
            } else if let pointerDragWindowID,
                      liveWindowIDs.contains(pointerDragWindowID),
                      pointerButtonIsDown
                      || Date() <= (pointerDragDeadline ?? .distantPast)
            {
                // External move/resize tools can briefly perturb the native
                // stacking order while dragging one grouped window. Keep the
                // drag source authoritative through the first post-release
                // geometry update, even when the complete drag occurred
                // between normal discovery polls.
                selectedWindowID = pointerDragWindowID
            } else if pointerButtonIsDown,
                      let selectedWindowID,
                      liveWindowIDs.contains(selectedWindowID)
            {
                self.selectedWindowID = selectedWindowID
            } else {
                pendingSelectionID = nil
                selectedWindowID = frontmostWindowID
            }
        } else if selectedWindowID == nil
            || !newWindows.contains(where: { $0.id == selectedWindowID })
        {
            selectedWindowID = newWindows.first?.id
        }

        let externalPointerDragIsActive = pointerDragWindowID != nil
            && pointerButtonIsDown
        if browserFrame == nil {
            let initialFrame = selectedWindow?.frame ?? newWindows[0].frame
            browserFrame = AppSettings.shared.tileManagerCompatibility
                && hasUpperTiledNeighbor(above: initialFrame)
                ? ContainerGeometry.browserFrame(fittingOuterFrame: initialFrame)
                : initialFrame
            alignAllWindows()
        } else if !isManipulating, !externalPointerDragIsActive, let selectedWindow {
            let current = browserFrame ?? selectedWindow.frame
            if pendingAlignmentIDs.contains(selectedWindow.id) {
                // Browser startup can report a transient default frame for
                // several polls. Keep retrying our frame without accepting
                // that transient geometry as the container's new position.
            } else if AppSettings.shared.tileManagerCompatibility,
                      shouldApplyPendingInteractiveTile(to: selectedWindow.frame)
            {
                browserFrame = ContainerGeometry.browserFrame(
                    fittingOuterFrame: selectedWindow.frame
                )
                pendingInteractiveTilePlacement = nil
                alignAllWindows()
            } else if current.distance(to: selectedWindow.frame) > 3 {
                let pointerPlacementIsActive = pointerButtonIsDown
                    || Date() <= (recentPointerPlacementDeadline ?? .distantPast)
                if pointerPlacementIsActive
                    || !AppSettings.shared.tileManagerCompatibility
                {
                    // Modifier-drag utilities can consume every mouse event,
                    // but the physical Quartz button state still identifies
                    // their position-only updates as pointer movement.
                    browserFrame = selectedWindow.frame
                } else {
                    // Keyboard-driven window managers assign the rectangle
                    // of the complete visual window. Keep the Transom tab
                    // strip inside that rectangle instead of above it.
                    browserFrame = ContainerGeometry.browserFrame(
                        fittingOuterFrame: selectedWindow.frame
                    )
                }
                alignAllWindows()
            }
        }

        tabStrip.update(windows: windows, selectedWindowID: selectedWindowID)
        positionChrome()
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            show()
        } else {
            hide()
        }
    }

    func rescanDidBegin() {
        isManipulating = false
    }

    func settingsDidChange() {
        shellView.applyTheme(AppSettings.shared.overlayTheme)
        tabStrip.applyTheme(AppSettings.shared.overlayTheme)
        lastOrderedSelectionID = nil
        positionChrome()
    }

    @discardableResult
    func pointerDragDidBegin(at screenLocation: CGPoint) -> Bool {
        guard let browserFrame, let selectedWindowID else { return false }
        let appKitBrowserFrame = ContainerGeometry.appKitRect(fromQuartz: browserFrame)
        let outerFrame = CGRect(
            x: appKitBrowserFrame.minX,
            y: appKitBrowserFrame.minY,
            width: appKitBrowserFrame.width,
            height: appKitBrowserFrame.height + ContainerGeometry.tabHeight
        )
        guard outerFrame.contains(screenLocation) else { return false }
        // A new placement gesture supersedes an earlier tab activation.
        // Otherwise discovery can select the old click target while BentoBox
        // assigns an outer frame to the window actually being dragged.
        pendingSelectionID = nil
        pendingSelectionMatches = 0
        pendingSelectionDeadline = .distantPast
        pointerDragWindowID = coreGraphicsBrowserWindowID(at: screenLocation)
            ?? selectedWindowID
        if let pointerDragWindowID {
            self.selectedWindowID = pointerDragWindowID
            pendingAlignmentIDs.remove(pointerDragWindowID)
        }
        pointerDragDeadline = .distantFuture
        return true
    }

    func followPointerDrag() {
        guard let pointerDragWindowID,
              let frame = coreGraphicsFrame(of: pointerDragWindowID)
        else {
            return
        }
        browserFrame = frame.integral
        positionChrome()
    }

    func notePointerPlacementEnded() {
        recentPointerPlacementDeadline = Date().addingTimeInterval(0.75)
        if let pointerDragWindowID {
            pointerDragDeadline = Date().addingTimeInterval(0.75)
            applyBrowserFrame(excluding: pointerDragWindowID)
        }
    }

    func expectInteractiveTilePlacement() {
        let deadline = Date().addingTimeInterval(1.5)
        if pendingInteractiveTilePlacement != nil {
            pendingInteractiveTilePlacement?.deadline = deadline
        } else if let browserFrame {
            pendingInteractiveTilePlacement = PendingTilePlacement(
                initialFrame: browserFrame,
                deadline: deadline
            )
        }
    }

    private var selectedWindow: BrowserWindow? {
        windows.first { $0.id == selectedWindowID }
    }

    private var pointerButtonIsDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
    }

    private func shouldApplyPendingInteractiveTile(to frame: CGRect) -> Bool {
        guard let pendingInteractiveTilePlacement else { return false }
        guard Date() <= pendingInteractiveTilePlacement.deadline else {
            self.pendingInteractiveTilePlacement = nil
            return false
        }
        guard !pointerButtonIsDown else { return false }
        return pendingInteractiveTilePlacement.initialFrame.distance(to: frame) > 3
    }

    private func selectWindow(_ id: CGWindowID) {
        guard let window = windows.first(where: { $0.id == id }) else {
            return
        }
        selectedWindowID = id
        pendingSelectionID = id
        pendingSelectionMatches = 0
        pendingSelectionDeadline = Date().addingTimeInterval(2)
        pointerDragWindowID = nil
        pointerDragDeadline = nil
        tabStrip.update(windows: windows, selectedWindowID: id)
        tabPanel.displayIfNeeded()
        CATransaction.flush()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingSelectionID == id else { return }
            self.accessibility.raise(window)
            self.show()
        }
    }

    private func reorderWindow(_ id: CGWindowID, to destination: Int) {
        guard let source = stableWindowOrder.firstIndex(of: id) else { return }
        stableWindowOrder.remove(at: source)
        stableWindowOrder.insert(id, at: min(destination, stableWindowOrder.count))
        let orderByID = Dictionary(
            uniqueKeysWithValues: stableWindowOrder.enumerated().map { ($0.element, $0.offset) }
        )
        windows.sort {
            orderByID[$0.id, default: .max] < orderByID[$1.id, default: .max]
        }
        AppSettings.shared.setProfileOrder(
            windows.compactMap { $0.profile?.id },
            browser: browser.kind
        )
        tabStrip.update(windows: windows, selectedWindowID: selectedWindowID)
    }

    private func move(by delta: CGPoint) {
        guard let frame = browserFrame else { return }
        isManipulating = true
        browserFrame = ContainerGeometry.moved(frame, byAppKitDelta: delta).integral
        applyBrowserFrame()
        positionChrome()
    }

    private func resize(edge: ResizeEdge, by delta: CGPoint) {
        guard let frame = browserFrame else { return }
        isManipulating = true
        browserFrame = ContainerGeometry.resized(frame, edge: edge, byAppKitDelta: delta)
        applyBrowserFrame()
        positionChrome()
    }

    private func alignAllWindows() {
        applyBrowserFrame()
    }

    private func alignPendingWindows(to frame: CGRect) {
        for window in windows where pendingAlignmentIDs.contains(window.id) {
            accessibility.setFrame(frame, of: window.element)
        }
    }

    private func applyBrowserFrame(excluding excludedWindowID: CGWindowID? = nil) {
        guard let browserFrame else { return }
        for window in windows
            where window.id != excludedWindowID && window.frame.distance(to: browserFrame) > 1 {
            accessibility.setFrame(browserFrame, of: window.element)
        }
    }

    private func hasUpperTiledNeighbor(above frame: CGRect) -> Bool {
        let managedWindowIDs = Set(windows.map(\.id))
        guard let dictionaries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        for dictionary in dictionaries {
            guard
                (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let id = (dictionary[kCGWindowNumber as String] as? NSNumber)
                .map({ CGWindowID($0.uint32Value) }),
                !managedWindowIDs.contains(id),
                (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != getpid(),
                let bounds = dictionary[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                width >= 200,
                height >= 160
            else {
                continue
            }
            let candidate = CGRect(x: x, y: y, width: width, height: height)
            let edgeGap = frame.minY - candidate.maxY
            let horizontalOverlap = max(
                0,
                min(frame.maxX, candidate.maxX) - max(frame.minX, candidate.minX)
            )
            let overlapRatio = horizontalOverlap / min(frame.width, candidate.width)
            if edgeGap >= 0, edgeGap <= 24, overlapRatio >= 0.8 {
                return true
            }
        }
        return false
    }

    private func coreGraphicsBrowserWindowID(at appKitPoint: CGPoint) -> CGWindowID? {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let quartzPoint = CGPoint(x: appKitPoint.x, y: primaryTop - appKitPoint.y)
        let managedWindowIDs = Set(windows.map(\.id))
        guard let dictionaries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        for dictionary in dictionaries {
            guard
                (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let id = (dictionary[kCGWindowNumber as String] as? NSNumber)
                .map({ CGWindowID($0.uint32Value) }),
                managedWindowIDs.contains(id),
                let bounds = dictionary[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                CGRect(x: x, y: y, width: width, height: height).contains(quartzPoint)
            else {
                continue
            }
            return id
        }
        return nil
    }

    private func coreGraphicsFrame(of windowID: CGWindowID) -> CGRect? {
        guard let dictionaries = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]],
            let dictionary = dictionaries.first,
            let bounds = dictionary[kCGWindowBounds as String] as? [String: Any],
            let x = (bounds["X"] as? NSNumber)?.doubleValue,
            let y = (bounds["Y"] as? NSNumber)?.doubleValue,
            let width = (bounds["Width"] as? NSNumber)?.doubleValue,
            let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func positionChrome() {
        guard let browserFrame else { return }
        let appKitBrowserFrame = ContainerGeometry.appKitRect(fromQuartz: browserFrame)
        let tabFrame = CGRect(
            x: appKitBrowserFrame.minX,
            y: appKitBrowserFrame.maxY,
            width: appKitBrowserFrame.width,
            height: ContainerGeometry.tabHeight
        )
        shellPanel.setFrame(
            CGRect(
                x: tabFrame.minX,
                y: tabFrame.minY - ContainerGeometry.tabOverlap,
                width: tabFrame.width,
                height: tabFrame.height + ContainerGeometry.tabOverlap
            ),
            display: true
        )
        tabPanel.setFrame(tabFrame, display: true)
        for handle in resizeHandles {
            handle.position(around: browserFrame)
        }
        if isVisible {
            show()
        }
    }

    private func show() {
        guard browserFrame != nil, let selectedWindowID, !windows.isEmpty else { return }
        let browserIsActive = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == selectedWindow?.pid
        guard lastOrderedSelectionID != selectedWindowID || !tabPanel.isVisible
            || browserIsActive != lastOrderedBrowserWasActive
        else {
            return
        }

        // The overlapping glass stays behind browser chrome. When inactive,
        // let intervening windows obscure it rather than cover the browser.
        let shellAnchorID = browserIsActive
            && AppSettings.shared.keepOverlayAboveInactiveWindows
            ? selectedWindowID
            : (bottomWindowID ?? selectedWindowID)
        shellPanel.order(.below, relativeTo: Int(shellAnchorID))
        tabPanel.order(.above, relativeTo: Int(selectedWindowID))
        for handle in resizeHandles {
            handle.panel.order(.above, relativeTo: Int(selectedWindowID))
        }
        lastOrderedSelectionID = selectedWindowID
        lastOrderedBrowserWasActive = browserIsActive
    }

    private func hide() {
        shellPanel.orderOut(nil)
        tabPanel.orderOut(nil)
        for handle in resizeHandles {
            handle.close()
        }
        lastOrderedSelectionID = nil
        lastOrderedBrowserWasActive = false
    }
}

private struct PendingTilePlacement {
    let initialFrame: CGRect
    var deadline: Date
}

private extension CGRect {
    func distance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX)
            + abs(minY - other.minY)
            + abs(width - other.width)
            + abs(height - other.height)
    }
}
