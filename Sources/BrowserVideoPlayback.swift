import AppKit
import ApplicationServices

enum VideoProbe<T> {
    case playing(T), inactive, unavailable, uncertain

    func map<U>(_ transform: (T) -> U) -> VideoProbe<U> {
        switch self {
        case .playing(let target): .playing(transform(target))
        case .inactive: .inactive
        case .unavailable: .unavailable
        case .uncertain: .uncertain
        }
    }
}

enum VideoPause: String {
    case paused, alreadyStopped, unconfirmed, attempted

    var hasStopped: Bool { self == .paused || self == .alreadyStopped }
    var mayHavePaused: Bool { self == .paused || self == .attempted }
}

final class BrowserVideoPlayback {
    struct Target {
        fileprivate let window: AXUIElement
        fileprivate let button: AXUIElement
        fileprivate let pid: pid_t
        fileprivate let page: AXUIElement?
        fileprivate let pageURL: URL?
        let point: CGPoint
        var isPictureInPicture: Bool { page == nil }
    }

    private let queue = DispatchQueue(label: "local.kirill.chubzik.browser-video", qos: .userInitiated)
    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "company.thebrowser.dia.beta",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox", "com.kiridey.ardia.personal"
    ]

    static var hasAccess: Bool { AXIsProcessTrusted() }
    static var isFrontmostBrowser: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(browsers.contains) == true
    }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func find(on screen: CGRect, includeArDia: Bool = true, completion: @escaping (VideoProbe<Target>) -> Void) {
        guard let top = NSScreen.screens.first?.frame.maxY else {
            completion(.unavailable)
            return
        }
        let workspace = NSWorkspace.shared
        let front = workspace.frontmostApplication
        let activeBrowser = front.flatMap { app in
            app.bundleIdentifier.map { Self.browsers.contains($0) && (includeArDia || $0 != ArDiaVideoPlayback.bundleID) } == true
                ? app.processIdentifier : nil
        }
        let processes = workspace.runningApplications.filter { app in
            app.bundleIdentifier.map {
                (Self.browsers.contains($0) && (includeArDia || $0 != ArDiaVideoPlayback.bundleID)) || $0 == "com.apple.PIPAgent"
            } == true
        }.map(\.processIdentifier)
        queue.async {
            let windows = Self.visibleWindows(for: processes)
            let result: VideoProbe<Target>
            if !Self.hasAccess {
                result = activeBrowser == nil && windows.isEmpty ? .inactive : .unavailable
            } else {
                let inline = activeBrowser.map { Self.findInlineVideo(pid: $0, screen: screen, top: top) } ?? .inactive
                switch inline {
                case .playing, .uncertain: result = inline
                case .inactive, .unavailable:
                    let pip = Self.findPictureInPicture(in: windows, screen: screen, top: top)
                    if case .inactive = pip { result = inline } else { result = pip }
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func pause(_ target: Target, shouldPress: @escaping () -> Bool, completion: @escaping (VideoPause) -> Void) {
        guard let top = NSScreen.screens.first?.frame.maxY else {
            completion(.unconfirmed)
            return
        }
        queue.async {
            guard Self.hasAccess, Self.targetIsCurrent(target) else {
                DispatchQueue.main.async { completion(.unconfirmed) }
                return
            }
            guard Self.isPause(target.button) else {
                let result: VideoPause = Self.hasPlayControl(near: target, top: top) ? .alreadyStopped : .unconfirmed
                DispatchQueue.main.async { completion(result) }
                return
            }
            guard let bounds = Self.bounds(target.button),
                  hypot(bounds.midX - target.point.x, top - bounds.midY - target.point.y) < 12,
                  Self.controls(for: target).contains(where: { CFEqual($0, target.button) }),
                  DispatchQueue.main.sync(execute: shouldPress)
            else {
                DispatchQueue.main.async { completion(.unconfirmed) }
                return
            }
            guard AXUIElementPerformAction(target.button, kAXPressAction as CFString) == .success else {
                DispatchQueue.main.async { completion(.attempted) }
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.10) {
                let result: VideoPause = Self.targetIsCurrent(target) && Self.hasPlayControl(near: target, top: top)
                    ? .paused : .attempted
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    func resume(_ target: Target, shouldResume: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard let top = NSScreen.screens.first?.frame.maxY else { completion(false); return }
        queue.async {
            guard Self.hasAccess, let button = Self.resumeControl(for: target, top: top),
                  DispatchQueue.main.sync(execute: shouldResume) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let started = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            DispatchQueue.main.async {
                if started, !target.isPictureInPicture, shouldResume() {
                    NSRunningApplication(processIdentifier: target.pid)?.activate()
                }
                completion(started)
            }
        }
    }

    private static func resumeControl(for target: Target, top: CGFloat) -> AXUIElement? {
        if let page = target.page {
            // A normal page must still be the same selected tab, even while Codex has focus.
            guard let current = activePage(in: target.window), CFEqual(current, page),
                  attribute(current, kAXURLAttribute) as? URL == target.pageURL,
                  let browserWindow = focusedWindow(target.pid), CFEqual(browserWindow, target.window) else { return nil }
        } else {
            guard targetIsCurrent(target) else { return nil }
        }
        let candidates = controls(for: target).filter { node in
            guard isPlay(node), let box = bounds(node) else { return false }
            return hypot(box.midX - target.point.x, top - box.midY - target.point.y) < 12
        }
        guard candidates.count == 1, let button = candidates.first else { return nil }
        return target.isPictureInPicture || CFEqual(button, target.button) ? button : nil
    }

    private static func targetIsCurrent(_ target: Target) -> Bool {
        if let page = target.page {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
                  let window = focusedWindow(target.pid), CFEqual(window, target.window),
                  let current = activePage(in: window), CFEqual(current, page),
                  attribute(current, kAXURLAttribute) as? URL == target.pageURL
            else { return false }
            return true
        }
        return isPictureInPicture(target.window) && isVisible(target.window, in: visibleWindows(for: [target.pid]))
    }

    private static func hasPlayControl(near target: Target, top: CGFloat) -> Bool {
        func atTarget(_ node: AXUIElement) -> Bool {
            guard isPlay(node), let box = bounds(node) else { return false }
            return hypot(box.midX - target.point.x, top - box.midY - target.point.y) < 12
        }
        return atTarget(target.button) || controls(for: target).contains(where: atTarget)
    }

    private static func controls(for target: Target) -> [AXUIElement] {
        elements(target.page ?? target.window, limit: target.page == nil ? 48 : 420)
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.13)
        let raw = attribute(application, kAXFocusedWindowAttribute) ?? attribute(application, kAXMainWindowAttribute)
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func activePage(in window: AXUIElement) -> AXUIElement? {
        elements(window, limit: 110).first {
            attribute($0, kAXRoleAttribute) as? String == "AXWebArea" &&
                bounds($0) != nil &&
                attribute($0, kAXURLAttribute) as? URL != nil
        }
    }

    private static func findInlineVideo(pid: pid_t, screen: CGRect, top: CGFloat) -> VideoProbe<Target> {
        guard let window = focusedWindow(pid), let page = activePage(in: window),
              let pageBounds = bounds(page), let url = attribute(page, kAXURLAttribute) as? URL else { return .unavailable }
        if ["about:blank", "about:newtab", "chrome://newtab/", "edge://newtab/"].contains(url.absoluteString) { return .inactive }
        guard url.scheme == "http" || url.scheme == "https" || url.isFileURL else { return .unavailable }
        let nodes = elements(page, limit: 420)
        let videoSite = isVideoPage(url)
        let videoRegions = videoSite ? [] : nodes.filter {
            attribute($0, kAXSubroleAttribute) as? String == "AXVideo" ||
                attribute($0, kAXRoleAttribute) as? String == "AXVideo" ||
                ["video player", "youtube video player", "видеоплеер", "видеопроигрыватель"].contains(
                    normalized(attribute($0, kAXDescriptionAttribute) as? String ?? ""))
        }
        var matches: [Target] = []
        var hasPlay = false
        for button in nodes where attribute(button, kAXRoleAttribute) as? String == kAXButtonRole {
            let pauses = isPause(button)
            guard pauses || isPlay(button), let box = bounds(button), pageBounds.contains(CGPoint(x: box.midX, y: box.midY)),
                  videoSite || videoRegions.contains(where: { region in
                      elements(region, limit: 80).contains { CFEqual($0, button) }
                  })
            else { continue }
            let point = CGPoint(x: box.midX, y: top - box.midY)
            if !pauses { hasPlay = true; continue }
            guard screen.contains(point) else { return .uncertain }
            matches.append(Target(window: window, button: button, pid: pid, page: page, pageURL: url, point: point))
            if matches.count > 1 { return .uncertain }
        }
        if let target = matches.first { return .playing(target) }
        if hasPlay { return .inactive }
        if videoSite || !videoRegions.isEmpty || nodes.count >= 420 { return .uncertain }
        return .inactive
    }

    private static func isVideoPage(_ url: URL) -> Bool {
        let path = url.path
        switch url.host?.lowercased() {
        case "youtube.com", "www.youtube.com", "m.youtube.com":
            return path == "/watch" || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
        case "instagram.com", "www.instagram.com":
            return path.hasPrefix("/reel/") || path.hasPrefix("/reels") || path.hasPrefix("/p/")
        case "tiktok.com", "www.tiktok.com":
            return path == "/" || path == "/foryou" || path.contains("/video/")
        default: return false
        }
    }

    private static func findPictureInPicture(in visible: [pid_t: [CGRect]], screen: CGRect, top: CGFloat) -> VideoProbe<Target> {
        var matches: [Target] = []
        var uncertain = false
        for (pid, frames) in visible {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.13)
            guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else {
                uncertain = true
                continue
            }
            for window in windows.prefix(24) {
                guard isPictureInPicture(window), isVisible(window, in: [pid: frames]) else { continue }
                let controls = elements(window, limit: 45)
                let playing = controls.filter(isPause)
                if playing.isEmpty, !controls.contains(where: isPlay) { uncertain = true }
                for button in playing {
                    guard let bounds = bounds(button) else { continue }
                    let point = CGPoint(x: bounds.midX, y: top - bounds.midY)
                    guard screen.contains(point) else { return .uncertain }
                    matches.append(Target(window: window, button: button, pid: pid, page: nil, pageURL: nil, point: point))
                    if matches.count > 1 { return .uncertain }
                }
            }
        }
        if uncertain { return .uncertain }
        return matches.first.map(VideoProbe.playing) ?? .inactive
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    private static func isPictureInPicture(_ window: AXUIElement) -> Bool {
        let names: Set<String> = ["picture in picture", "picture in picture window",
                                  "картинка в картинке", "окно картинки в картинке"]
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXSubroleAttribute, kAXIdentifierAttribute].contains {
            let name = normalized(attribute(window, $0) as? String ?? "")
            return names.contains(name) || name == "axpictureinpicturewindow"
        }
    }

    private static func isPause(_ button: AXUIElement) -> Bool {
        let names: Set<String> = ["pause", "pause k", "pause video", "pause playback", "пауза", "пауза k",
                                  "приостановить", "приостановить k", "приостановить видео", "приостановить воспроизведение"]
        return isButton(button, named: names)
    }

    private static func isPlay(_ button: AXUIElement) -> Bool {
        isButton(button, named: ["play", "play k", "play video", "resume", "replay", "воспроизвести", "воспроизвести k",
                                 "воспроизвести видео", "продолжить воспроизведение", "повторить", "повторить k"])
    }

    private static func isButton(_ button: AXUIElement, named names: Set<String>) -> Bool {
        guard attribute(button, kAXRoleAttribute) as? String == kAXButtonRole,
              (attribute(button, kAXEnabledAttribute) as? Bool) != false else { return false }
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains {
            names.contains(normalized(attribute(button, $0) as? String ?? ""))
        }
    }

    private static func elements(_ root: AXUIElement, limit: Int) -> [AXUIElement] {
        var nodes = [root]
        var index = 0
        while index < nodes.count, nodes.count < limit {
            let children = attribute(nodes[index], kAXChildrenAttribute) as? [AXUIElement] ?? []
            nodes.append(contentsOf: children.prefix(limit - nodes.count))
            index += 1
        }
        return nodes
    }

    private static func visibleWindows(for pids: [pid_t]) -> [pid_t: [CGRect]] {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var visible: [pid_t: [CGRect]] = [:]
        for info in infos {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let layer = info[kCGWindowLayer as String] as? Int, layer > 0,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  frame.width >= 70, frame.height >= 55 else { continue }
            visible[pid, default: []].append(frame)
        }
        return visible
    }

    private static func isVisible(_ window: AXUIElement, in frames: [pid_t: [CGRect]]) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, let box = bounds(window) else { return false }
        return frames[pid, default: []].contains {
            abs($0.minX - box.minX) < 12 && abs($0.minY - box.minY) < 12 &&
                abs($0.width - box.width) < 24 && abs($0.height - box.height) < 24
        }
    }

    private static func bounds(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(element, kAXPositionAttribute),
              let rawSize = attribute(element, kAXSizeAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
}
