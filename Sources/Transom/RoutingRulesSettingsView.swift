import AppKit

final class RoutingRulesSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: RoutingStore
    private let registry: BrowserRegistry
    private let tableView = NSTableView()
    private let matcherPopup = NSPopUpButton()
    private let patternField = NSTextField()
    private let browserPopup = NSPopUpButton()
    private let profilePopup = NSPopUpButton()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    init(store: RoutingStore, registry: BrowserRegistry) {
        self.store = store
        self.registry = registry
        super.init(frame: .zero)

        let patternColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pattern"))
        patternColumn.title = "Match"
        patternColumn.width = 300
        let destinationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination"))
        destinationColumn.title = "Destination"
        destinationColumn.width = 260
        tableView.addTableColumn(patternColumn)
        tableView.addTableColumn(destinationColumn)
        tableView.rowHeight = 27
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        matcherPopup.addItems(withTitles: RoutingRule.Matcher.allCases.map(\.rawValue))
        matcherPopup.controlSize = .small
        matcherPopup.target = self
        matcherPopup.action = #selector(matcherChanged)
        matcherPopup.translatesAutoresizingMaskIntoConstraints = false
        patternField.placeholderString = "*.example.com"
        patternField.controlSize = .small
        patternField.translatesAutoresizingMaskIntoConstraints = false
        browserPopup.controlSize = .small
        browserPopup.target = self
        browserPopup.action = #selector(browserChanged)
        browserPopup.translatesAutoresizingMaskIntoConstraints = false
        profilePopup.controlSize = .small
        profilePopup.translatesAutoresizingMaskIntoConstraints = false

        addButton.controlSize = .small
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addRule)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.controlSize = .small
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedRule)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        let editor = NSStackView(views: [
            matcherPopup,
            patternField,
            browserPopup,
            profilePopup,
            addButton,
            deleteButton,
        ])
        editor.orientation = .horizontal
        editor.alignment = .centerY
        editor.spacing = 7
        editor.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(editor)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 155),
            editor.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            editor.leadingAnchor.constraint(equalTo: leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor),
            patternField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            browserPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 105),
            profilePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 105),
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refresh() {
        registry.refresh()
        browserPopup.removeAllItems()
        browserPopup.addItems(withTitles: registry.browsers.map(\.displayName))
        refreshProfileMenu()
        addButton.isEnabled = !registry.browsers.isEmpty
        tableView.reloadData()
        updateDeleteButton()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.rules.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let rule = store.rules[row]
        let value: String
        if tableColumn?.identifier.rawValue == "pattern" {
            value = "\(rule.matcher.rawValue):  \(rule.pattern)"
        } else {
            let browser = registry.browsers.first { $0.kind == rule.browser }
            let profile = browser?.profiles.first { $0.id == rule.profileID }
            value = "\(browser?.displayName ?? rule.browser.displayName) · \(profile?.displayName ?? "Default")"
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDeleteButton()
    }

    @objc private func browserChanged() {
        refreshProfileMenu()
    }

    @objc private func matcherChanged() {
        let matcher = RoutingRule.Matcher.allCases[matcherPopup.indexOfSelectedItem]
        patternField.placeholderString = matcher == .hostPathPrefix || matcher == .hostPathExact
            ? "github.com/owner/repository" : "Pattern"
    }

    @objc private func addRule() {
        let pattern = patternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty,
              matcherPopup.indexOfSelectedItem >= 0,
              registry.browsers.indices.contains(browserPopup.indexOfSelectedItem)
        else {
            NSSound.beep()
            return
        }

        let matcher = RoutingRule.Matcher.allCases[matcherPopup.indexOfSelectedItem]
        if matcher == .hostPathPrefix || matcher == .hostPathExact {
            guard RoutingScope(pattern: pattern, exact: matcher == .hostPathExact) != nil else {
                let alert = NSAlert()
                alert.messageText = "Enter a host and path"
                alert.informativeText = "For example: github.com/owner/repository. Omit the scheme, query string, and fragment."
                alert.runModal()
                return
            }
        }
        let browser = registry.browsers[browserPopup.indexOfSelectedItem]
        let profile = browser.profiles.indices.contains(profilePopup.indexOfSelectedItem)
            ? browser.profiles[profilePopup.indexOfSelectedItem]
            : nil
        store.add(RoutingRule(
            matcher: matcher,
            pattern: pattern,
            browser: browser.kind,
            profileID: profile?.id
        ))
        patternField.stringValue = ""
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    @objc private func deleteSelectedRule() {
        let row = tableView.selectedRow
        guard store.rules.indices.contains(row) else { return }
        store.remove(id: store.rules[row].id)
        tableView.reloadData()
        updateDeleteButton()
    }

    private func refreshProfileMenu() {
        profilePopup.removeAllItems()
        guard registry.browsers.indices.contains(browserPopup.indexOfSelectedItem) else {
            return
        }
        let browser = registry.browsers[browserPopup.indexOfSelectedItem]
        if browser.profiles.isEmpty {
            profilePopup.addItem(withTitle: "Default")
        } else {
            profilePopup.addItems(withTitles: browser.profiles.map(\.displayName))
        }
    }

    private func updateDeleteButton() {
        deleteButton.isEnabled = store.rules.indices.contains(tableView.selectedRow)
    }
}
