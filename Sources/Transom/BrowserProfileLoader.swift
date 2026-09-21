import AppKit
import Foundation

enum BrowserProfileLoader {
    static func load(
        family: BrowserFamily,
        kind: BrowserKind,
        root: URL
    ) -> [BrowserProfile] {
        switch family {
        case .chromium:
            chromiumProfiles(kind: kind, root: root)
        case .firefox:
            firefoxProfiles(kind: kind, root: root)
        }
    }

    static func matchingProfile(
        forWindowTitle title: String,
        in profiles: [BrowserProfile]
    ) -> BrowserProfile? {
        profiles
            .filter { title.hasSuffix(" - \($0.name)") }
            .max { $0.name.count < $1.name.count }
    }

    private static func chromiumProfiles(
        kind: BrowserKind,
        root: URL
    ) -> [BrowserProfile] {
        let localStateURL = root.appendingPathComponent("Local State")
        guard
            let data = try? Data(contentsOf: localStateURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = json["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: [String: Any]]
        else {
            return []
        }

        return infoCache.map { id, info in
            let name = info["name"] as? String ?? id
            return BrowserProfile(
                id: id,
                name: name,
                color: chromiumColor(info["profile_highlight_color"])
                    ?? fallbackColor(for: "\(kind.rawValue):\(id)"),
                directory: root.appendingPathComponent(id)
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func firefoxProfiles(
        kind: BrowserKind,
        root: URL
    ) -> [BrowserProfile] {
        guard let contents = try? String(
            contentsOf: root.appendingPathComponent("profiles.ini"),
            encoding: .utf8
        ) else {
            return []
        }

        var profiles: [BrowserProfile] = []
        var name: String?
        var path: String?
        var isRelative = true

        func flush() {
            guard let name, let path else { return }
            let directory = isRelative
                ? root.appendingPathComponent(path)
                : URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return
            }
            profiles.append(
                BrowserProfile(
                    id: directory.lastPathComponent,
                    name: name,
                    color: fallbackColor(for: "\(kind.rawValue):\(directory.lastPathComponent)"),
                    directory: directory
                )
            )
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                flush()
                name = nil
                path = nil
                isRelative = true
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "Name": name = value
            case "Path": path = value
            case "IsRelative": isRelative = value == "1"
            default: break
            }
        }
        flush()

        return profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func chromiumColor(_ value: Any?) -> NSColor? {
        let raw: UInt32?
        switch value {
        case let number as NSNumber:
            raw = UInt32(truncating: number)
        case let string as String:
            raw = UInt32(string.replacingOccurrences(of: "#", with: ""), radix: 16)
        default:
            raw = nil
        }
        guard let raw else { return nil }
        return adaptForDarkBackground(
            red: CGFloat((raw >> 16) & 0xff) / 255,
            green: CGFloat((raw >> 8) & 0xff) / 255,
            blue: CGFloat(raw & 0xff) / 255
        )
    }

    private static func adaptForDarkBackground(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> NSColor {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        if maximum != minimum {
            let delta = maximum - minimum
            saturation = lightness > 0.5
                ? delta / (2 - maximum - minimum)
                : delta / (maximum + minimum)
            if maximum == red {
                hue = ((green - blue) / delta + (green < blue ? 6 : 0)) / 6
            } else if maximum == green {
                hue = ((blue - red) / delta + 2) / 6
            } else {
                hue = ((red - green) / delta + 4) / 6
            }
        }

        saturation = max(saturation, 0.45)
        let adaptedLightness = max(lightness, 0.55)
        let chroma = (1 - abs(2 * adaptedLightness - 1)) * saturation
        let hueSection = hue * 6
        let intermediate = chroma * (1 - abs(hueSection.truncatingRemainder(dividingBy: 2) - 1))
        let base: (CGFloat, CGFloat, CGFloat)
        switch hueSection {
        case 0 ..< 1: base = (chroma, intermediate, 0)
        case 1 ..< 2: base = (intermediate, chroma, 0)
        case 2 ..< 3: base = (0, chroma, intermediate)
        case 3 ..< 4: base = (0, intermediate, chroma)
        case 4 ..< 5: base = (intermediate, 0, chroma)
        default: base = (chroma, 0, intermediate)
        }
        let offset = adaptedLightness - chroma / 2
        return NSColor(
            calibratedRed: base.0 + offset,
            green: base.1 + offset,
            blue: base.2 + offset,
            alpha: 1
        )
    }

    private static func fallbackColor(for seed: String) -> NSColor {
        let palette: [NSColor] = [
            .systemBlue,
            .systemTeal,
            .systemGreen,
            .systemYellow,
            .systemOrange,
            .systemPink,
            .systemPurple,
            .systemIndigo,
        ]
        let hash = seed.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
