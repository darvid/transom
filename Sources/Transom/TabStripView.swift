import AppKit

final class TabStripView: NSView {
    var onSelectWindow: ((CGWindowID) -> Void)?
    var onActivateBrowser: (() -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    var onReorderWindow: ((CGWindowID, Int) -> Void)?

    private let browser: InstalledBrowser
    private let tabs = NativeTabControl()
    private let appIconView = NSImageView()
    private var tabWindowIDs: [CGWindowID] = []
    private var tabLabels: [String] = []
    private var tabProfileIDs: [String?] = []
    private var tabProfileColors: [String?] = []
    private var lastDragLocation: CGPoint?

    init(browser: InstalledBrowser, frame frameRect: NSRect) {
        self.browser = browser
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        menu = contextMenu()
        applyTheme(AppSettings.shared.overlayTheme)

        appIconView.image = NSWorkspace.shared.icon(
            forFile: browser.applicationURL.path
        )
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false

        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        tabs.controlSize = .regular
        tabs.font = .systemFont(ofSize: 12.5, weight: .medium)
        tabs.target = self
        tabs.action = #selector(selectTab(_:))
        tabs.onReorder = { [weak self] source, destination in
            guard let self, tabWindowIDs.indices.contains(source) else { return }
            onReorderWindow?(tabWindowIDs[source], destination)
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false

        addSubview(appIconView)
        addSubview(tabs)
        NSLayoutConstraint.activate([
            appIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            appIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 22),
            appIconView.heightAnchor.constraint(equalToConstant: 22),
            tabs.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            tabs.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func applyTheme(_ theme: OverlayTheme) {
        switch theme {
        case .automatic:
            appearance = nil
            tabs.appearance = nil
        case .light, .catppuccinLatte:
            let light = NSAppearance(named: .aqua)
            appearance = light
            tabs.appearance = light
        case .black, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha:
            let dark = NSAppearance(named: .darkAqua)
            appearance = dark
            tabs.appearance = dark
        }
        needsDisplay = true
        tabs.needsDisplay = true
    }

    func update(windows: [BrowserWindow], selectedWindowID: CGWindowID?) {
        let labels = windows.enumerated().map { index, window in
            window.profile?.displayName ?? "Window \(index + 1)"
        }
        let windowIDs = windows.map(\.id)
        let profileIDs = windows.map { $0.profile?.id }
        let profileColors = windows.map { $0.profile?.displayColor.hexRGB }

        if windowIDs != tabWindowIDs || labels != tabLabels || profileIDs != tabProfileIDs
            || profileColors != tabProfileColors
        {
            tabWindowIDs = windowIDs
            tabLabels = labels
            tabProfileIDs = profileIDs
            tabProfileColors = profileColors
            tabs.segmentCount = windows.count

            for (index, item) in zip(windows, labels).enumerated() {
                let (window, label) = item
                tabs.setLabel(label, forSegment: index)
                tabs.setImage(
                    profileIndicator(color: window.profile?.displayColor ?? .tertiaryLabelColor),
                    forSegment: index
                )
                tabs.setImageScaling(.scaleNone, forSegment: index)
                tabs.setToolTip(window.title, forSegment: index)
                tabs.setWidth(segmentWidth(for: label), forSegment: index)
            }
        }

        let selectedSegment = selectedWindowID.flatMap(tabWindowIDs.firstIndex) ?? -1
        if tabs.selectedSegment != selectedSegment {
            tabs.selectedSegment = selectedSegment
            tabs.needsDisplay = true
            tabs.displayIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
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

    @objc private func selectTab(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard tabWindowIDs.indices.contains(index) else { return }
        onSelectWindow?(tabWindowIDs[index])
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

    private func segmentWidth(for label: String) -> CGFloat {
        let textWidth = (label as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]
        ).width
        return min(190, max(92, ceil(textWidth + 50)))
    }

    private func profileIndicator(color: NSColor) -> NSImage {
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

private final class NativeTabControl: NSSegmentedControl {
    var onReorder: ((Int, Int) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let initialLocation = convert(event.locationInWindow, from: nil)
        guard let initialSegment = segment(at: initialLocation) else {
            super.mouseDown(with: event)
            return
        }

        var currentSegment = initialSegment
        var isDragging = false
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let nextEvent = window?.nextEvent(matching: eventMask) {
            let location = convert(nextEvent.locationInWindow, from: nil)
            if nextEvent.type == .leftMouseDragged {
                if abs(location.x - initialLocation.x) > 4
                    || abs(location.y - initialLocation.y) > 4
                {
                    isDragging = true
                }
                if isDragging, let destination = segment(at: location), destination != currentSegment {
                    onReorder?(currentSegment, destination)
                    currentSegment = destination
                }
            } else {
                if !isDragging, let selected = segment(at: location) {
                    selectedSegment = selected
                    sendAction(action, to: target)
                }
                break
            }
        }
    }

    private func segment(at point: CGPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        var leadingEdge: CGFloat = 0
        for index in 0 ..< segmentCount {
            let trailingEdge = leadingEdge + width(forSegment: index)
            if point.x >= leadingEdge, point.x < trailingEdge {
                return index
            }
            leadingEdge = trailingEdge
        }
        return nil
    }
}

extension Notification.Name {
    static let transomSettings = Notification.Name("Transom.settings")
    static let transomRescan = Notification.Name("Transom.rescan")
}
