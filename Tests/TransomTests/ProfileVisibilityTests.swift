import AppKit
import Testing
@testable import Transom

struct ProfileVisibilityTests {
    @Test func existingOverridesRemainVisible() throws {
        try withSettings { settings, defaults in
            defaults.set(Data(##"{"chrome:Default":{"displayName":"Work","colorHex":"#123456"}}"##.utf8),
                         forKey: "browserProfileOverrides")
            #expect(settings.isProfileVisibleInPicker(browser: .chrome, profileID: "Default"))
            #expect(settings.profileOverride(browser: .chrome, profileID: "Default")?.displayName == "Work")
            #expect(settings.profileOverride(browser: .chrome, profileID: "Default")?.colorHex == "#123456")
        }
    }

    @Test func visibilityPersistsIndependentlyOfOtherOverrides() throws {
        try withSettings { settings, defaults in
            settings.setProfileName("Work", browser: .chrome, profileID: "Default")
            settings.setProfileColor("#123456", browser: .chrome, profileID: "Default")
            settings.setProfileVisibleInPicker(false, browser: .chrome, profileID: "Default")
            let reloaded = AppSettings(defaults: defaults)
            #expect(!reloaded.isProfileVisibleInPicker(browser: .chrome, profileID: "Default"))
            #expect(reloaded.isProfileVisibleInPicker(browser: .helium, profileID: "Default"))
            settings.setProfileName(nil, browser: .chrome, profileID: "Default")
            settings.setProfileColor(nil, browser: .chrome, profileID: "Default")
            #expect(!settings.isProfileVisibleInPicker(browser: .chrome, profileID: "Default"))
            settings.setProfileVisibleInPicker(true, browser: .chrome, profileID: "Default")
            #expect(settings.profileOverride(browser: .chrome, profileID: "Default") == nil)

            settings.setProfileName("Personal", browser: .chrome, profileID: "Default")
            settings.setProfileVisibleInPicker(false, browser: .chrome, profileID: "Default")
            settings.setProfileVisibleInPicker(true, browser: .chrome, profileID: "Default")
            #expect(settings.profileOverride(browser: .chrome, profileID: "Default")?.displayName == "Personal")
        }
    }

    @Test func hiddenProfilesDoNotProduceFallbackChoices() throws {
        try withSettings { settings, _ in
            let profiles = ["Default", "Profile 1"].map {
                BrowserProfile(id: $0, name: $0, color: .blue, directory: nil)
            }
            let chrome = browser(.chrome, profiles: profiles)
            let helium = browser(.helium, profiles: profiles)
            settings.setProfileVisibleInPicker(false, browser: .chrome, profileID: "Default")
            let choices = ProfileChoice.pickerChoices(for: [chrome, helium], settings: settings)
            #expect(choices.count == 3)
            #expect(choices.first?.profile?.id == "Profile 1")
            settings.setProfileVisibleInPicker(false, browser: .chrome, profileID: "Profile 1")
            #expect(ProfileChoice.pickerChoices(for: [chrome], settings: settings).isEmpty)
            // A browser that genuinely has no discovered profiles still works.
            let fallback = ProfileChoice.pickerChoices(for: [browser(.firefox, profiles: [])], settings: settings)
            #expect(fallback.count == 1)
            #expect(fallback.first?.profile == nil)
            settings.setProfileVisibleInPicker(false, browser: .firefox, profileID: BrowserProfile.pickerDefaultID)
            #expect(ProfileChoice.pickerChoices(for: [browser(.firefox, profiles: [])], settings: settings).isEmpty)
            settings.setProfileVisibleInPicker(true, browser: .chrome, profileID: "Default")
            #expect(ProfileChoice.pickerChoices(for: [chrome], settings: settings).first?.profile?.id == "Default")
        }
    }

    @Test func fallbackProfileSupportsCustomizationWithoutBecomingALaunchProfile() throws {
        try withSettings { settings, _ in
            settings.setProfileName("Default Work", browser: .chrome, profileID: BrowserProfile.pickerDefaultID)
            settings.setProfileColor("#123456", browser: .chrome, profileID: BrowserProfile.pickerDefaultID)
            let display = BrowserProfile.pickerDefault(browser: .chrome, settings: settings)
            #expect(display.displayName == "Default Work")
            #expect(display.displayColor.hexRGB == "#123456")
            #expect(display.directory == nil)
            let choice = try #require(ProfileChoice.pickerChoices(for: [browser(.chrome, profiles: [])], settings: settings).first)
            #expect(choice.profile == nil)
        }
    }

    private func browser(_ kind: BrowserKind, profiles: [BrowserProfile]) -> InstalledBrowser {
        let root = URL(fileURLWithPath: "/synthetic/\(kind.rawValue)")
        return InstalledBrowser(kind: kind, family: .chromium, bundleIdentifier: "test.\(kind.rawValue)",
                                applicationURL: root, executableURL: root, profileRoot: root, profiles: profiles)
    }

    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let suite = "TransomTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults), defaults)
    }
}
