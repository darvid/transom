import AppKit

final class ContainerShellView: NSVisualEffectView {
    private let baseFill = CALayer()
    private let gloss = CAGradientLayer()
    private let outerRim = CAShapeLayer()
    private let innerRim = CAShapeLayer()
    private var theme = OverlayTheme.automatic

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true

        layer?.addSublayer(baseFill)

        gloss.startPoint = CGPoint(x: 0.5, y: 1)
        gloss.endPoint = CGPoint(x: 0.5, y: 0)
        gloss.locations = [0, 0.42, 1]
        layer?.addSublayer(gloss)

        outerRim.fillColor = NSColor.clear.cgColor
        outerRim.lineWidth = 1.5
        layer?.addSublayer(outerRim)

        innerRim.fillColor = NSColor.clear.cgColor
        innerRim.lineWidth = 0.5
        layer?.addSublayer(innerRim)
        applyTheme(AppSettings.shared.overlayTheme)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        baseFill.frame = bounds
        gloss.frame = bounds

        outerRim.frame = bounds
        outerRim.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: 11.25,
            cornerHeight: 11.25,
            transform: nil
        )

        innerRim.frame = bounds
        innerRim.path = CGPath(
            roundedRect: bounds.insetBy(dx: 3, dy: 3),
            cornerWidth: 9,
            cornerHeight: 9,
            transform: nil
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterials()
    }

    func applyTheme(_ theme: OverlayTheme) {
        self.theme = theme
        switch theme {
        case .automatic:
            appearance = nil
            material = .hudWindow
            baseFill.backgroundColor = NSColor.clear.cgColor
        case .light:
            appearance = NSAppearance(named: .aqua)
            material = .headerView
            baseFill.backgroundColor = NSColor.white.withAlphaComponent(0.42).cgColor
        case .black:
            appearance = NSAppearance(named: .darkAqua)
            material = .hudWindow
            baseFill.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
        case .catppuccinLatte, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha:
            appearance = NSAppearance(named: theme == .catppuccinLatte ? .aqua : .darkAqua)
            material = theme == .catppuccinLatte ? .headerView : .hudWindow
            if let palette = theme.catppuccinPalette {
                baseFill.backgroundColor = NSColor(hexRGB: palette.base)?.withAlphaComponent(0.94).cgColor
            }
        }
        updateMaterials()
    }

    private func updateMaterials() {
        if let palette = theme.catppuccinPalette {
            let mauve = NSColor(hexRGB: palette.mauve) ?? .systemPurple
            let text = NSColor(hexRGB: palette.text) ?? .labelColor
            outerRim.strokeColor = mauve.withAlphaComponent(0.35).cgColor
            innerRim.strokeColor = text.withAlphaComponent(0.08).cgColor
            gloss.colors = [
                mauve.withAlphaComponent(0.12).cgColor,
                mauve.withAlphaComponent(0.025).cgColor,
                NSColor.clear.cgColor,
            ]
            return
        }
        let isDark = theme == .black || (theme == .automatic
            && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

        outerRim.strokeColor = NSColor.white
            .withAlphaComponent(theme == .black ? 0.22 : (isDark ? 0.30 : 0.46))
            .cgColor
        innerRim.strokeColor = NSColor.white
            .withAlphaComponent(theme == .black ? 0.08 : (isDark ? 0.12 : 0.20))
            .cgColor
        gloss.colors = [
            NSColor.white
                .withAlphaComponent(theme == .black ? 0.10 : (isDark ? 0.22 : 0.32))
                .cgColor,
            NSColor.white
                .withAlphaComponent(theme == .black ? 0.025 : 0.05)
                .cgColor,
            NSColor.clear.cgColor,
        ]
    }
}
