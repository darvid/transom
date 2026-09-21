import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var workspaceController: WorkspaceController?
    private var routingController: RoutingController?
    private var settingsController: SettingsController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let registry = BrowserRegistry()
        let routingController = RoutingController(registry: registry)
        let workspaceController = WorkspaceController(registry: registry)
        let settingsController = SettingsController(
            registry: registry,
            routingStore: routingController.store
        )
        workspaceController.onShowSettings = { [weak settingsController] in
            settingsController?.show()
        }
        workspaceController.onShowRoutingRules = { [weak routingController] in
            routingController?.showRules()
        }
        workspaceController.onRegisterAsDefaultBrowser = { [weak routingController] in
            routingController?.registerAsDefaultBrowser()
        }
        routingController.onShowRules = { [weak settingsController] in
            settingsController?.showLinks()
        }
        settingsController.onRegisterAsDefaultBrowser = { [weak routingController] in
            routingController?.registerAsDefaultBrowser()
        }
        settingsController.onRescanBrowsers = { [weak workspaceController] in
            workspaceController?.rescanBrowsers()
        }
        settingsController.onSettingsChanged = { [weak workspaceController] in
            workspaceController?.settingsDidChange()
        }

        self.routingController = routingController
        self.workspaceController = workspaceController
        self.settingsController = settingsController
        workspaceController.start()

        for url in pendingURLs {
            routingController.handle(url)
        }
        pendingURLs.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let routingController else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            routingController.handle(url)
        }
    }
}
