import Foundation

struct BrowserProfileOverride: Codable, Equatable {
    var displayName: String?
    var colorHex: String?
}

enum OverlayTheme: String, CaseIterable {
    case automatic
    case light
    case black
    case catppuccinLatte
    case catppuccinFrappe
    case catppuccinMacchiato
    case catppuccinMocha

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .black: "Black"
        case .catppuccinLatte: "Catppuccin Latte"
        case .catppuccinFrappe: "Catppuccin Frappé"
        case .catppuccinMacchiato: "Catppuccin Macchiato"
        case .catppuccinMocha: "Catppuccin Mocha"
        }
    }

    var catppuccinPalette: (base: String, mauve: String, text: String)? {
        switch self {
        case .catppuccinLatte: ("#eff1f5", "#8839ef", "#4c4f69")
        case .catppuccinFrappe: ("#303446", "#ca9ee6", "#c6d0f5")
        case .catppuccinMacchiato: ("#24273a", "#c6a0f6", "#cad3f5")
        case .catppuccinMocha: ("#1e1e2e", "#cba6f7", "#cdd6f4")
        default: nil
        }
    }
}

final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let tileManagerCompatibility = "tileManagerCompatibility"
        static let keepOverlayAboveInactiveWindows = "keepOverlayAboveInactiveWindows"
        static let overlayTheme = "overlayTheme"
        static let browserProfileOverrides = "browserProfileOverrides"
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.tileManagerCompatibility: true,
            Key.keepOverlayAboveInactiveWindows: true,
            Key.overlayTheme: OverlayTheme.automatic.rawValue,
        ])
    }

    var tileManagerCompatibility: Bool {
        get { defaults.bool(forKey: Key.tileManagerCompatibility) }
        set { defaults.set(newValue, forKey: Key.tileManagerCompatibility) }
    }

    var keepOverlayAboveInactiveWindows: Bool {
        get { defaults.bool(forKey: Key.keepOverlayAboveInactiveWindows) }
        set { defaults.set(newValue, forKey: Key.keepOverlayAboveInactiveWindows) }
    }

    var overlayTheme: OverlayTheme {
        get {
            OverlayTheme(rawValue: defaults.string(forKey: Key.overlayTheme) ?? "")
                ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: Key.overlayTheme) }
    }

    func profileOverride(browser: BrowserKind, profileID: String) -> BrowserProfileOverride? {
        profileOverrides[Self.profileKey(browser: browser, profileID: profileID)]
    }

    func profileOrder(browser: BrowserKind) -> [String] {
        defaults.stringArray(forKey: "profileOrder.\(browser.rawValue)") ?? []
    }

    func setProfileOrder(_ profileIDs: [String], browser: BrowserKind) {
        var order: [String] = []
        for id in profileIDs + profileOrder(browser: browser) where !order.contains(id) {
            order.append(id)
        }
        defaults.set(order, forKey: "profileOrder.\(browser.rawValue)")
    }

    func setProfileName(_ name: String?, browser: BrowserKind, profileID: String) {
        updateProfileOverride(browser: browser, profileID: profileID) {
            $0.displayName = name
        }
    }

    func setProfileColor(_ colorHex: String?, browser: BrowserKind, profileID: String) {
        updateProfileOverride(browser: browser, profileID: profileID) {
            $0.colorHex = colorHex
        }
    }

    private var profileOverrides: [String: BrowserProfileOverride] {
        get {
            guard let data = defaults.data(forKey: Key.browserProfileOverrides) else {
                return [:]
            }
            return (try? JSONDecoder().decode([String: BrowserProfileOverride].self, from: data))
                ?? [:]
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.browserProfileOverrides)
        }
    }

    private func updateProfileOverride(
        browser: BrowserKind,
        profileID: String,
        update: (inout BrowserProfileOverride) -> Void
    ) {
        var overrides = profileOverrides
        let key = Self.profileKey(browser: browser, profileID: profileID)
        var profileOverride = overrides[key] ?? BrowserProfileOverride()
        update(&profileOverride)
        if profileOverride.displayName == nil, profileOverride.colorHex == nil {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = profileOverride
        }
        profileOverrides = overrides
    }

    private static func profileKey(browser: BrowserKind, profileID: String) -> String {
        "\(browser.rawValue):\(profileID)"
    }
}
