import AppKit

struct ProfileChoice {
    let browser: InstalledBrowser
    let profile: BrowserProfile?
}

final class ProfilePickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private let panel: NSPanel
    private let searchField = NSTextField()
    private let urlLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scopePopup = NSPopUpButton()
    private let customPath = NSTextField()
    private let scopeHint = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let searchSurface = NSVisualEffectView()
    private var scopes: [RoutingScope] = []
    private var currentURL: URL?
    private var customPathHeight: NSLayoutConstraint?
    private var theme = OverlayTheme.automatic
    private var allChoices: [ProfileChoice] = []
    private var choices: [ProfileChoice] = []
    private var onPick: ((ProfileChoice, RoutingScope?) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        background.frame = panel.contentView?.bounds ?? .zero
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.borderWidth = 1.25
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        tint.frame = background.bounds
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.13).cgColor
        tint.autoresizingMask = [.width, .height]
        background.addSubview(tint)

        searchSurface.material = .contentBackground
        searchSurface.blendingMode = .withinWindow
        searchSurface.state = .active
        searchSurface.wantsLayer = true
        searchSurface.layer?.cornerRadius = 13
        searchSurface.layer?.borderWidth = 1
        searchSurface.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        searchSurface.translatesAutoresizingMaskIntoConstraints = false

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "Search"
        )
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search profiles or browsers"
        searchField.font = .systemFont(ofSize: 18, weight: .medium)
        searchField.delegate = self
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false

        searchSurface.addSubview(searchIcon)
        searchSurface.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 17),
            searchIcon.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 11),
            searchField.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
        ])

        urlLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 60
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(confirmSelection)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        scopePopup.cell?.lineBreakMode = .byTruncatingMiddle
        scopePopup.setAccessibilityLabel("Remember link scope")
        scopePopup.translatesAutoresizingMaskIntoConstraints = false
        customPath.placeholderString = "/organization/repository"
        customPath.bezelStyle = .roundedBezel
        customPath.delegate = self
        customPath.setAccessibilityLabel("Custom path on this site")
        customPath.translatesAutoresizingMaskIntoConstraints = false
        scopeHint.font = .systemFont(ofSize: 11.5)
        scopeHint.textColor = .secondaryLabelColor
        scopeHint.translatesAutoresizingMaskIntoConstraints = false
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(confirmSelection)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let customPathHeight = customPath.heightAnchor.constraint(equalToConstant: 0)
        self.customPathHeight = customPathHeight

        for view in [searchSurface, urlLabel, scrollView, scopePopup, customPath, scopeHint, openButton] {
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchSurface.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            searchSurface.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 26),
            searchSurface.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -26),
            searchSurface.heightAnchor.constraint(equalToConstant: 56),
            urlLabel.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 10),
            urlLabel.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 4),
            urlLabel.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scopePopup.topAnchor, constant: -16),
            scopePopup.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor),
            scopePopup.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -12),
            scopePopup.bottomAnchor.constraint(equalTo: customPath.topAnchor, constant: -8),
            customPath.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor),
            customPath.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor),
            customPathHeight,
            customPath.bottomAnchor.constraint(equalTo: scopeHint.topAnchor, constant: -6),
            scopeHint.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor),
            scopeHint.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor),
            scopeHint.heightAnchor.constraint(equalToConstant: 34),
            scopeHint.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18),
            openButton.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor),
            openButton.centerYAnchor.constraint(equalTo: scopePopup.centerYAnchor),
        ])
    }

    func show(
        url: URL,
        browsers: [InstalledBrowser],
        onPick: @escaping (ProfileChoice, RoutingScope?) -> Void
    ) {
        self.onPick = onPick
        currentURL = url
        applyTheme(AppSettings.shared.overlayTheme)
        allChoices = browsers.flatMap { browser in
            browser.profiles.isEmpty
                ? [ProfileChoice(browser: browser, profile: nil)]
                : browser.profiles.map { ProfileChoice(browser: browser, profile: $0) }
        }
        choices = allChoices
        searchField.stringValue = ""
        urlLabel.stringValue = url.absoluteString
        scopes = RoutingScope.suggestions(for: url)
        scopePopup.removeAllItems()
        scopePopup.addItem(withTitle: "Open once · Always open…")
        for scope in scopes {
            let kind = scope.exact ? "Exact path" : (scope.path.isEmpty ? "Entire site" : "Path + subpaths")
            scopePopup.addItem(withTitle: "\(kind): \(scope.pattern)")
        }
        scopePopup.addItems(withTitles: ["Custom path + subpaths…", "Custom exact path…"])
        scopePopup.selectItem(at: 0)
        customPath.stringValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        scopeChanged()
        tableView.reloadData()
        if !choices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(searchField)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        choices.count
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        let row = LauncherTableRowView()
        row.accent = theme.catppuccinPalette.flatMap { NSColor(hexRGB: $0.mauve) } ?? .controlAccentColor
        return row
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let view = ProfileChoiceCellView()
        view.configure(choice: choices[row])
        view.applyTheme(theme)
        return view
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
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
            scopeChanged()
            return
        }
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        choices = query.isEmpty ? allChoices : allChoices.filter {
            $0.browser.displayName.lowercased().contains(query)
                || ($0.profile?.displayName.lowercased().contains(query) ?? false)
        }
        tableView.reloadData()
        if !choices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateOpenButton()
    }

    private var selectedScope: RoutingScope? {
        let index = scopePopup.indexOfSelectedItem
        if index > 0, index <= scopes.count { return scopes[index - 1] }
        guard index > scopes.count, let host = currentURL?.host else { return nil }
        return RoutingScope(
            host: host,
            path: customPath.stringValue,
            exact: index == scopes.count + 2
        )
    }

    @objc private func scopeChanged() {
        let remembering = scopePopup.indexOfSelectedItem > 0
        customPath.isHidden = scopePopup.indexOfSelectedItem <= scopes.count
        customPathHeight?.constant = customPath.isHidden ? 0 : 26
        if let scope = selectedScope {
            scopeHint.stringValue = "Always open \(scope.pattern)\(scope.exact ? " (exact path)" : " and its subpaths") in the selected profile. Query and fragment ignored."
        } else {
            scopeHint.stringValue = remembering
                ? "Enter a path beginning with /. Leave out query strings and fragments."
                : "Return to open · Esc to close. Choose a scope above to remember this destination."
        }
        updateOpenButton()
    }

    private func updateOpenButton() {
        let remembering = scopePopup.indexOfSelectedItem > 0
        openButton.title = remembering ? "Save & Open" : "Open"
        openButton.isEnabled = choices.indices.contains(tableView.selectedRow)
            && (!remembering || selectedScope != nil)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateOpenButton()
    }

    private func applyTheme(_ theme: OverlayTheme) {
        self.theme = theme
        let isLight = theme == .light || theme == .catppuccinLatte
        panel.appearance = theme == .automatic ? nil : NSAppearance(named: isLight ? .aqua : .darkAqua)
        background.material = isLight ? .headerView : .hudWindow
        let palette = theme.catppuccinPalette
        let base = palette.flatMap { NSColor(hexRGB: $0.base) }
        let accent = palette.flatMap { NSColor(hexRGB: $0.mauve) }
        let text = palette.flatMap { NSColor(hexRGB: $0.text) }
        tint.layer?.backgroundColor = (base?.withAlphaComponent(0.94)
            ?? (theme == .black ? NSColor.black.withAlphaComponent(0.94)
                : (isLight ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.13)))).cgColor
        background.layer?.borderColor = (accent ?? .separatorColor).withAlphaComponent(0.4).cgColor
        searchSurface.layer?.borderColor = (accent ?? .separatorColor).withAlphaComponent(0.25).cgColor
        searchField.textColor = text ?? .labelColor
        urlLabel.textColor = text ?? .secondaryLabelColor
        scopeHint.textColor = text ?? .secondaryLabelColor
    }

    @objc private func confirmSelection() {
        let row = tableView.selectedRow
        guard choices.indices.contains(row),
            scopePopup.indexOfSelectedItem == 0 || selectedScope != nil
        else { return }
        let choice = choices[row]
        let scope = selectedScope
        panel.orderOut(nil)
        onPick?(choice, scope)
    }

    @objc private func cancel() {
        panel.orderOut(nil)
    }

    private func moveSelection(by delta: Int) {
        guard !choices.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let next = min(choices.count - 1, max(0, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

private final class LauncherTableRowView: NSTableRowView {
    var accent = NSColor.controlAccentColor
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        let rect = bounds.insetBy(dx: 2, dy: 1)
        accent.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
        accent.withAlphaComponent(0.3).setStroke()
        let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5)
        rim.lineWidth = 1
        rim.stroke()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class ProfileChoiceCellView: NSTableCellView {
    private let browserIcon = NSImageView()
    private let colorDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        browserIcon.imageScaling = .scaleProportionallyUpOrDown
        browserIcon.translatesAutoresizingMaskIntoConstraints = false

        colorDot.wantsLayer = true
        colorDot.layer?.cornerRadius = 5
        colorDot.layer?.borderWidth = 0.75
        colorDot.layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        colorDot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [browserIcon, colorDot, titleLabel, subtitleLabel] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            browserIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            browserIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            browserIcon.widthAnchor.constraint(equalToConstant: 30),
            browserIcon.heightAnchor.constraint(equalToConstant: 30),
            colorDot.leadingAnchor.constraint(equalTo: browserIcon.trailingAnchor, constant: 13),
            colorDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorDot.widthAnchor.constraint(equalToConstant: 10),
            colorDot.heightAnchor.constraint(equalToConstant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: colorDot.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(choice: ProfileChoice) {
        browserIcon.image = NSWorkspace.shared.icon(forFile: choice.browser.applicationURL.path)
        colorDot.layer?.backgroundColor = (choice.profile?.displayColor ?? .tertiaryLabelColor).cgColor
        titleLabel.stringValue = choice.profile?.displayName ?? "Default profile"
        subtitleLabel.stringValue = choice.browser.displayName
    }

    func applyTheme(_ theme: OverlayTheme) {
        let text = theme.catppuccinPalette.flatMap { NSColor(hexRGB: $0.text) }
        titleLabel.textColor = text ?? .labelColor
        subtitleLabel.textColor = text?.withAlphaComponent(0.8) ?? .secondaryLabelColor
    }
}
