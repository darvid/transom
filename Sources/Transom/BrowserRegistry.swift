import AppKit
import Foundation

final class BrowserRegistry {
    private(set) var browsers: [InstalledBrowser] = []
    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
        refresh()
    }

    func refresh() {
        browsers = Self.definitions.compactMap(discoverBrowser)
    }

    func browser(for runningApplication: NSRunningApplication) -> InstalledBrowser? {
        if let bundleIdentifier = runningApplication.bundleIdentifier,
           let exact = browsers.first(where: { $0.bundleIdentifier == bundleIdentifier })
        {
            return exact
        }

        guard let executablePath = runningApplication.executableURL?
            .standardizedFileURL.path.lowercased()
        else {
            return nil
        }
        return browsers.first {
            executablePath == $0.executableURL.standardizedFileURL.path.lowercased()
                || Self.pathPatterns(for: $0.kind).contains(where: executablePath.contains)
        }
    }

    private func discoverBrowser(_ definition: BrowserDefinition) -> InstalledBrowser? {
        let workspace = NSWorkspace.shared
        let applicationURL = definition.bundleIdentifiers
            .lazy
            .compactMap(workspace.urlForApplication(withBundleIdentifier:))
            .first
            ?? definition.applicationURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) })

        guard
            let applicationURL,
            let bundle = Bundle(url: applicationURL),
            let executableURL = bundle.executableURL,
            FileManager.default.fileExists(atPath: definition.profileRoot.path)
        else {
            return nil
        }

        let profiles = BrowserProfileLoader.load(
            family: definition.family,
            kind: definition.kind,
            root: definition.profileRoot
        ).map { profile in
            let profileOverride = settings.profileOverride(
                browser: definition.kind,
                profileID: profile.id
            )
            return BrowserProfile(
                id: profile.id,
                name: profile.name,
                color: profile.color,
                directory: profile.directory,
                customName: profileOverride?.displayName,
                customColor: profileOverride?.colorHex.flatMap(NSColor.init(hexRGB:))
            )
        }
        return InstalledBrowser(
            kind: definition.kind,
            family: definition.family,
            bundleIdentifier: bundle.bundleIdentifier
                ?? definition.bundleIdentifiers.first
                ?? definition.kind.rawValue,
            applicationURL: applicationURL,
            executableURL: executableURL,
            profileRoot: definition.profileRoot,
            profiles: profiles
        )
    }

    private static func pathPatterns(for kind: BrowserKind) -> [String] {
        switch kind {
        case .chrome: ["google chrome.app", "google/chrome"]
        case .edge: ["microsoft edge.app", "microsoft/edge"]
        case .brave: ["brave browser.app", "brave-browser"]
        case .vivaldi: ["vivaldi.app"]
        case .opera: ["opera.app"]
        case .arc: ["arc.app/contents/macos/arc"]
        case .chromium: ["chromium.app"]
        case .helium: ["helium.app"]
        case .firefox: ["firefox.app"]
        case .zen: ["zen browser.app", "zen.app"]
        }
    }

    private static let definitions: [BrowserDefinition] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)

        func applications(_ name: String) -> [URL] {
            [
                URL(fileURLWithPath: "/Applications/\(name).app"),
                home.appendingPathComponent("Applications/\(name).app"),
            ]
        }

        return [
            BrowserDefinition(
                kind: .chrome,
                family: .chromium,
                bundleIdentifiers: ["com.google.Chrome"],
                applicationURLs: applications("Google Chrome"),
                profileRoot: support.appendingPathComponent("Google/Chrome")
            ),
            BrowserDefinition(
                kind: .edge,
                family: .chromium,
                bundleIdentifiers: ["com.microsoft.edgemac"],
                applicationURLs: applications("Microsoft Edge"),
                profileRoot: support.appendingPathComponent("Microsoft Edge")
            ),
            BrowserDefinition(
                kind: .brave,
                family: .chromium,
                bundleIdentifiers: ["com.brave.Browser"],
                applicationURLs: applications("Brave Browser"),
                profileRoot: support.appendingPathComponent("BraveSoftware/Brave-Browser")
            ),
            BrowserDefinition(
                kind: .vivaldi,
                family: .chromium,
                bundleIdentifiers: ["com.vivaldi.Vivaldi"],
                applicationURLs: applications("Vivaldi"),
                profileRoot: support.appendingPathComponent("Vivaldi")
            ),
            BrowserDefinition(
                kind: .opera,
                family: .chromium,
                bundleIdentifiers: ["com.operasoftware.Opera"],
                applicationURLs: applications("Opera"),
                profileRoot: support.appendingPathComponent("com.operasoftware.Opera")
            ),
            BrowserDefinition(
                kind: .arc,
                family: .chromium,
                bundleIdentifiers: ["company.thebrowser.Browser"],
                applicationURLs: applications("Arc"),
                profileRoot: support.appendingPathComponent("Arc/User Data")
            ),
            BrowserDefinition(
                kind: .chromium,
                family: .chromium,
                bundleIdentifiers: ["org.chromium.Chromium"],
                applicationURLs: applications("Chromium"),
                profileRoot: support.appendingPathComponent("Chromium")
            ),
            BrowserDefinition(
                kind: .helium,
                family: .chromium,
                bundleIdentifiers: ["net.imput.helium"],
                applicationURLs: applications("Helium"),
                profileRoot: support.appendingPathComponent("net.imput.helium")
            ),
            BrowserDefinition(
                kind: .firefox,
                family: .firefox,
                bundleIdentifiers: ["org.mozilla.firefox"],
                applicationURLs: applications("Firefox"),
                profileRoot: support.appendingPathComponent("Firefox")
            ),
            BrowserDefinition(
                kind: .zen,
                family: .firefox,
                bundleIdentifiers: ["app.zen-browser.zen", "io.zen-browser.zen"],
                applicationURLs: applications("Zen Browser") + applications("Zen"),
                profileRoot: support.appendingPathComponent("zen")
            ),
        ]
    }()
}

private struct BrowserDefinition {
    let kind: BrowserKind
    let family: BrowserFamily
    let bundleIdentifiers: [String]
    let applicationURLs: [URL]
    let profileRoot: URL
}
