import AppKit

final class ResizeHandleController {
    let edge: ResizeEdge
    let panel: NSPanel
    var onResize: ((ResizeEdge, CGPoint) -> Void)?
    var onResizeEnded: (() -> Void)?

    init(edge: ResizeEdge) {
        self.edge = edge
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        let view = ResizeHandleView(edge: edge)
        panel.contentView = view
        view.onResize = { [weak self] delta in
            guard let self else { return }
            self.onResize?(self.edge, delta)
        }
        view.onResizeEnded = { [weak self] in
            self?.onResizeEnded?()
        }
    }

    func position(around browserFrame: CGRect) {
        let frame = ContainerGeometry.appKitRect(fromQuartz: browserFrame)
        let hit = ContainerGeometry.resizeHitWidth
        let inset = ContainerGeometry.shellInset
        let panelFrame: CGRect

        switch edge {
        case .left:
            panelFrame = CGRect(
                x: frame.minX - hit / 2,
                y: frame.minY - inset,
                width: hit,
                height: frame.height + inset + ContainerGeometry.tabHeight
            )
        case .right:
            panelFrame = CGRect(
                x: frame.maxX - hit / 2,
                y: frame.minY - inset,
                width: hit,
                height: frame.height + inset + ContainerGeometry.tabHeight
            )
        case .bottom:
            panelFrame = CGRect(
                x: frame.minX,
                y: frame.minY - inset - hit / 2,
                width: frame.width,
                height: hit
            )
        default:
            panelFrame = CGRect(
                x: frame.minX,
                y: frame.maxY + ContainerGeometry.tabHeight - hit / 2,
                width: frame.width,
                height: hit
            )
        }

        panel.setFrame(panelFrame, display: true)
    }

    func close() {
        panel.orderOut(nil)
    }
}

private final class ResizeHandleView: NSView {
    let edge: ResizeEdge
    var onResize: ((CGPoint) -> Void)?
    var onResizeEnded: (() -> Void)?
    private var lastLocation: CGPoint?

    init(edge: ResizeEdge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        let cursor: NSCursor = edge == .left || edge == .right
            ? .resizeLeftRight
            : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        lastLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        guard let previous = lastLocation else {
            lastLocation = location
            return
        }
        let delta = CGPoint(x: location.x - previous.x, y: location.y - previous.y)
        lastLocation = location
        onResize?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        lastLocation = nil
        onResizeEnded?()
    }
}
