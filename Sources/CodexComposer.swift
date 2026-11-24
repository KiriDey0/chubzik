import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

enum CodexComposer {
    struct Window {
        let pid: pid_t
        let id: CGWindowID
        let frame: CGRect
        let title: String

        func isCurrent() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let current = CodexComposer.confirmedWindow(pid: pid, title: title)
            else { return false }
            return current.id == id && current.frame == frame
        }
    }

    private static let placeholders: Set<String> = [
        "работайте с codex", "работайте с chatgpt", "спроси что угодно",
        "спросите что угодно", "work with codex", "work with chatgpt", "ask anything", "ask codex",
        "ask a follow up"
    ]

    static func focusedTitle(pid: pid_t) -> String? {
        guard let window = focusedWindow(pid), let title = attribute(window, kAXTitleAttribute) as? String else { return nil }
        let titleText = CodexHook.normalizedThreadTitle(title)
        return titleText.isEmpty ? nil : titleText
    }

    static func locate(in window: Window, top: CGFloat) async -> CGPoint? {
        let point: CGPoint?
        if let native = accessibilityPoint(pid: window.pid, window: window.frame) {
            point = native
        } else if CGPreflightScreenCaptureAccess() {
            point = await placeholderPoint(window: window.id, frame: window.frame, pid: window.pid)
        } else {
            point = nil
        }
        guard !Task.isCancelled, let point else { return nil }
        return CGPoint(x: point.x, y: top - point.y)
    }

    static func confirmedWindow(pid: pid_t, title: String) -> Window? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for record in records {
            guard record[kCGWindowOwnerPID as String] as? pid_t == pid,
                  record[kCGWindowLayer as String] as? Int == 0,
                  let id = record[kCGWindowNumber as String] as? CGWindowID,
                  let raw = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  frame.width >= 400, frame.height >= 320 else { continue }
            if let visibleTitle = record[kCGWindowName as String] as? String, !visibleTitle.isEmpty {
                guard CodexHook.normalizedThreadTitle(visibleTitle) == title else { return nil }
            } else {
                guard let focused = focusedWindow(pid), elementBounds(focused) == frame,
                      let nativeTitle = attribute(focused, kAXTitleAttribute) as? String,
                      CodexHook.normalizedThreadTitle(nativeTitle) == title else { return nil }
            }
            return Window(pid: pid, id: id, frame: frame, title: title)
        }
        return nil
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        guard let raw = attribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func accessibilityPoint(pid: pid_t, window: CGRect) -> CGPoint? {
        guard let focused = focusedWindow(pid), elementBounds(focused) == window else { return nil }
        var pending = [focused], index = 0
        var match: CGPoint?
        let limit = 1_400
        let deadline = ProcessInfo.processInfo.systemUptime + 0.24
        while index < pending.count, ProcessInfo.processInfo.systemUptime < deadline {
            let node = pending[index]
            index += 1
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(limit - pending.count))
            }
            guard let role = attribute(node, kAXRoleAttribute) as? String,
                  role == kAXTextAreaRole || role == kAXTextFieldRole,
                  attribute(node, kAXEnabledAttribute) as? Bool != false,
                  [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains(where: {
                      (attribute(node, $0) as? String).map(isPlaceholder) == true
                  }), let box = elementBounds(node),
                  composerArea(window).contains(CGPoint(x: box.midX, y: box.midY))
            else { continue }
            if match != nil { return nil }
            match = CGPoint(x: box.midX, y: box.midY)
        }
        return match
    }

    private static func placeholderPoint(window id: CGWindowID, frame: CGRect, pid: pid_t) async -> CGPoint? {
        guard frame.width >= 400,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == pid }),
              !Task.isCancelled else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(1.55, 2300 / frame.width)
        configuration.width = Int(frame.width * scale)
        configuration.height = Int(frame.height * scale)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              !Task.isCancelled else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        let region = CGRect(x: 0.12, y: 0.025, width: 0.84, height: 0.17)
        request.regionOfInterest = region
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        let matches = request.results?.compactMap { line -> CGPoint? in
            guard line.topCandidates(2).contains(where: { isVisiblePlaceholder($0.string) }) else { return nil }
            let box = line.boundingBox
            // Vision reports locations relative to the region of interest.
            let x = region.minX + box.midX * region.width
            let y = region.minY + box.midY * region.height
            let point = CGPoint(x: frame.minX + x * frame.width, y: frame.minY + (1 - y) * frame.height)
            return composerArea(frame).contains(point) ? point : nil
        } ?? []
        return matches.count == 1 ? matches.first : nil
    }

    private static func composerArea(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + frame.width * 0.12, y: frame.maxY - frame.height * 0.32,
               width: frame.width * 0.84, height: frame.height * 0.30)
    }

    private static func isPlaceholder(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        return placeholders.contains(words)
    }

    private static func isVisiblePlaceholder(_ text: String) -> Bool {
        if isPlaceholder(text) { return true }
        // Fast Vision OCR reads the Russian composer label with look-alike Latin characters.
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        return words.range(of: #"^[pр]?[aа]?[b6б][oо0][tт][aа][mиuлnй][tт][eе] [cс] (codex|chatgpt)$"#,
                           options: .regularExpression) != nil
    }

    private static func elementBounds(_ node: AXUIElement) -> CGRect? {
        guard let rawPoint = attribute(node, kAXPositionAttribute), CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              let rawSize = attribute(node, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }
}
