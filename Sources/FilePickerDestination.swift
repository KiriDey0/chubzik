import AppKit
import ApplicationServices

struct FilePickerDestination {
    let pid: pid_t
    private let panel: AXUIElement

    static func current() -> Self? {
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != getpid(), let focused = focusedWindow(pid) else { return nil }
        let candidates = ([focused] + children(focused)).filter {
            value($0, kAXIdentifierAttribute) as? String == "open-panel"
        }
        guard candidates.count == 1, let panel = candidates.first else { return nil }
        return Self(pid: pid, panel: panel)
    }

    @MainActor func select(_ file: URL) async -> Bool {
        // Go to Folder takes keyboard input. File names containing control characters still work by drag and drop.
        guard file.isFileURL, !file.path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }),
              CGPreflightPostEventAccess(), CodexResultFiles.localFile(at: file.path) != nil else { return false }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        for _ in 0..<15 {
            guard isCurrent else { return false }
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled, isCurrent,
              CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty,
              Self.goToSheet(panel) == nil else { return false }
        for attempt in 0..<30 {
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
            if let sheet = Self.goToSheet(panel), let field = Self.child(of: sheet, named: "PathTextField") {
                return await select(file, through: sheet, field: field)
            }
            if (attempt == 0 || attempt == 16), isCurrent, Self.goToSheet(panel) == nil {
                Self.key(5, flags: [.maskCommand, .maskShift])
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return false
    }

    @MainActor private func select(_ file: URL, through sheet: AXUIElement, field: AXUIElement) async -> Bool {
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              Self.hasFocus(field, on: pid) else { return false }
        Self.key(0, flags: .maskCommand)
        for character in file.path { Self.key(0, text: Array(String(character).utf16)) }
        try? await Task.sleep(for: .milliseconds(340))
        func ownsPathField() -> Bool {
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let current = Self.goToSheet(panel), CFEqual(current, sheet), Self.hasFocus(field, on: pid)
            else { return false }
            return Self.value(field, kAXValueAttribute) as? String == file.path
        }
        guard ownsPathField() else { return false }
        if CodexResultFiles.localFile(at: file.path) != nil {
            // Return applies the path to the Go to Folder sheet. The Open button remains untouched.
            Self.key(36)
            for _ in 0..<15 {
                guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
                if isCurrent, Self.goToSheet(panel) == nil { return true }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        if ownsPathField() {
            Self.key(53)
            for _ in 0..<10 {
                if Task.isCancelled || (isCurrent && Self.goToSheet(panel) == nil) { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        return false
    }

    var isCurrent: Bool {
        guard let current = Self.current(), current.pid == pid else { return false }
        return CFEqual(current.panel, panel)
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let raw = value(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        let window = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.08)
        return window
    }

    private static func goToSheet(_ panel: AXUIElement) -> AXUIElement? {
        child(of: panel, named: "GoToWindow")
    }

    private static func child(of parent: AXUIElement, named identifier: String) -> AXUIElement? {
        children(parent).first { value($0, kAXIdentifierAttribute) as? String == identifier }
    }

    private static func hasFocus(_ field: AXUIElement, on pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let current = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(current) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(current, field)
    }

    private static func children(_ item: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        value(item, attribute) as? [AXUIElement] ?? []
    }

    private static func value(_ item: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var output: CFTypeRef?
        return AXUIElementCopyAttributeValue(item, attribute as CFString, &output) == .success ? output : nil
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: [UInt16] = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = down ? flags : []
            if !text.isEmpty { event?.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
            event?.post(tap: .cghidEventTap)
        }
    }
}
