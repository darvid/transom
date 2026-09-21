import AppKit

final class RoutingController {
    var onShowRules: (() -> Void)?

    let store = RoutingStore()
    private let registry: BrowserRegistry
    private let launcher = BrowserLauncher()
    private let picker = ProfilePickerController()
    private var isRegisteringDefaultBrowser = false

    init(registry: BrowserRegistry) {
        self.registry = registry
    }

    func handle(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        registry.refresh()

        if !NSEvent.modifierFlags.contains(.option), let rule = store.matchingRule(for: url),
           let choice = choice(for: rule)
        {
            launch(url, with: choice)
            return
        }

        picker.show(url: url, browsers: registry.browsers) { [weak self] choice, scope in
            guard let self else { return }
            if let scope {
                self.store.add(
                    RoutingRule(
                        matcher: scope.matcher,
                        pattern: scope.pattern,
                        browser: choice.browser.kind,
                        profileID: choice.profile?.id
                    )
                )
            }
            self.launch(url, with: choice)
        }
    }

    func showRules() {
        onShowRules?()
    }

    func registerAsDefaultBrowser() {
        guard !isRegisteringDefaultBrowser else { return }
        isRegisteringDefaultBrowser = true
        DefaultBrowserRegistrar().register(applicationURL: Bundle.main.bundleURL) { error in
            self.isRegisteringDefaultBrowser = false
            let alert = NSAlert()
            if let error {
                alert.alertStyle = .warning
                alert.messageText = "Transom could not become the default browser"
                alert.informativeText = error.localizedDescription
            } else {
                alert.alertStyle = .informational
                alert.messageText = "Transom is now the default web link handler"
                alert.informativeText = "Unmatched links will open the profile picker. Routing rules can send known URLs directly to a profile."
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func choice(for rule: RoutingRule) -> ProfileChoice? {
        guard let browser = registry.browsers.first(where: { $0.kind == rule.browser }) else {
            return nil
        }
        let profile = rule.profileID.flatMap { id in
            browser.profiles.first { $0.id == id }
        }
        if rule.profileID != nil, profile == nil {
            return nil
        }
        return ProfileChoice(browser: browser, profile: profile)
    }

    private func launch(_ url: URL, with choice: ProfileChoice) {
        if case let .failure(error) = launcher.launch(
            url: url,
            browser: choice.browser,
            profile: choice.profile
        ) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not open the link"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
