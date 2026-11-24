import AppKit
import ApplicationServices

struct CompletionReturnLocation {
    let pid: pid_t
    let window: AXUIElement

    static func capture(pid: pid_t) -> Self? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                AXUIElementSetMessagingTimeout(window, 0.12)
                return Self(pid: pid, window: window)
            }
        }
        return nil
    }

    func isAvailable() -> Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success &&
            role as? String == kAXWindowRole
    }

    func restore() -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, isAvailable() else { return false }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           minimized as? Bool == true {
            guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                return false
            }
        }
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        return app.activate()
    }
}
