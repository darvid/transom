import AppKit
import ServiceManagement

final class SettingsController: NSObject, NSTextFieldDelegate {
    var onRegisterAsDefaultBrowser: (() -> Void)?
    var onRescanBrowsers: (() -> Void)?
    var onSettingsChanged: (() -> Void)?

    private enum Section: Int {
        case general
        case appearance
        case browsers
        case links
    }

    private let registry: BrowserRegistry
    private let routingStore: RoutingStore
    private let window: NSPanel
    private let sectionControl = NSSegmentedControl(
        labels: ["General", "Appearance", "Browsers", "Links"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let contentContainer = NSView()
    private let launchAtLoginSwitch = NSSwitch()
    private let tileManagerSwitch = NSSwitch()
    private let overlayLayeringSwitch = NSSwitch()
    private let themePopup = NSPopUpButton()
    private lazy var routingRulesView = RoutingRulesSettingsView(
        store: routingStore,
        registry: registry
    )

    init(registry: BrowserRegistry, routingStore: RoutingStore) {
        self.registry = registry
        self.routingStore = routingStore
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Transom Settings"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 480)
        window.setFrameAutosaveName("TransomSettings")

        let background = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.autoresizingMask = [.width, .height]
        window.contentView = background

        sectionControl.selectedSegment = Section.general.rawValue
        sectionControl.segmentStyle = .automatic
        sectionControl.controlSize = .large
        sectionControl.target = self
        sectionControl.action = #selector(sectionChanged)
        sectionControl.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sectionControl)
        background.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sectionControl.topAnchor.constraint(equalTo: background.topAnchor, constant: 24),
            sectionControl.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            sectionControl.widthAnchor.constraint(equalToConstant: 410),
            contentContainer.topAnchor.constraint(equalTo: sectionControl.bottomAnchor, constant: 20),
            contentContainer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            contentContainer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
            contentContainer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -28),
        ])

        configureSwitches()
        display(.general)
    }

    func show() {
        refreshValues()
        display(Section(rawValue: sectionControl.selectedSegment) ?? .general)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func showLinks() {
        sectionControl.selectedSegment = Section.links.rawValue
        show()
    }

    private func configureSwitches() {
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged)
        tileManagerSwitch.target = self
        tileManagerSwitch.action = #selector(tileManagerChanged)
        overlayLayeringSwitch.target = self
        overlayLayeringSwitch.action = #selector(overlayLayeringChanged)
        themePopup.addItems(withTitles: OverlayTheme.allCases.map(\.displayName))
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
    }

    private func refreshValues() {
        if #available(macOS 13.0, *) {
            launchAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launchAtLoginSwitch.isEnabled = false
        }
        tileManagerSwitch.state = AppSettings.shared.tileManagerCompatibility ? .on : .off
        overlayLayeringSwitch.state = AppSettings.shared.keepOverlayAboveInactiveWindows
            ? .on
            : .off
        themePopup.selectItem(at: OverlayTheme.allCases.firstIndex(
            of: AppSettings.shared.overlayTheme
        ) ?? 0)
    }

    @objc private func sectionChanged() {
        display(Section(rawValue: sectionControl.selectedSegment) ?? .general)
    }

    private func display(_ section: Section) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch section {
        case .general:
            view = generalView()
        case .appearance:
            view = appearanceView()
        case .browsers:
            view = browsersView()
        case .links:
            view = linksView()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        let bottomConstraint = section == .browsers
            ? view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            : view.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            bottomConstraint,
        ])
    }

    private func generalView() -> NSView {
        let stack = verticalStack()
        let heading = sectionHeading(
            "General",
            detail: "Control how Transom starts and integrates with macOS window management."
        )
        let group = card(rows: [
            settingsRow(
                title: "Launch at login",
                detail: "Start Transom automatically when you sign in.",
                control: launchAtLoginSwitch
            ),
            separator(),
            settingsRow(
                title: "Window-manager compatibility",
                detail: "Fit the browser and overlay inside tiling window managers.",
                control: tileManagerSwitch
            ),
            separator(),
            settingsRow(
                title: "Raise glass with active browser",
                detail: "Keep the complete overlay above overlapping inactive windows.",
                control: overlayLayeringSwitch
            ),
        ])
        let footnote = NSTextField(
            wrappingLabelWithString: "Window behavior changes apply immediately to open browser containers."
        )
        footnote.font = .systemFont(ofSize: 11.5)
        footnote.textColor = .tertiaryLabelColor
        for view in [heading, group, footnote] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func appearanceView() -> NSView {
        let stack = verticalStack()
        let heading = sectionHeading(
            "Appearance",
            detail: "Choose how the Transom overlay looks above browser windows."
        )
        themePopup.controlSize = .large
        let group = card(rows: [
            settingsRow(
                title: "Overlay theme",
                detail: "Automatic follows macOS. Black uses an opaque near-black backing.",
                control: themePopup
            ),
        ])
        for view in [heading, group] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func browsersView() -> NSView {
        registry.refresh()
        let stack = verticalStack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = sectionHeading(
            "Browsers",
            detail: "Rename profiles and choose the colors Transom uses for them."
        )
        stack.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let browserStack = NSStackView()
        browserStack.orientation = .vertical
        browserStack.spacing = 0
        browserStack.alignment = .leading
        if registry.browsers.isEmpty {
            let empty = NSTextField(
                wrappingLabelWithString: "No supported browsers were found in Applications or through Launch Services."
            )
            empty.textColor = .secondaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            browserStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: browserStack.widthAnchor).isActive = true
        } else {
            for (index, browser) in registry.browsers.enumerated() {
                if index > 0 {
                    let divider = separator()
                    browserStack.addArrangedSubview(divider)
                    divider.widthAnchor.constraint(equalTo: browserStack.widthAnchor).isActive = true
                }
                let row = browserRow(browser)
                browserStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: browserStack.widthAnchor).isActive = true
            }
        }
        let group = card(rows: [browserStack])
        stack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let rescanButton = NSButton(title: "Rescan Browsers", target: self, action: #selector(rescanBrowsers))
        rescanButton.bezelStyle = .rounded
        rescanButton.controlSize = .large
        stack.addArrangedSubview(rescanButton)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        return scrollView
    }

    private func linksView() -> NSView {
        let stack = verticalStack()
        let heading = sectionHeading(
            "Web Links",
            detail: "Choose how HTTP and HTTPS links are routed to browser profiles."
        )
        stack.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let defaultButton = NSButton(
            title: isDefaultBrowser ? "Transom Is the Default Browser" : "Make Transom Default Browser…",
            target: self,
            action: #selector(makeDefaultBrowser)
        )
        defaultButton.bezelStyle = .rounded
        defaultButton.controlSize = .large
        defaultButton.isEnabled = !isDefaultBrowser

        let group = card(rows: [
            settingsRow(
                title: "Default link handler",
                detail: "Open unmatched links in Transom’s searchable profile picker.",
                control: defaultButton
            ),
        ])
        stack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let rulesHeading = sectionHeading(
            "Routing Rules",
            detail: "Regex rules run first, in list order. Site rules prefer the most specific path. Hold Option when opening a link to choose a profile once."
        )
        stack.addArrangedSubview(rulesHeading)
        rulesHeading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        routingRulesView.refresh()
        stack.addArrangedSubview(routingRulesView)
        routingRulesView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    private var isDefaultBrowser: Bool {
        guard let url = URL(string: "https://example.com"),
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        else {
            return false
        }
        return applicationURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        return stack
    }

    private func sectionHeading(_ title: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12.5)
        detailLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func card(rows: [NSView]) -> NSView {
        let background = NSVisualEffectView()
        background.material = .contentBackground
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 11
        background.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.36).cgColor

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
        return background
    }

    private func settingsRow(title: String, detail: String, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -20),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func browserRow(_ browser: InstalledBrowser) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        let header = browserHeaderRow(browser)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for profile in browser.profiles {
            let divider = separator()
            stack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let row = profileRow(profile, browser: browser.kind)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func browserHeaderRow(_ browser: InstalledBrowser) -> NSView {
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: browser.applicationURL.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: browser.displayName)
        name.font = .systemFont(ofSize: 13.5, weight: .semibold)
        let count = browser.profiles.count
        let detail = NSTextField(
            labelWithString: count == 0
                ? "Default profile"
                : "\(count) profile\(count == 1 ? "" : "s")"
        )
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.addSubview(icon)
        row.addSubview(labels)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 58),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])
        return row
    }

    private func profileRow(_ profile: BrowserProfile, browser: BrowserKind) -> NSView {
        let colorWell = ProfileColorWell()
        colorWell.browser = browser
        colorWell.profileID = profile.id
        colorWell.color = profile.displayColor
        colorWell.controlSize = .small
        // Native click-to-open requires a bordered well; ProfileColorWell
        // supplies its own circular drawing instead of the native bezel.
        colorWell.isBordered = true
        colorWell.toolTip = "Choose a color for \(profile.displayName)"
        colorWell.setAccessibilityLabel("Color for \(profile.displayName)")
        colorWell.target = self
        colorWell.action = #selector(profileColorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false

        let resetColor = ProfileColorResetButton(
            title: "Reset",
            target: self,
            action: #selector(resetProfileColor(_:))
        )
        resetColor.browser = browser
        resetColor.profileID = profile.id
        resetColor.controlSize = .small
        resetColor.bezelStyle = .rounded
        resetColor.colorWell = colorWell
        resetColor.nativeColor = profile.color
        resetColor.isHidden = AppSettings.shared.profileOverride(
            browser: browser,
            profileID: profile.id
        )?.colorHex == nil
        colorWell.resetButton = resetColor

        let colorControls = NSStackView(views: [resetColor])
        colorControls.orientation = .horizontal
        colorControls.alignment = .centerY
        colorControls.spacing = 7
        colorControls.translatesAutoresizingMaskIntoConstraints = false

        let nameField = ProfileNameField()
        nameField.browser = browser
        nameField.profileID = profile.id
        nameField.stringValue = profile.customName ?? ""
        nameField.placeholderString = profile.name
        nameField.controlSize = .large
        nameField.font = .systemFont(ofSize: 13)
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let nameStack = NSStackView()
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 2
        nameStack.addArrangedSubview(nameField)
        if let customName = profile.customName, customName != profile.name {
            let original = NSTextField(labelWithString: "Original: \(profile.name)")
            original.font = .systemFont(ofSize: 10.5)
            original.textColor = .tertiaryLabelColor
            original.lineBreakMode = .byTruncatingTail
            nameStack.addArrangedSubview(original)
        }
        nameStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.addSubview(nameStack)
        row.addSubview(colorWell)
        row.addSubview(colorControls)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 62),
            colorWell.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 44),
            colorWell.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            nameStack.leadingAnchor.constraint(equalTo: colorWell.trailingAnchor, constant: 12),
            nameStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameStack.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            colorControls.leadingAnchor.constraint(equalTo: nameStack.trailingAnchor, constant: 12),
            nameField.widthAnchor.constraint(equalToConstant: 260),
            nameField.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            colorWell.widthAnchor.constraint(equalToConstant: 28),
            colorWell.heightAnchor.constraint(equalToConstant: 28),
            colorControls.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -4),
            colorControls.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    @objc private func launchAtLoginChanged() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLoginSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            refreshValues()
            let alert = NSAlert(error: error)
            alert.messageText = "Could not update Launch at Login"
            alert.runModal()
        }
    }

    @objc private func tileManagerChanged() {
        AppSettings.shared.tileManagerCompatibility = tileManagerSwitch.state == .on
        onSettingsChanged?()
    }

    @objc private func overlayLayeringChanged() {
        AppSettings.shared.keepOverlayAboveInactiveWindows = overlayLayeringSwitch.state == .on
        onSettingsChanged?()
    }

    @objc private func themeChanged() {
        guard OverlayTheme.allCases.indices.contains(themePopup.indexOfSelectedItem) else {
            return
        }
        AppSettings.shared.overlayTheme = OverlayTheme.allCases[themePopup.indexOfSelectedItem]
        onSettingsChanged?()
    }

    @objc private func rescanBrowsers() {
        registry.refresh()
        onRescanBrowsers?()
        display(.browsers)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? ProfileNameField else { return }
        AppSettings.shared.setProfileName(
            field.stringValue.isEmpty ? nil : field.stringValue,
            browser: field.browser,
            profileID: field.profileID
        )
        profileCustomizationChanged()
    }

    @objc private func profileColorChanged(_ sender: ProfileColorWell) {
        guard let hex = sender.color.hexRGB else { return }
        AppSettings.shared.setProfileColor(
            hex,
            browser: sender.browser,
            profileID: sender.profileID
        )
        sender.resetButton?.isHidden = false
        profileCustomizationChanged(rebuildSettings: false)
    }

    @objc private func resetProfileColor(_ sender: ProfileColorResetButton) {
        AppSettings.shared.setProfileColor(
            nil,
            browser: sender.browser,
            profileID: sender.profileID
        )
        sender.colorWell?.color = sender.nativeColor
        sender.isHidden = true
        profileCustomizationChanged(rebuildSettings: false)
    }

    private func profileCustomizationChanged(rebuildSettings: Bool = true) {
        registry.refresh()
        onRescanBrowsers?()
        if rebuildSettings {
            display(.browsers)
        }
    }

    @objc private func makeDefaultBrowser() {
        onRegisterAsDefaultBrowser?()
    }

}

private final class ProfileNameField: NSTextField {
    var browser = BrowserKind.chrome
    var profileID = ""
}

private final class ProfileColorWell: NSColorWell {
    var browser = BrowserKind.chrome
    var profileID = ""
    weak var resetButton: ProfileColorResetButton?

    // The custom swatch uses the full view bounds, not the native bezel's
    // alignment rectangle, which can extend outside the stack's layout box.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func activate(_ exclusive: Bool) {
        super.activate(exclusive)
        guard let window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let panel = NSColorPanel.shared
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let preferredX = anchor.maxX + 12
        let x = preferredX + size.width <= visibleFrame.maxX
            ? preferredX : anchor.minX - size.width - 12
        panel.setFrameOrigin(CGPoint(
            x: max(visibleFrame.minX, min(x, visibleFrame.maxX - size.width)),
            y: max(visibleFrame.minY, min(anchor.maxY - size.height, visibleFrame.maxY - size.height))
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        let swatchRect = bounds.insetBy(dx: 2, dy: 2)
        let swatch = NSBezierPath(ovalIn: swatchRect)
        color.setFill()
        swatch.fill()

        NSColor.white.withAlphaComponent(0.32).setStroke()
        swatch.lineWidth = 1
        swatch.stroke()

        if isActive {
            NSColor.controlAccentColor.setStroke()
            let focusRing = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            focusRing.lineWidth = 1.5
            focusRing.stroke()
        }
    }
}

private final class ProfileColorResetButton: NSButton {
    var browser = BrowserKind.chrome
    var profileID = ""
    weak var colorWell: ProfileColorWell?
    var nativeColor = NSColor.clear
}
