import AppKit
import OSLog

final class WorkspaceController: NSObject, NSMenuDelegate {
    var onShowSettings: (() -> Void)?
    var onShowRoutingRules: (() -> Void)?
    var onRegisterAsDefaultBrowser: (() -> Void)?

    private let accessibility = AccessibilityController()
    private let discovery: BrowserWindowDiscovery
    private let logger = Logger(subsystem: "com.transom.app", category: "OverlayVisibility")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var containers: [BrowserKind: ContainerController] = [:]
    private var windowIDsByBrowser: [BrowserKind: [CGWindowID]] = [:]
    private var timer: Timer?
    private var pointerTrackingTimer: Timer?
    private var pointerStateWatchdogTimer: Timer?
    private var localPointerIsDown = false
    private var globalWindowGestureMonitor: Any?
    private var localWindowGestureMonitor: Any?

    init(registry: BrowserRegistry) {
        discovery = BrowserWindowDiscovery(registry: registry)
        super.init()
        configureStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettings),
            name: .transomSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rescan),
            name: .transomRescan,
            object: nil
        )
    }

    deinit {
        pointerTrackingTimer?.invalidate()
        pointerStateWatchdogTimer?.invalidate()
        if let globalWindowGestureMonitor {
            NSEvent.removeMonitor(globalWindowGestureMonitor)
        }
        if let localWindowGestureMonitor {
            NSEvent.removeMonitor(localWindowGestureMonitor)
        }
    }

    func start() {
        if !accessibility.isTrusted {
            accessibility.requestPermission()
        }
        installWindowGestureMonitors()
        rescan()
        setPollingInterval(0.25)
        startPointerStateWatchdog()
    }

    private func installWindowGestureMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .flagsChanged,
        ]
        globalWindowGestureMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mask
        ) { [weak self] event in
            self?.handleWindowGesture(event, isLocal: false)
        }
        localWindowGestureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mask
        ) { [weak self] event in
            self?.handleWindowGesture(event, isLocal: true)
            return event
        }
    }

    private func handleWindowGesture(_ event: NSEvent, isLocal: Bool) {
        let shiftIsDown = event.modifierFlags.contains(.shift)
        let leftButtonIsDown = CGEventSource.buttonState(
            .combinedSessionState,
            button: .left
        )
        if isLocal, event.type == .leftMouseDown {
            localPointerIsDown = true
        } else if isLocal, event.type == .leftMouseUp {
            localPointerIsDown = false
        }
        if event.type == .leftMouseDown, !isLocal {
            let location = NSEvent.mouseLocation
            for container in containers.values {
                container.pointerDragDidBegin(at: location)
            }
            beginPointerTracking()
        } else if event.type == .leftMouseDragged, !isLocal {
            for container in containers.values {
                container.followPointerDrag()
            }
        }
        if shiftIsDown,
           event.type == .leftMouseDown || event.type == .leftMouseUp
           || (event.type == .flagsChanged && leftButtonIsDown)
        {
            for container in containers.values {
                container.expectInteractiveTilePlacement()
            }
        }
        if event.type == .leftMouseUp, !isLocal {
            finishPointerTracking(followFinalFrame: true)
        }
    }

    private func startPointerStateWatchdog() {
        pointerStateWatchdogTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(checkPhysicalPointerState),
            userInfo: nil,
            repeats: true
        )
        if let pointerStateWatchdogTimer {
            RunLoop.main.add(pointerStateWatchdogTimer, forMode: .common)
        }
    }

    @objc private func checkPhysicalPointerState() {
        let pointerButtonIsDown = CGEventSource.buttonState(
            .combinedSessionState,
            button: .left
        ) || CGEventSource.buttonState(.combinedSessionState, button: .right)
        if pointerButtonIsDown, pointerTrackingTimer == nil, !localPointerIsDown {
            let location = NSEvent.mouseLocation
            let captured = containers.values.reduce(false) { captured, container in
                container.pointerDragDidBegin(at: location) || captured
            }
            if captured {
                if CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) {
                    for container in containers.values {
                        container.expectInteractiveTilePlacement()
                    }
                }
                beginPointerTracking()
            }
        } else if pointerButtonIsDown, pointerTrackingTimer != nil,
                  CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        {
            for container in containers.values {
                container.expectInteractiveTilePlacement()
            }
        } else if !pointerButtonIsDown, pointerTrackingTimer != nil {
            finishPointerTracking(followFinalFrame: true)
        }
    }

    private func beginPointerTracking() {
        pointerTrackingTimer?.invalidate()
        pointerTrackingTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(trackPointerDrag),
            userInfo: nil,
            repeats: true
        )
        if let pointerTrackingTimer {
            RunLoop.main.add(pointerTrackingTimer, forMode: .common)
        }
    }

    private func endPointerTracking() {
        pointerTrackingTimer?.invalidate()
        pointerTrackingTimer = nil
    }

    @objc private func trackPointerDrag() {
        guard CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
        else {
            // Global event-tap utilities can consume mouse-up. Never leave
            // pointer tracking or its selected-window lock alive afterward.
            finishPointerTracking(followFinalFrame: true)
            return
        }
        for container in containers.values {
            container.followPointerDrag()
        }
    }

    private func finishPointerTracking(followFinalFrame: Bool) {
        if followFinalFrame {
            for container in containers.values {
                container.followPointerDrag()
            }
        }
        for container in containers.values {
            container.notePointerPlacementEnded()
        }
        endPointerTracking()
        poll()
    }

    private func setPollingInterval(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(poll),
            userInfo: nil,
            repeats: true
        )
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func poll() {
        let windows = discovery.discover()
        let grouped = Dictionary(grouping: windows, by: { $0.browser.kind })
        let runningKinds = Set(grouped.keys)

        for (kind, browserWindows) in grouped {
            let container: ContainerController
            if let existing = containers[kind] {
                container = existing
            } else if let browser = browserWindows.first?.browser {
                container = ContainerController(browser: browser)
                containers[kind] = container
            } else {
                continue
            }
            container.update(windows: browserWindows)
            container.setVisible(true)
            windowIDsByBrowser[kind] = browserWindows.map(\.id)
        }

        for (kind, container) in containers where !runningKinds.contains(kind) {
            if !(windowIDsByBrowser[kind] ?? []).isEmpty {
                logger.notice("Hiding \(kind.rawValue, privacy: .public) overlay: discovery returned no usable visible windows")
            }
            container.update(windows: [])
            container.setVisible(false)
            windowIDsByBrowser[kind] = []
        }
    }

    @objc private func rescan() {
        discovery.refreshBrowsers()
        for container in containers.values {
            container.rescanDidBegin()
        }
        poll()
    }

    @objc private func requestAccessibility() {
        accessibility.requestPermission()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func rescanBrowsers() {
        rescan()
    }

    func settingsDidChange() {
        for container in containers.values {
            container.settingsDidChange()
        }
    }

    @objc private func showSettings() {
        onShowSettings?()
    }

    @objc private func showRoutingRules() {
        onShowRoutingRules?()
    }

    @objc private func registerAsDefaultBrowser() {
        onRegisterAsDefaultBrowser?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.stack.badge.person.crop",
                accessibilityDescription: "Transom"
            )
            button.toolTip = "Transom"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(
            title: accessibility.isTrusted
                ? "Accessibility access granted"
                : "Accessibility access required",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        for browser in discovery.registry.browsers {
            let count = windowIDsByBrowser[browser.kind]?.count ?? 0
            let item = NSMenuItem(
                title: "\(browser.displayName) — \(count) window\(count == 1 ? "" : "s")",
                action: nil,
                keyEquivalent: ""
            )
            item.image = NSWorkspace.shared.icon(forFile: browser.applicationURL.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.isEnabled = false
            menu.addItem(item)
        }

        if discovery.registry.browsers.isEmpty {
            let item = NSMenuItem(
                title: "No supported browsers found",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let rescanItem = NSMenuItem(
            title: "Rescan Browsers",
            action: #selector(rescan),
            keyEquivalent: "r"
        )
        rescanItem.target = self
        menu.addItem(rescanItem)

        if !accessibility.isTrusted {
            let permissionItem = NSMenuItem(
                title: "Open Accessibility Settings…",
                action: #selector(requestAccessibility),
                keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
        }

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let rulesItem = NSMenuItem(
            title: "Routing Rules…",
            action: #selector(showRoutingRules),
            keyEquivalent: ""
        )
        rulesItem.target = self
        menu.addItem(rulesItem)

        let defaultBrowserItem = NSMenuItem(
            title: "Make Transom Default Browser…",
            action: #selector(registerAsDefaultBrowser),
            keyEquivalent: ""
        )
        defaultBrowserItem.target = self
        menu.addItem(defaultBrowserItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Transom",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
