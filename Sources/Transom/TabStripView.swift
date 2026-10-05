import AppKit

final class TabStripView: NSView {
    var onSelectWindow: ((CGWindowID) -> Void)?
    var onActivateBrowser: (() -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    var onReorderWindow: ((CGWindowID, Int) -> Void)?
    var onCloseWindow: ((CGWindowID) -> Void)?
    var onOpenProfile: ((BrowserProfile?) -> Void)?

    private static let leadingInset: CGFloat = 12
    private static let trailingInset: CGFloat = 10
    private static let iconSize: CGFloat = 26
    private static let iconSpacing: CGFloat = 6
    private static let accessorySpacing: CGFloat = 6
    private static let accessorySize: CGFloat = 26
    private static let tabHeight: CGFloat = 30

    private struct TabModel: Equatable {
        let id: CGWindowID
        let label: String
        let title: String
        let colorHex: String?
    }

    private struct GhostModel: Equatable {
        let id: String
        let label: String
        let colorHex: String?
    }

    private let browser: InstalledBrowser
    private let menuButton: StripButton
    private let tabRow = TabRowView()
    private let overflowButton = StripButton(content: .overflow(0))
    private let newWindowButton = StripButton(content: .plus)
    private var windowTabs: [TabButton] = []
    private var ghostTabs: [TabButton] = []
    private var tabModels: [TabModel] = []
    private var ghostModels: [GhostModel] = []
    private var launchProfiles: [BrowserProfile?] = []
    private var launchBrowser: InstalledBrowser
    private var selectedWindowID: CGWindowID?
    private var overflowWindowIDs: [CGWindowID] = []
    private var slotFrames: [CGWindowID: CGRect] = [:]
    private var theme = AppSettings.shared.overlayTheme
    private var isBrowserActive = true
    private var draggedWindowID: CGWindowID?
    private var dragGrabOffset: CGFloat = 0
    private var draggedOriginX: CGFloat = 0
    private var lastDragLocation: CGPoint?

    init(browser: InstalledBrowser, frame frameRect: NSRect) {
        self.browser = browser
        launchBrowser = browser
        menuButton = StripButton(content: .appIcon(NSWorkspace.shared.icon(forFile: browser.applicationURL.path)))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        menu = contextMenu()

        menuButton.accessibilityName = "\(browser.displayName) Menu"
        menuButton.toolTip = "Transom"
        menuButton.onPress = { [weak self] button in
            guard let self else { return }
            popUp(contextMenu(), from: button)
        }
        overflowButton.accessibilityName = "More Windows"
        overflowButton.onPress = { [weak self] button in
            guard let self else { return }
            popUp(overflowMenu(), from: button)
        }
        newWindowButton.accessibilityName = "New Window"
        newWindowButton.toolTip = "New Window"
        newWindowButton.onPress = { [weak self] button in
            guard let self else { return }
            popUp(newWindowMenu(), from: button)
        }

        addSubview(menuButton)
        addSubview(tabRow)
        addSubview(overflowButton)
        addSubview(newWindowButton)
        overflowButton.isHidden = true
        newWindowButton.isHidden = true
        applyTheme(theme)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func applyTheme(_ theme: OverlayTheme) {
        self.theme = theme
        switch theme {
        case .automatic:
            appearance = nil
        case .light, .catppuccinLatte:
            appearance = NSAppearance(named: .aqua)
        case .black, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha:
            appearance = NSAppearance(named: .darkAqua)
        }
        for button in [menuButton, overflowButton, newWindowButton] {
            button.theme = theme
        }
        for tab in windowTabs + ghostTabs {
            tab.theme = theme
        }
        needsDisplay = true
    }

    func setBrowserActive(_ isActive: Bool) {
        guard isActive != isBrowserActive else { return }
        isBrowserActive = isActive
        for tab in windowTabs + ghostTabs {
            tab.isBrowserActive = isActive
        }
        for button in [menuButton, overflowButton, newWindowButton] {
            button.alphaValue = isActive ? 1 : 0.6
        }
    }

    func update(windows: [BrowserWindow], selectedWindowID: CGWindowID?) {
        let currentBrowser = windows.first?.browser ?? browser
        let labels = TabStripLayout.labels(for: windows.map(\.profile))
        let models = zip(windows, labels).map { window, label in
            TabModel(id: window.id, label: label, title: window.title, colorHex: window.profile?.displayColor.hexRGB)
        }
        let openProfileIDs = Set(windows.compactMap { $0.profile?.id })
        let choices = ProfileChoice.pickerChoices(for: [currentBrowser])
        let profiles = choices.map(\.profile)
        let ghostProfiles = profiles.compactMap { $0 }.filter { !openProfileIDs.contains($0.id) }
        let ghosts = ghostProfiles.map {
            GhostModel(id: $0.id, label: $0.displayName, colorHex: $0.displayColor.hexRGB)
        }

        launchBrowser = currentBrowser
        launchProfiles = profiles
        var needsLayout = false
        if models != tabModels {
            rebuildWindowTabs(models: models, windows: windows)
            needsLayout = true
        }
        if ghosts != ghostModels {
            rebuildGhostTabs(models: ghosts, profiles: ghostProfiles)
            needsLayout = true
        }
        if newWindowButton.isHidden != profiles.isEmpty {
            newWindowButton.isHidden = profiles.isEmpty
            needsLayout = true
        }

        if selectedWindowID != self.selectedWindowID {
            self.selectedWindowID = selectedWindowID
            for tab in windowTabs {
                tab.isSelected = tab.windowID == selectedWindowID
            }
            needsLayout = true
        }

        guard needsLayout else { return }
        layoutTabs(animated: window != nil)
        updateAccessibilityPositions()
        displayIfNeeded()
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            layoutTabs(animated: false)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = NSEvent.mouseLocation
        onActivateBrowser?()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        guard let previous = lastDragLocation else {
            lastDragLocation = location
            return
        }
        let delta = CGPoint(x: location.x - previous.x, y: location.y - previous.y)
        lastDragLocation = location
        onMove?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        onMoveEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard windowTabs.count > 1 else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        guard event.phase == .began || (event.phase == [] && event.momentumPhase == []), delta != 0 else {
            return
        }
        let currentIndex = windowTabs.firstIndex { $0.windowID == selectedWindowID } ?? 0
        let step = delta > 0 ? -1 : 1
        let nextIndex = (currentIndex + step + windowTabs.count) % windowTabs.count
        if let id = windowTabs[nextIndex].windowID {
            onSelectWindow?(id)
        }
    }

    // MARK: - Tabs

    private func rebuildWindowTabs(models: [TabModel], windows: [BrowserWindow]) {
        var existing = Dictionary(uniqueKeysWithValues: windowTabs.compactMap { tab in
            tab.windowID.map { ($0, tab) }
        })
        windowTabs = zip(models, windows).map { model, window in
            let tab = existing.removeValue(forKey: model.id) ?? makeWindowTab(id: model.id)
            tab.label = model.label
            tab.color = window.profile?.displayColor ?? .tertiaryLabelColor
            tab.toolTip = model.title.isEmpty ? model.label : model.title
            tab.isSelected = model.id == selectedWindowID
            return tab
        }
        for tab in existing.values {
            tab.removeFromSuperview()
        }
        tabModels = models
        if let draggedWindowID, !models.contains(where: { $0.id == draggedWindowID }) {
            self.draggedWindowID = nil
        }
    }

    private func rebuildGhostTabs(models: [GhostModel], profiles: [BrowserProfile]) {
        for tab in ghostTabs {
            tab.removeFromSuperview()
        }
        ghostTabs = zip(models, profiles).map { model, profile in
            let tab = TabButton(windowID: nil)
            tab.label = model.label
            tab.color = profile.displayColor
            tab.toolTip = "Open \(model.label)"
            tab.theme = theme
            tab.isBrowserActive = isBrowserActive
            tab.onPress = { [weak self] in
                self?.onOpenProfile?(profile)
            }
            tab.menu = menu
            tab.isHidden = true
            tabRow.addSubview(tab)
            return tab
        }
        ghostModels = models
    }

    private func makeWindowTab(id: CGWindowID) -> TabButton {
        let tab = TabButton(windowID: id)
        tab.theme = theme
        tab.isBrowserActive = isBrowserActive
        tab.menu = menu
        tab.isHidden = true
        tab.onPress = { [weak self] in
            self?.onSelectWindow?(id)
        }
        tab.onClose = { [weak self] in
            self?.onCloseWindow?(id)
        }
        tab.onDragBegan = { [weak self, weak tab] grabOffset in
            guard let self, let tab else { return }
            beginDrag(tab, id: id, grabOffset: grabOffset)
        }
        tab.onDragMoved = { [weak self] location in
            self?.moveDrag(id: id, windowLocation: location)
        }
        tab.onDragEnded = { [weak self] in
            self?.endDrag(id: id)
        }
        tabRow.addSubview(tab)
        return tab
    }

    private func layoutTabs(animated: Bool) {
        let height = bounds.height
        menuButton.frame = CGRect(
            x: Self.leadingInset, y: (height - Self.iconSize) / 2,
            width: Self.iconSize, height: Self.iconSize
        )
        var trailing = bounds.width - Self.trailingInset
        if !newWindowButton.isHidden {
            newWindowButton.frame = CGRect(
                x: trailing - Self.accessorySize, y: (height - Self.accessorySize) / 2,
                width: Self.accessorySize, height: Self.accessorySize
            )
            trailing -= Self.accessorySize + Self.accessorySpacing
        }

        let rowX = menuButton.frame.maxX + Self.iconSpacing
        let available = max(0, trailing - rowX)
        let overflowWidth = StripButton.overflowWidth(count: windowTabs.count)
        let layout = TabStripLayout.compute(
            naturalWidths: windowTabs.map(\.naturalWidth),
            selectedIndex: windowTabs.firstIndex { $0.windowID == selectedWindowID },
            ghostWidths: ghostTabs.map(\.naturalWidth),
            availableWidth: available,
            overflowReservedWidth: overflowWidth + Self.accessorySpacing
        )
        tabRow.frame = CGRect(x: rowX, y: 0, width: available, height: height)

        overflowWindowIDs = layout.overflow.compactMap { windowTabs[$0].windowID }
        overflowButton.isHidden = overflowWindowIDs.isEmpty
        if !overflowButton.isHidden {
            overflowButton.content = .overflow(overflowWindowIDs.count)
            overflowButton.toolTip = "\(overflowWindowIDs.count) more windows"
            overflowButton.frame = CGRect(
                x: trailing - overflowWidth, y: (height - Self.accessorySize) / 2,
                width: overflowWidth, height: Self.accessorySize
            )
        }

        let tabY = (height - Self.tabHeight) / 2
        var x: CGFloat = 0
        var placed = Set<ObjectIdentifier>()
        slotFrames = [:]
        for slot in layout.visible {
            let tab = windowTabs[slot.index]
            let frame = CGRect(x: x, y: tabY, width: slot.width, height: Self.tabHeight)
            if let id = tab.windowID {
                slotFrames[id] = frame
            }
            if tab.windowID != nil, tab.windowID == draggedWindowID {
                let maxX = max(0, available - frame.width)
                tab.frame = CGRect(
                    x: min(maxX, max(0, draggedOriginX)), y: tabY,
                    width: frame.width, height: Self.tabHeight
                )
                tab.isHidden = false
            } else {
                place(tab, at: frame, animated: animated)
            }
            placed.insert(ObjectIdentifier(tab))
            x = frame.maxX + TabStripLayout.spacing
        }
        for slot in layout.ghosts {
            let tab = ghostTabs[slot.index]
            place(tab, at: CGRect(x: x, y: tabY, width: slot.width, height: Self.tabHeight), animated: animated)
            placed.insert(ObjectIdentifier(tab))
            x += slot.width + TabStripLayout.spacing
        }
        for tab in windowTabs + ghostTabs where !placed.contains(ObjectIdentifier(tab)) {
            tab.isHidden = true
        }
    }

    private func place(_ tab: TabButton, at frame: CGRect, animated: Bool) {
        guard animated, !tab.isHidden, tab.frame != .zero else {
            tab.frame = frame
            tab.isHidden = false
            return
        }
        guard tab.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            tab.animator().frame = frame
        }
    }

    private func updateAccessibilityPositions() {
        let visibleTabs = windowTabs.filter { !$0.isHidden }
        for (index, tab) in visibleTabs.enumerated() {
            tab.setAccessibilityHelp("Window \(index + 1) of \(windowTabs.count)")
        }
        tabRow.setAccessibilityChildren(visibleTabs + ghostTabs.filter { !$0.isHidden })
    }

    // MARK: - Reordering

    private func beginDrag(_ tab: TabButton, id: CGWindowID, grabOffset: CGFloat) {
        draggedWindowID = id
        dragGrabOffset = grabOffset
        draggedOriginX = tab.frame.minX
        tab.isLifted = true
        tabRow.addSubview(tab, positioned: .above, relativeTo: nil)
    }

    private func moveDrag(id: CGWindowID, windowLocation: CGPoint) {
        guard draggedWindowID == id else { return }
        let pointerX = tabRow.convert(windowLocation, from: nil).x
        draggedOriginX = pointerX - dragGrabOffset
        if let target = slotFrames.first(where: { key, frame in
            key != id && pointerX >= frame.minX && pointerX < frame.maxX
        })?.key,
            let destination = windowTabs.firstIndex(where: { $0.windowID == target })
        {
            onReorderWindow?(id, destination)
        }
        layoutTabs(animated: true)
    }

    private func endDrag(id: CGWindowID) {
        guard draggedWindowID == id else { return }
        draggedWindowID = nil
        windowTabs.first { $0.windowID == id }?.isLifted = false
        layoutTabs(animated: true)
    }

    // MARK: - Menus

    private func popUp(_ menu: NSMenu, from view: NSView) {
        let origin = CGPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: origin, in: view)
    }

    private func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        for id in overflowWindowIDs {
            guard let tab = windowTabs.first(where: { $0.windowID == id }) else { continue }
            let item = menu.addItem(withTitle: tab.label, action: #selector(selectOverflowWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: id)
            item.image = Self.profileIndicator(color: tab.color)
            item.toolTip = tab.toolTip
        }
        return menu
    }

    private func newWindowMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, profile) in launchProfiles.enumerated() {
            let display = profile ?? .pickerDefault(browser: launchBrowser.kind)
            let item = menu.addItem(withTitle: display.displayName, action: #selector(openProfile(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = Self.profileIndicator(color: display.displayColor)
        }
        return menu
    }

    @objc private func selectOverflowWindow(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        onSelectWindow?(CGWindowID(id))
    }

    @objc private func openProfile(_ sender: NSMenuItem) {
        guard launchProfiles.indices.contains(sender.tag) else { return }
        onOpenProfile?(launchProfiles[sender.tag])
    }

    @objc private func requestSettings() {
        NotificationCenter.default.post(name: .transomSettings, object: nil)
    }

    @objc private func requestRescan() {
        NotificationCenter.default.post(name: .transomRescan, object: nil)
    }

    @objc private func quitTransom() {
        NSApp.terminate(nil)
    }

    private func contextMenu() -> NSMenu {
        let contextMenu = NSMenu()
        let settingsItem = contextMenu.addItem(
            withTitle: "Settings…",
            action: #selector(requestSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        let rescanItem = contextMenu.addItem(
            withTitle: "Rescan Browser Windows",
            action: #selector(requestRescan),
            keyEquivalent: ""
        )
        rescanItem.target = self
        contextMenu.addItem(.separator())
        let quitItem = contextMenu.addItem(
            withTitle: "Quit Transom",
            action: #selector(quitTransom),
            keyEquivalent: ""
        )
        quitItem.target = self
        return contextMenu
    }

    fileprivate static func profileIndicator(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.white.withAlphaComponent(0.38).setStroke()
            let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 1.25, dy: 1.25))
            rim.lineWidth = 0.75
            rim.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension OverlayTheme {
    var stripTextColor: NSColor {
        catppuccinPalette.flatMap { NSColor(hexRGB: $0.text) } ?? .labelColor
    }
}

private final class TabRowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Browser Windows")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}

private final class TabButton: NSView {
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let selectedFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let dotSize: CGFloat = 8
    private static let leadingPadding: CGFloat = 11
    private static let dotSpacing: CGFloat = 7
    private static let closeSize: CGFloat = 16
    private static let closeTrailingPadding: CGFloat = 6
    private static let labelCloseSpacing: CGFloat = 4
    private static let ghostTrailingPadding: CGFloat = 11

    let windowID: CGWindowID?
    var onPress: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragBegan: ((CGFloat) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    var label = "" {
        didSet {
            guard label != oldValue else { return }
            setAccessibilityLabel(isWindow ? label : "Open \(label)")
            needsDisplay = true
        }
    }

    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    var theme = OverlayTheme.automatic { didSet { needsDisplay = true } }
    var isBrowserActive = true { didSet { needsDisplay = true } }
    var isLifted = false { didSet { needsDisplay = true } }

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            setAccessibilityValue(NSNumber(value: isSelected))
            setAccessibilitySelected(isSelected)
            needsDisplay = true
        }
    }

    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var isCloseHovered = false { didSet { needsDisplay = true } }

    private var isWindow: Bool { windowID != nil }

    var naturalWidth: CGFloat {
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: Self.selectedFont]).width)
        let trailing = isWindow
            ? Self.labelCloseSpacing + Self.closeSize + Self.closeTrailingPadding
            : Self.ghostTrailingPadding
        return Self.leadingPadding + Self.dotSize + Self.dotSpacing + textWidth + trailing
    }

    private var closeRect: CGRect {
        CGRect(
            x: bounds.maxX - Self.closeTrailingPadding - Self.closeSize,
            y: bounds.midY - Self.closeSize / 2,
            width: Self.closeSize,
            height: Self.closeSize
        )
    }

    init(windowID: CGWindowID?) {
        self.windowID = windowID
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(windowID == nil ? .button : .radioButton)
        setAccessibilitySubrole(windowID == nil ? nil : .tabButton)
        if windowID != nil {
            setAccessibilityValue(NSNumber(value: false))
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Close Window") { [weak self] in
                    self?.onClose?()
                    return true
                },
            ])
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateCloseHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCloseHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isCloseHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        if isWindow, closeRect.contains(start) {
            trackClose()
            return
        }

        isPressed = true
        if isWindow {
            onPress?()
        }
        var isDragging = false
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let next = window?.nextEvent(matching: mask) {
            let location = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged {
                if isWindow, !isDragging,
                   abs(location.x - start.x) > 4 || abs(location.y - start.y) > 4
                {
                    isDragging = true
                    isPressed = false
                    onDragBegan?(start.x)
                }
                if isDragging {
                    onDragMoved?(next.locationInWindow)
                } else {
                    isPressed = bounds.contains(location)
                }
            } else {
                if isDragging {
                    onDragEnded?()
                } else if !isWindow, bounds.contains(location) {
                    onPress?()
                }
                break
            }
        }
        isPressed = false
        isHovered = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard isWindow, event.buttonNumber == 2,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else {
            super.otherMouseUp(with: event)
            return
        }
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let textColor = theme.stripTextColor
        let tint = isBrowserActive
            ? color
            : (color.usingColorSpace(.sRGB)?.blended(withFraction: 0.55, of: .gray) ?? color)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)

        if isSelected || isLifted {
            tint.withAlphaComponent(isBrowserActive ? 0.24 : 0.14).setFill()
            shape.fill()
            tint.withAlphaComponent(isBrowserActive ? 0.55 : 0.3).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if isPressed {
            textColor.withAlphaComponent(0.13).setFill()
            shape.fill()
        } else if isHovered {
            textColor.withAlphaComponent(0.07).setFill()
            shape.fill()
        }

        let contentAlpha: CGFloat = isWindow ? 1 : (isHovered ? 0.8 : 0.5)
        let dotRect = CGRect(
            x: Self.leadingPadding,
            y: bounds.midY - Self.dotSize / 2,
            width: Self.dotSize,
            height: Self.dotSize
        )
        if isWindow {
            tint.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            NSColor.white.withAlphaComponent(0.38).setStroke()
            let rim = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.25, dy: 0.25))
            rim.lineWidth = 0.75
            rim.stroke()
        } else {
            tint.withAlphaComponent(contentAlpha).setStroke()
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }

        let showsClose = isWindow && (isHovered || isCloseHovered)
        let labelX = dotRect.maxX + Self.dotSpacing
        let labelMaxX = isWindow
            ? closeRect.minX - Self.labelCloseSpacing
            : bounds.maxX - Self.ghostTrailingPadding
        let font = isSelected ? Self.selectedFont : Self.font
        let labelAlpha: CGFloat = isSelected ? (isBrowserActive ? 1 : 0.7) : (isBrowserActive ? 0.72 : 0.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor.withAlphaComponent(labelAlpha * contentAlpha),
            .paragraphStyle: paragraph,
        ]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        (label as NSString).draw(
            with: CGRect(
                x: labelX,
                y: floor((bounds.height - lineHeight) / 2),
                width: max(0, labelMaxX - labelX),
                height: lineHeight
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes
        )

        guard showsClose else { return }
        let close = closeRect
        if isCloseHovered {
            textColor.withAlphaComponent(isPressed ? 0.2 : 0.12).setFill()
            NSBezierPath(roundedRect: close, xRadius: 4, yRadius: 4).fill()
        }
        let glyph = close.insetBy(dx: 5, dy: 5)
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: glyph.minX, y: glyph.minY))
        cross.line(to: CGPoint(x: glyph.maxX, y: glyph.maxY))
        cross.move(to: CGPoint(x: glyph.minX, y: glyph.maxY))
        cross.line(to: CGPoint(x: glyph.maxX, y: glyph.minY))
        cross.lineWidth = 1.25
        cross.lineCapStyle = .round
        textColor.withAlphaComponent(isCloseHovered ? 0.85 : 0.55).setStroke()
        cross.stroke()
    }

    private func updateCloseHover(_ event: NSEvent) {
        guard isWindow else { return }
        isCloseHovered = closeRect.contains(convert(event.locationInWindow, from: nil))
    }

    private func trackClose() {
        isCloseHovered = true
        isPressed = true
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let next = window?.nextEvent(matching: mask) {
            let inside = closeRect.contains(convert(next.locationInWindow, from: nil))
            isCloseHovered = inside
            if next.type == .leftMouseUp {
                isPressed = false
                if inside {
                    onClose?()
                }
                return
            }
        }
        isPressed = false
    }
}

private final class StripButton: NSView {
    enum Content {
        case appIcon(NSImage)
        case plus
        case overflow(Int)
    }

    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    var content: Content { didSet { needsDisplay = true } }
    var theme = OverlayTheme.automatic { didSet { needsDisplay = true } }
    var onPress: ((NSView) -> Void)?
    var accessibilityName = "" { didSet { setAccessibilityLabel(accessibilityName) } }
    private var isHovered = false { didSet { needsDisplay = true } }

    static func overflowWidth(count: Int) -> CGFloat {
        let text = ("+\(count)" as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + 28
    }

    init(content: Content) {
        self.content = content
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(self)
        isHovered = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let textColor = theme.stripTextColor
        if isHovered {
            textColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let foreground = textColor.withAlphaComponent(isHovered ? 0.9 : 0.6)
        switch content {
        case let .appIcon(image):
            image.draw(in: bounds.insetBy(dx: 2, dy: 2))
        case .plus:
            let glyph = CGRect(x: bounds.midX - 5.5, y: bounds.midY - 5.5, width: 11, height: 11)
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: glyph.midX, y: glyph.minY))
            plus.line(to: CGPoint(x: glyph.midX, y: glyph.maxY))
            plus.move(to: CGPoint(x: glyph.minX, y: glyph.midY))
            plus.line(to: CGPoint(x: glyph.maxX, y: glyph.midY))
            plus.lineWidth = 1.5
            plus.lineCapStyle = .round
            foreground.setStroke()
            plus.stroke()
        case let .overflow(count):
            let text = "+\(count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: foreground]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: 10, y: floor((bounds.height - size.height) / 2)), withAttributes: attributes)
            let chevronX = 10 + ceil(size.width) + 4
            let chevron = NSBezierPath()
            chevron.move(to: CGPoint(x: chevronX, y: bounds.midY + 1.5))
            chevron.line(to: CGPoint(x: chevronX + 3, y: bounds.midY - 1.5))
            chevron.line(to: CGPoint(x: chevronX + 6, y: bounds.midY + 1.5))
            chevron.lineWidth = 1.25
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            foreground.setStroke()
            chevron.stroke()
        }
    }
}

extension Notification.Name {
    static let transomSettings = Notification.Name("Transom.settings")
    static let transomRescan = Notification.Name("Transom.rescan")
}
