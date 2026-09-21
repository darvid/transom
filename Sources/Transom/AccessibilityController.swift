import AppKit
import ApplicationServices

struct AccessibilityController {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func windows(for pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return attribute(kAXWindowsAttribute, from: app) as? [AXUIElement] ?? []
    }

    func title(of element: AXUIElement) -> String {
        attribute(kAXTitleAttribute, from: element) as? String ?? ""
    }

    func document(of element: AXUIElement) -> String? {
        guard let document = attribute(kAXDocumentAttribute, from: element) as? String,
            !document.isEmpty
        else {
            return nil
        }
        return document
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard
            let rawPosition = attribute(kAXPositionAttribute, from: element),
            let rawSize = attribute(kAXSizeAttribute, from: element),
            CFGetTypeID(rawPosition) == AXValueGetTypeID(),
            CFGetTypeID(rawSize) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)

        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue, .cgPoint, &position),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    func windowNumber(of element: AXUIElement) -> CGWindowID? {
        guard let number = attribute("AXWindowNumber", from: element) as? NSNumber else {
            return nil
        }
        return CGWindowID(number.uint32Value)
    }

    @discardableResult
    func setFrame(_ frame: CGRect, of element: AXUIElement) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard
            let positionValue = AXValueCreate(.cgPoint, &position),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let moved = AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            positionValue
        ) == .success
        let resized = AXUIElementSetAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            sizeValue
        ) == .success
        return moved && resized
    }

    @discardableResult
    func raise(_ window: BrowserWindow) -> Bool {
        let mainResult = AXUIElementSetAttributeValue(
            window.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let focusResult = AXUIElementSetAttributeValue(
            window.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        let raiseResult = AXUIElementPerformAction(
            window.element,
            kAXRaiseAction as CFString
        )
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid {
            NSRunningApplication(processIdentifier: window.pid)?.activate(
                options: [.activateIgnoringOtherApps]
            )
        }
        return raiseResult == .success || mainResult == .success || focusResult == .success
    }

    private func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
