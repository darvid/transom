import AppKit
import ApplicationServices

enum BrowserFamily {
    case chromium
    case firefox
}

enum BrowserKind: String, CaseIterable, Hashable, Codable {
    case chrome
    case edge
    case brave
    case vivaldi
    case opera
    case arc
    case chromium
    case helium
    case firefox
    case zen

    var displayName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .arc: "Arc"
        case .chromium: "Chromium"
        case .helium: "Helium"
        case .firefox: "Firefox"
        case .zen: "Zen"
        }
    }
}

struct BrowserProfile: Equatable {
    let id: String
    let name: String
    let color: NSColor
    let directory: URL?
    let customName: String?
    let customColor: NSColor?

    init(
        id: String,
        name: String,
        color: NSColor,
        directory: URL?,
        customName: String? = nil,
        customColor: NSColor? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.directory = directory
        self.customName = customName
        self.customColor = customColor
    }

    var displayName: String { customName ?? name }
    var displayColor: NSColor { customColor ?? color }
}

extension NSColor {
    convenience init?(hexRGB: String) {
        let value = hexRGB.hasPrefix("#") ? String(hexRGB.dropFirst()) : hexRGB
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }

    var hexRGB: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

struct InstalledBrowser: Equatable {
    let kind: BrowserKind
    let family: BrowserFamily
    let bundleIdentifier: String
    let applicationURL: URL
    let executableURL: URL
    let profileRoot: URL
    let profiles: [BrowserProfile]

    var displayName: String { kind.displayName }

    static func == (lhs: InstalledBrowser, rhs: InstalledBrowser) -> Bool {
        lhs.kind == rhs.kind && lhs.applicationURL == rhs.applicationURL
            && lhs.profiles == rhs.profiles
    }
}

struct BrowserWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let browser: InstalledBrowser
    let title: String
    let profile: BrowserProfile?
    let frame: CGRect
    let element: AXUIElement

    static func == (lhs: BrowserWindow, rhs: BrowserWindow) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid
            && lhs.browser.kind == rhs.browser.kind && lhs.title == rhs.title
            && lhs.profile == rhs.profile && lhs.frame == rhs.frame
    }
}

enum ContainerGeometry {
    static let tabHeight: CGFloat = 44
    static let tabOverlap: CGFloat = 18
    static let shellInset: CGFloat = 6
    static let resizeHitWidth: CGFloat = 10
    static let minimumBrowserSize = CGSize(width: 520, height: 360)

    static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: rect.minX,
            y: primaryTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: rect.minX,
            y: primaryTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func moved(_ frame: CGRect, byAppKitDelta delta: CGPoint) -> CGRect {
        frame.offsetBy(dx: delta.x, dy: -delta.y)
    }

    static func browserFrame(fittingOuterFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: frame.minY + tabHeight,
            width: frame.width,
            height: max(minimumBrowserSize.height, frame.height - tabHeight)
        ).integral
    }

    static func resized(
        _ frame: CGRect,
        edge: ResizeEdge,
        byAppKitDelta delta: CGPoint
    ) -> CGRect {
        var result = frame
        let quartzDX = delta.x
        let quartzDY = -delta.y

        if edge.contains(.left) {
            let proposedWidth = result.width - quartzDX
            let acceptedDX = min(quartzDX, result.width - minimumBrowserSize.width)
            if proposedWidth >= minimumBrowserSize.width || acceptedDX < 0 {
                result.origin.x += acceptedDX
                result.size.width -= acceptedDX
            }
        }
        if edge.contains(.right) {
            result.size.width = max(minimumBrowserSize.width, result.width + quartzDX)
        }
        if edge.contains(.top) {
            let proposedHeight = result.height - quartzDY
            let acceptedDY = min(quartzDY, result.height - minimumBrowserSize.height)
            if proposedHeight >= minimumBrowserSize.height || acceptedDY < 0 {
                result.origin.y += acceptedDY
                result.size.height -= acceptedDY
            }
        }
        if edge.contains(.bottom) {
            result.size.height = max(minimumBrowserSize.height, result.height + quartzDY)
        }

        return result.integral
    }
}

struct ResizeEdge: OptionSet, Equatable {
    let rawValue: Int

    static let left = ResizeEdge(rawValue: 1 << 0)
    static let right = ResizeEdge(rawValue: 1 << 1)
    static let top = ResizeEdge(rawValue: 1 << 2)
    static let bottom = ResizeEdge(rawValue: 1 << 3)
}
