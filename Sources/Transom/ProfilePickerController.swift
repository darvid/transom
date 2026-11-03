import AppKit

struct ProfileChoice {
    let browser: InstalledBrowser
    let profile: BrowserProfile?

    var displayProfile: BrowserProfile { profile ?? .pickerDefault(browser: browser.kind) }

    static func pickerChoices(for browsers: [InstalledBrowser], settings: AppSettings = .shared) -> [ProfileChoice] {
        browsers.flatMap { browser in
            if browser.profiles.isEmpty {
                return settings.isProfileVisibleInPicker(browser: browser.kind, profileID: BrowserProfile.pickerDefaultID)
                    ? [ProfileChoice(browser: browser, profile: nil)] : []
            }
            return browser.profiles.filter {
                settings.isProfileVisibleInPicker(browser: browser.kind, profileID: $0.id)
            }.map { ProfileChoice(browser: browser, profile: $0) }
        }
    }
}

private final class PickerPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event)
    }
}

final class ProfilePickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private enum Layout {
        static let width: CGFloat = 600
        static let inset: CGFloat = 18
        static let rowHeight: CGFloat = 50
        static let rowSpacing: CGFloat = 2
        static let maxVisibleRows = 7
        static let minVisibleRows = 2
        static let quickPickLimit = 9
    }

    private enum ScopeTag {
        static let customPrefix = -1
        static let customExact = -2
    }

    private let panel: PickerPanel
    private let searchField = NSTextField()
    private let hostLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let queryLabel = NSTextField(labelWithString: "")
    private lazy var urlRow = NSStackView(views: [hostLabel, pathLabel, queryLabel])
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let rememberSwitch = NSSwitch()
    private let rememberLabel = NSTextField(labelWithString: "Remember for")
    private let scopePopup = NSPopUpButton()
    private let customPath = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let searchSurface = NSView()
    private let linkIcon = NSImageView()
    private let topRule = NSView()
    private let bottomRule = NSView()
    private var listHeight: NSLayoutConstraint?
    private var scopes: [RoutingScope] = []
    private var currentURL: URL?
    private var theme = OverlayTheme.automatic
    private var allChoices: [ProfileChoice] = []
    private var choices: [ProfileChoice] = []
    private var showsBrowserNames = false
    private var onPick: ((ProfileChoice, RoutingScope?) -> Void)?

    override init() {
        panel = PickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        configurePanel()
        configureHeader()
        configureList()
        let footer = configureFooter()

        for view in [searchSurface, urlRow, linkIcon, topRule, scrollView, emptyLabel, bottomRule, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        let listHeight = scrollView.heightAnchor.constraint(equalToConstant: 200)
        self.listHeight = listHeight
        let inset = Layout.inset
        NSLayoutConstraint.activate([
            searchSurface.topAnchor.constraint(equalTo: background.topAnchor, constant: inset),
            searchSurface.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            searchSurface.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),
            searchSurface.heightAnchor.constraint(equalToConstant: 46),

            linkIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 15),
            linkIcon.centerYAnchor.constraint(equalTo: urlRow.centerYAnchor),
            linkIcon.widthAnchor.constraint(equalToConstant: 13),
            linkIcon.heightAnchor.constraint(equalToConstant: 13),
            urlRow.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 11),
            urlRow.leadingAnchor.constraint(equalTo: linkIcon.trailingAnchor, constant: 8),
            urlRow.trailingAnchor.constraint(lessThanOrEqualTo: searchSurface.trailingAnchor, constant: -4),
            // Keep room for the path when the host alone is very long.
            hostLabel.widthAnchor.constraint(lessThanOrEqualTo: searchSurface.widthAnchor, multiplier: 0.5),

            topRule.topAnchor.constraint(equalTo: urlRow.bottomAnchor, constant: 11),
            topRule.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            topRule.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            listHeight,
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),

            bottomRule.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            bottomRule.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: 1),

            footer.topAnchor.constraint(equalTo: bottomRule.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.keyEquivalentHandler = { [weak self] event in
            self?.handleQuickPick(event) ?? false
        }

        background.frame = panel.contentView?.bounds ?? .zero
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.borderWidth = 1
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        tint.frame = background.bounds
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        background.addSubview(tint)
    }

    private func configureHeader() {
        searchSurface.wantsLayer = true
        searchSurface.layer?.cornerRadius = 11
        searchSurface.layer?.borderWidth = 1

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Open in…"
        searchField.font = .systemFont(ofSize: 17, weight: .regular)
        searchField.delegate = self
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.cell?.usesSingleLineMode = true
        searchField.setAccessibilityLabel("Search profiles or browsers")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        searchSurface.addSubview(searchIcon)
        searchSurface.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 40),
            searchField.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -14),
            searchField.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
        ])

        linkIcon.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        linkIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        linkIcon.contentTintColor = .tertiaryLabelColor

        // When the link is too long, the query shrinks first, then the
        // path (middle-truncated), and the host last. All stay below the
        // window's size-holding priority (500) so the panel never widens.
        let parts: [(NSTextField, NSFont, NSLineBreakMode, Float)] = [
            (hostLabel, .systemFont(ofSize: 12.5, weight: .semibold), .byTruncatingMiddle, 450),
            (pathLabel, .systemFont(ofSize: 12.5), .byTruncatingMiddle, 400),
            (queryLabel, .systemFont(ofSize: 12.5), .byTruncatingTail, 250),
        ]
        for (label, font, lineBreakMode, resistance) in parts {
            label.font = font
            label.lineBreakMode = lineBreakMode
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.init(resistance), for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        urlRow.orientation = .horizontal
        urlRow.alignment = .firstBaseline
        urlRow.spacing = 0
        urlRow.detachesHiddenViews = true
    }

    private func configureList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = Layout.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Layout.rowSpacing)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(confirmSelection)
        tableView.setAccessibilityLabel("Profiles")

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.isHidden = true
    }

    private func configureFooter() -> NSView {
        rememberSwitch.controlSize = .small
        rememberSwitch.target = self
        rememberSwitch.action = #selector(scopeChanged)
        rememberSwitch.setAccessibilityLabel("Remember this choice")

        rememberLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        let labelClick = NSClickGestureRecognizer(target: self, action: #selector(toggleRemember))
        rememberLabel.addGestureRecognizer(labelClick)

        scopePopup.controlSize = .small
        scopePopup.font = .systemFont(ofSize: 12)
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        scopePopup.cell?.lineBreakMode = .byTruncatingMiddle
        scopePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scopePopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        scopePopup.setAccessibilityLabel("Remember link scope")

        openButton.bezelStyle = .push
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(confirmSelection)
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let controls = NSStackView(views: [rememberSwitch, rememberLabel, scopePopup, spacer, openButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.setCustomSpacing(6, after: rememberSwitch)

        customPath.placeholderString = "/organization/repository"
        customPath.bezelStyle = .roundedBezel
        customPath.controlSize = .small
        customPath.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        customPath.delegate = self
        customPath.setAccessibilityLabel("Custom path on this site")

        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.maximumNumberOfLines = 1
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [controls, customPath, hintLabel])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 9
        footer.detachesHiddenViews = true
        for view in [controls, customPath, hintLabel] {
            view.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        return footer
    }

    // MARK: - Presentation

    func show(
        url: URL,
        browsers: [InstalledBrowser],
        onPick: @escaping (ProfileChoice, RoutingScope?) -> Void
    ) {
        self.onPick = onPick
        currentURL = url
        allChoices = ProfileChoice.pickerChoices(for: browsers)
        choices = allChoices
        showsBrowserNames = Set(allChoices.map(\.browser.kind)).count > 1
        applyTheme(AppSettings.shared.overlayTheme)
        searchField.stringValue = ""
        showURL(url)

        scopes = RoutingScope.suggestions(for: url)
        rebuildScopeMenu()
        rememberSwitch.state = .off
        customPath.stringValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"

        let visibleRows = min(Layout.maxVisibleRows, max(Layout.minVisibleRows, allChoices.count))
        listHeight?.constant = CGFloat(visibleRows) * (Layout.rowHeight + Layout.rowSpacing)
        reloadChoices()
        scopeChanged()

        resizeToFit(keepingTop: false)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(searchField)
    }

    private func rebuildScopeMenu() {
        let menu = NSMenu()
        for (index, scope) in scopes.enumerated() {
            // The kind leads so truncating a long pattern never hides it.
            let kind = scope.exact ? "Exact path" : (scope.path.isEmpty ? "Entire site" : "Path and subpaths")
            let title = "\(kind): \(scope.pattern.middleTruncated(to: 64))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.toolTip = scope.pattern
            item.tag = index
            menu.addItem(item)
        }
        if !scopes.isEmpty { menu.addItem(.separator()) }
        for (title, tag) in [("Custom path and subpaths…", ScopeTag.customPrefix),
                             ("Custom exact path…", ScopeTag.customExact)]
        {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            menu.addItem(item)
        }
        scopePopup.menu = menu
        scopePopup.selectItem(at: 0)
    }

    private func showURL(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? ""
        var extras = components?.percentEncodedQuery.map { "?" + $0 } ?? ""
        extras += components?.percentEncodedFragment.map { "#" + $0 } ?? ""
        hostLabel.stringValue = url.host ?? url.absoluteString
        pathLabel.stringValue = url.host == nil ? "" : path
        queryLabel.stringValue = url.host == nil ? "" : extras
        pathLabel.isHidden = pathLabel.stringValue.isEmpty
        queryLabel.isHidden = queryLabel.stringValue.isEmpty
        urlRow.toolTip = url.absoluteString
        urlRow.setAccessibilityLabel(url.absoluteString)
    }

    private func resizeToFit(keepingTop: Bool) {
        background.layoutSubtreeIfNeeded()
        let height = background.fittingSize.height
        var frame = panel.frame
        let contentHeight = panel.contentRect(forFrameRect: frame).height
        let delta = height - contentHeight
        guard abs(delta) > 0.5 else { return }
        frame.size.height += delta
        if keepingTop { frame.origin.y -= delta }
        panel.setFrame(frame, display: true, animate: keepingTop && panel.isVisible)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        choices.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = LauncherTableRowView()
        rowView.accent = Palette(theme: theme).accent
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = ProfileChoiceCellView()
        view.configure(
            choice: choices[row],
            showsBrowserName: showsBrowserNames,
            shortcut: row < Layout.quickPickLimit ? "⌘\(row + 1)" : nil,
            palette: Palette(theme: theme)
        )
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
    }

    // MARK: - Input

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            confirmSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === customPath {
            updateFooter()
            return
        }
        reloadChoices()
    }

    private func reloadChoices() {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        choices = query.isEmpty ? allChoices : allChoices.filter {
            $0.browser.displayName.lowercased().contains(query)
                || $0.displayProfile.displayName.lowercased().contains(query)
        }
        tableView.reloadData()
        if !choices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        updateFooter()
    }

    private func handleQuickPick(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
              (1 ... Layout.quickPickLimit).contains(digit),
              choices.indices.contains(digit - 1)
        else { return false }
        tableView.selectRowIndexes(IndexSet(integer: digit - 1), byExtendingSelection: false)
        confirmSelection()
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !choices.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let next = min(choices.count - 1, max(0, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - Remembering

    private var isRemembering: Bool { rememberSwitch.state == .on }

    private var isCustomScope: Bool { (scopePopup.selectedItem?.tag ?? 0) < 0 }

    private var selectedScope: RoutingScope? {
        guard isRemembering, let tag = scopePopup.selectedItem?.tag else { return nil }
        if scopes.indices.contains(tag) { return scopes[tag] }
        guard tag < 0, let host = currentURL?.host else { return nil }
        return RoutingScope(host: host, path: customPath.stringValue, exact: tag == ScopeTag.customExact)
    }

    @objc private func toggleRemember() {
        rememberSwitch.state = isRemembering ? .off : .on
        scopeChanged()
    }

    @objc private func scopeChanged() {
        scopePopup.isEnabled = isRemembering
        let showsCustom = isRemembering && isCustomScope
        if customPath.isHidden == showsCustom {
            customPath.isHidden = !showsCustom
            resizeToFit(keepingTop: true)
            if showsCustom { panel.makeFirstResponder(customPath) }
        }
        updateFooter()
    }

    private func updateFooter() {
        emptyLabel.isHidden = !choices.isEmpty
        emptyLabel.stringValue = allChoices.isEmpty
            ? "No profiles available. Enable Show in picker in Settings → Browsers, or rescan your browsers."
            : "No matching profiles."

        let selected = choices.indices.contains(tableView.selectedRow) ? choices[tableView.selectedRow] : nil
        let scope = selectedScope
        openButton.title = isRemembering ? "Save & Open" : "Open"
        openButton.isEnabled = selected != nil && (!isRemembering || scope != nil)

        let palette = Palette(theme: theme)
        hintLabel.textColor = palette.secondaryText
        if !isRemembering {
            hintLabel.stringValue = "↑↓ to choose  ·  ↩ to open  ·  ⌘1–9 to open directly  ·  esc to close"
        } else if let scope {
            let coverage = scope.exact ? "exactly" : (scope.path.isEmpty ? "and everything on it" : "and its subpaths")
            let target = selected.map { " in \($0.displayProfile.displayName)" } ?? ""
            hintLabel.stringValue = "Always open \(scope.pattern.middleTruncated(to: 40)) \(coverage)\(target). Query and fragment are ignored."
        } else {
            hintLabel.stringValue = "Enter a path beginning with /, without a query string or fragment."
            hintLabel.textColor = .systemOrange
        }
    }

    // MARK: - Theme

    private func applyTheme(_ theme: OverlayTheme) {
        self.theme = theme
        let palette = Palette(theme: theme)
        panel.appearance = theme == .automatic ? nil : NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
        background.material = palette.isLight ? .headerView : .hudWindow
        tint.layer?.backgroundColor = palette.tint.cgColor
        background.layer?.borderColor = (theme.catppuccinPalette == nil
            ? NSColor.white.withAlphaComponent(palette.isLight ? 0.5 : 0.14)
            : palette.accent.withAlphaComponent(0.35)).cgColor
        searchSurface.layer?.backgroundColor = palette.text.withAlphaComponent(palette.isLight ? 0.05 : 0.07).cgColor
        searchSurface.layer?.borderColor = palette.text.withAlphaComponent(0.08).cgColor
        for rule in [topRule, bottomRule] {
            rule.wantsLayer = true
            rule.layer?.backgroundColor = palette.text.withAlphaComponent(0.08).cgColor
        }
        searchField.textColor = palette.text
        hostLabel.textColor = palette.text
        pathLabel.textColor = palette.secondaryText
        queryLabel.textColor = palette.tertiaryText
        rememberLabel.textColor = palette.text
        emptyLabel.textColor = palette.secondaryText
        openButton.bezelColor = theme.catppuccinPalette == nil ? nil : palette.accent
    }

    // MARK: - Actions

    @objc private func confirmSelection() {
        let row = tableView.selectedRow
        guard choices.indices.contains(row), !isRemembering || selectedScope != nil else { return }
        let choice = choices[row]
        let scope = selectedScope
        panel.orderOut(nil)
        onPick?(choice, scope)
    }

    @objc private func cancel() {
        panel.orderOut(nil)
    }
}

private struct Palette {
    let isLight: Bool
    let text: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let accent: NSColor
    let tint: NSColor

    init(theme: OverlayTheme) {
        isLight = theme == .light || theme == .catppuccinLatte
        let catppuccin = theme.catppuccinPalette
        let customText = catppuccin.flatMap { NSColor(hexRGB: $0.text) }
        text = customText ?? .labelColor
        secondaryText = customText?.withAlphaComponent(0.62) ?? .secondaryLabelColor
        tertiaryText = customText?.withAlphaComponent(0.4) ?? .tertiaryLabelColor
        accent = catppuccin.flatMap { NSColor(hexRGB: $0.mauve) } ?? .controlAccentColor
        if let base = catppuccin.flatMap({ NSColor(hexRGB: $0.base) }) {
            tint = base.withAlphaComponent(0.94)
        } else if theme == .black {
            tint = NSColor.black.withAlphaComponent(0.94)
        } else {
            tint = isLight ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.13)
        }
    }
}

private final class LauncherTableRowView: NSTableRowView {
    var accent = NSColor.controlAccentColor

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        let rect = bounds.insetBy(dx: 0, dy: 0.5)
        accent.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

private final class ProfileChoiceCellView: NSTableCellView {
    private let avatar = NSView()
    private let initialLabel = NSTextField(labelWithString: "")
    private let browserBadge = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 9
        avatar.layer?.cornerCurve = .continuous

        initialLabel.font = .systemFont(ofSize: 14, weight: .bold)
        initialLabel.alignment = .center

        browserBadge.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.lineBreakMode = .byTruncatingTail

        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.detachesHiddenViews = true

        avatar.addSubview(initialLabel)
        for view in [avatar, browserBadge, text, shortcutLabel, initialLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [avatar, browserBadge, text, shortcutLabel] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            initialLabel.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            browserBadge.trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 5),
            browserBadge.bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 5),
            browserBadge.widthAnchor.constraint(equalToConstant: 17),
            browserBadge.heightAnchor.constraint(equalToConstant: 17),
            text.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -12),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(choice: ProfileChoice, showsBrowserName: Bool, shortcut: String?, palette: Palette) {
        let profile = choice.displayProfile
        let color = profile.displayColor.usingColorSpace(.sRGB) ?? profile.displayColor
        avatar.layer?.backgroundColor = color.cgColor
        initialLabel.stringValue = profile.displayName.first.map { String($0).uppercased() } ?? "?"
        initialLabel.textColor = color.prefersDarkForeground
            ? NSColor.black.withAlphaComponent(0.72) : .white

        browserBadge.image = NSWorkspace.shared.icon(forFile: choice.browser.applicationURL.path)
        browserBadge.isHidden = !showsBrowserName

        titleLabel.stringValue = profile.displayName
        titleLabel.textColor = palette.text
        subtitleLabel.stringValue = choice.browser.displayName
        subtitleLabel.textColor = palette.secondaryText
        subtitleLabel.isHidden = !showsBrowserName

        shortcutLabel.stringValue = shortcut ?? ""
        shortcutLabel.textColor = palette.tertiaryText

        setAccessibilityLabel(showsBrowserName
            ? "\(profile.displayName), \(choice.browser.displayName)" : profile.displayName)
    }
}

private extension NSColor {
    var prefersDarkForeground: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance * rgb.alphaComponent + (1 - rgb.alphaComponent) * 0.5 > 0.62
    }
}

private extension String {
    func middleTruncated(to limit: Int) -> String {
        guard count > limit, limit > 1 else { return self }
        let head = (limit - 1) / 2
        return prefix(head) + "…" + suffix(limit - 1 - head)
    }
}
