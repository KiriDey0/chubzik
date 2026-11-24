import AppKit
import ApplicationServices

final class ArDiaAppleEventsPlayback {
    struct TabLocation {
        fileprivate let pid: pid_t
        fileprivate let windowID: String
        fileprivate let tabID: String
    }

    struct Target {
        fileprivate let pid: pid_t
        fileprivate let windowID: String
        fileprivate let tabID: String
        fileprivate let token: UUID
        fileprivate let pip: Bool
        fileprivate let pipStopped: Bool
        let point: CGPoint
        var isPictureInPicture: Bool { pip }
    }

    private struct Probe: Decodable {
        let mode: String
        let pipStopped: Bool?
        let x: Double?
        let y: Double?
    }

    private let queue = DispatchQueue(label: "local.kirill.chubzik.ardia-automation", qos: .userInitiated)

    func currentTab(pid: pid_t, completion: @escaping (TabLocation?) -> Void) {
        queue.async {
            let browser = ApplicationEvents(pid: pid)
            let location: TabLocation?
            if browser.isAllowed, let window = browser.frontWindow, !browser.isPrivate(window),
               let windowID = browser.get("ID  ", from: window)?.stringValue,
               let tab = browser.activeTab(in: window),
               let tabID = browser.get("ID  ", from: tab)?.stringValue {
                location = TabLocation(pid: pid, windowID: windowID, tabID: tabID)
            } else {
                location = nil
            }
            DispatchQueue.main.async { completion(location) }
        }
    }

    func restoreTab(_ location: TabLocation, shouldRestore: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        queue.async {
            let browser = ApplicationEvents(pid: location.pid)
            guard browser.isAllowed, let window = browser.window(id: location.windowID), !browser.isPrivate(window),
                  let tab = browser.tab(id: location.tabID, in: window),
                  browser.get("ID  ", from: tab)?.stringValue == location.tabID,
                  DispatchQueue.main.sync(execute: shouldRestore) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            browser.focus(tab)
            let restored = browser.activeTab(in: window).flatMap { browser.get("ID  ", from: $0)?.stringValue } == location.tabID
            DispatchQueue.main.async { completion(restored) }
        }
    }

    static func requestAccess() {
        guard let app = application else { return }
        let address = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, true)
        }
    }

    private static var application: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == ArDiaVideoPlayback.bundleID {
            return front
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: ArDiaVideoPlayback.bundleID)
            .first { !$0.isTerminated }
    }

    func find(on screen: CGRect, mediaTabID: String? = nil, completion: @escaping (VideoProbe<Target>) -> Void) {
        guard let top = NSScreen.screens.first?.frame.maxY else {
            completion(.unavailable)
            return
        }
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: ArDiaVideoPlayback.bundleID)
            .filter { !$0.isTerminated }
        let pipOwners = candidates.filter { ArDiaVideoPlayback.pictureInPicturePoint(top: top, owner: $0.processIdentifier) != nil }
        let foreground = candidates.first { $0.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let app = foreground ?? (pipOwners.count == 1 ? pipOwners.first : nil) else {
            completion(pipOwners.isEmpty ? .inactive : .uncertain)
            return
        }
        let inline = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let pip = ArDiaVideoPlayback.pictureInPicturePoint(top: top, owner: app.processIdentifier)
        guard inline || pip != nil else {
            completion(.inactive)
            return
        }
        let pid = app.processIdentifier
        queue.async {
            let target = Self.find(pid: pid, inline: inline, pip: pip, screen: screen, top: top,
                                   mediaTabID: mediaTabID)
            DispatchQueue.main.async { completion(target) }
        }
    }

    private static func find(pid: pid_t, inline: Bool, pip: CGPoint?, screen: CGRect, top: CGFloat,
                             mediaTabID: String?) -> VideoProbe<Target> {
        let browser = ApplicationEvents(pid: pid)
        guard browser.isAllowed else { return .unavailable }
        let started = ProcessInfo.processInfo.systemUptime
        let front = browser.frontWindow
        let frontID = front.flatMap { browser.get("ID  ", from: $0)?.stringValue }
        var activeID: String?
        var inlinePlayer: Target?
        if let window = front, !browser.isPrivate(window), let windowID = frontID,
              let tab = browser.activeTab(in: window),
              let tabID = browser.get("ID  ", from: tab)?.stringValue {
            activeID = tabID
            let selected = probe(browser, tab: tab, tabID: tabID, windowID: windowID, pid: pid,
                                 inline: inline, pip: pip, screen: screen, top: top)
            switch selected {
            case .playing(let target) where pip != nil && !target.isPictureInPicture && !target.pipStopped:
                inlinePlayer = target
            case .unavailable: break
            default: return selected
            }
        }
        guard let pip else { return .unavailable }
        guard screen.contains(pip) || inlinePlayer != nil else { return .uncertain }

        func resolved(_ result: VideoProbe<Target>) -> VideoProbe<Target>? {
            switch result {
            case .unavailable: return nil
            case .inactive: return inlinePlayer.map { .playing($0) } ?? .inactive
            case .playing where inlinePlayer != nil: return .uncertain
            default: return result
            }
        }

        // The visible native PiP window can belong to a background tab in another regular window.
        // Probe only for PiP and stop searching when the current completion would time out.
        let unresolved: VideoProbe<Target> = inlinePlayer == nil ? .unavailable : .uncertain
        let deadline = started + 1.15
        guard ProcessInfo.processInfo.systemUptime < deadline else { return unresolved }
        let count = min(6, browser.windowCount)
        guard count > 0 else { return unresolved }
        for index in 1...count {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard let indexedWindow = browser.window(index: index),
                  let windowID = browser.get("ID  ", from: indexedWindow)?.stringValue,
                  let window = browser.window(id: windowID), !browser.isPrivate(window) else { continue }
            if let mediaTabID, mediaTabID != activeID, let tab = browser.tab(id: mediaTabID, in: window) {
                let result = probe(browser, tab: tab, tabID: mediaTabID, windowID: windowID, pid: pid,
                                   inline: false, pip: pip, screen: screen, top: top)
                if let result = resolved(result) { return result }
            }
            for index in (0..<browser.tabCount(in: window)).reversed() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return unresolved }
                guard let tab = browser.tab(index: index + 1, in: window),
                      let tabID = browser.get("ID  ", from: tab)?.stringValue,
                      tabID != activeID, tabID != mediaTabID,
                      let stableTab = browser.tab(id: tabID, in: window) else { continue }
                let result = probe(browser, tab: stableTab, tabID: tabID, windowID: windowID, pid: pid,
                                   inline: false, pip: pip, screen: screen, top: top)
                if let result = resolved(result) { return result }
            }
        }
        return unresolved
    }

    private static func probe(_ browser: ApplicationEvents, tab: NSAppleEventDescriptor, tabID: String,
                              windowID: String, pid: pid_t, inline: Bool, pip: CGPoint?,
                              screen: CGRect, top: CGFloat) -> VideoProbe<Target> {
        let token = UUID()
        let probe = """
        (() => {
            const result = \(ArDiaVideoScript.probe(inline: inline, inspectPiP: pip != nil));
            if (!result) return '';
            if (result.video) {
                const key = Symbol.for('local.kirill.chubzik.video');
                globalThis[key] = { token: '\(token.uuidString)', result };
                setTimeout(() => { if (globalThis[key]?.token === '\(token.uuidString)') delete globalThis[key]; }, 6000);
            }
            return JSON.stringify({ mode: result.mode, pipStopped: result.pipStopped, x: result.x, y: result.y });
        })()
        """
        guard let result = browser.run(probe, in: tab),
              let state = try? JSONDecoder().decode(Probe.self, from: Data(result.utf8)) else { return .unavailable }
        if state.mode == "uncertain" { return .uncertain }
        if state.mode == "pipStopped" { return .inactive }
        if state.mode == "inactive" { return pip == nil ? .inactive : .unavailable }
        let point: CGPoint
        if state.mode == "pip", let pip { point = pip }
        else if state.mode == "inline", inline, let x = state.x, let y = state.y {
            point = CGPoint(x: x, y: top - y)
        } else {
            return .unavailable
        }
        guard screen.contains(point) else { return .uncertain }
        return .playing(Target(pid: pid, windowID: windowID, tabID: tabID, token: token, pip: state.mode == "pip",
                               pipStopped: state.pipStopped == true, point: point))
    }

    func pause(_ target: Target, retainForResume: Bool = false, shouldPress: @escaping () -> Bool,
               completion: @escaping (VideoPause) -> Void) {
        if target.pip {
            guard let top = NSScreen.screens.first?.frame.maxY,
                  let point = ArDiaVideoPlayback.pictureInPicturePoint(top: top, owner: target.pid),
                  hypot(point.x - target.point.x, point.y - target.point.y) < 12 else {
                completion(.unconfirmed)
                return
            }
        } else if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
            completion(.unconfirmed)
            return
        }
        queue.async {
            let paused = Self.press(target, retainForResume: retainForResume, shouldPress: shouldPress)
            DispatchQueue.main.async { completion(paused) }
        }
    }

    private static func press(_ target: Target, retainForResume: Bool, shouldPress: () -> Bool) -> VideoPause {
        let browser = ApplicationEvents(pid: target.pid)
        guard browser.isAllowed, let window = browser.window(id: target.windowID), !browser.isPrivate(window),
              let tab = browser.tab(id: target.tabID, in: window) else { return .unconfirmed }
        guard target.pip || isSelected(browser, target: target) else { return .unconfirmed }
        guard DispatchQueue.main.sync(execute: shouldPress) else { return .unconfirmed }
        let action = """
        (() => {
            const key = Symbol.for('local.kirill.chubzik.video'), handle = globalThis[key];
            if (handle?.token !== '\(target.token.uuidString)') return 'unconfirmed';
            delete globalThis[key];
            const result = (\(ArDiaVideoScript.pause(retainForResume: retainForResume))).call(handle.result);
            if (result === 'paused' && \(retainForResume)) {
                const resumeKey = Symbol.for('local.kirill.chubzik.video.resume.\(target.token.uuidString)');
                globalThis[resumeKey] = handle.result;
                setTimeout(() => { delete globalThis[resumeKey]; }, 480000);
            }
            return result;
        })()
        """
        return browser.run(action, in: tab).flatMap(VideoPause.init(rawValue:)) ?? .attempted
    }

    func resume(_ target: Target, shouldResume: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        if target.pip {
            guard let top = NSScreen.screens.first?.frame.maxY,
                  ArDiaVideoPlayback.pictureInPicturePoint(top: top, owner: target.pid) != nil else {
                completion(false)
                return
            }
        }
        queue.async {
            let browser = ApplicationEvents(pid: target.pid)
            guard browser.isAllowed, let window = browser.window(id: target.windowID), !browser.isPrivate(window),
                  let tab = browser.tab(id: target.tabID, in: window),
                  target.pip || Self.isSelected(browser, target: target, in: window),
                  DispatchQueue.main.sync(execute: shouldResume) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let key = "local.kirill.chubzik.video.resume." + target.token.uuidString
            let action = """
            (async () => {
                const key = Symbol.for('\(key)'), player = globalThis[key];
                delete globalThis[key];
                if (!player) return 'failed';
                return await (\(ArDiaVideoScript.resume)).call(player) ? 'playing' : 'failed';
            })()
            """
            let started = browser.run(action, in: tab, timeout: 1.1) == "playing"
            if started, !target.pip, !Self.isSelected(browser, target: target),
               Self.isSelected(browser, target: target, in: window),
               DispatchQueue.main.sync(execute: shouldResume) {
                browser.focus(tab)
            }
            DispatchQueue.main.async {
                if started, !target.pip, shouldResume() {
                    NSRunningApplication(processIdentifier: target.pid)?.activate()
                }
                completion(started)
            }
        }
    }

    private static func isSelected(_ browser: ApplicationEvents, target: Target) -> Bool {
        guard let front = browser.frontWindow, browser.get("ID  ", from: front)?.stringValue == target.windowID else { return false }
        return isSelected(browser, target: target, in: front)
    }

    private static func isSelected(_ browser: ApplicationEvents, target: Target, in window: NSAppleEventDescriptor) -> Bool {
        guard let active = browser.activeTab(in: window) else { return false }
        return browser.get("ID  ", from: active)?.stringValue == target.tabID
    }

    private struct ApplicationEvents {
        let receiver: NSAppleEventDescriptor

        init(pid: pid_t) { receiver = NSAppleEventDescriptor(processIdentifier: pid) }

        var isAllowed: Bool {
            AEDeterminePermissionToAutomateTarget(receiver.aeDesc, typeWildCard, typeWildCard, false) == noErr
        }

        var frontWindow: NSAppleEventDescriptor? { window(index: 1) }
        var windowCount: Int { count("cwin", in: .null()) }
        func window(index: Int) -> NSAppleEventDescriptor? { indexed("cwin", index, in: .null()) }

        func window(id: String) -> NSAppleEventDescriptor? { object("cwin", "ID  ", .init(string: id), .null()) }

        func activeTab(in window: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            object("prop", "prop", .init(typeCode: code("acTa")), window)
        }

        func tab(id: String, in window: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            object("DiaT", "ID  ", .init(string: id), window)
        }

        func tab(index: Int, in window: NSAppleEventDescriptor) -> NSAppleEventDescriptor? { indexed("DiaT", index, in: window) }
        func tabCount(in window: NSAppleEventDescriptor) -> Int { count("DiaT", in: window) }

        private func indexed(_ kind: String, _ index: Int, in container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            object(kind, "indx", .init(int32: Int32(index)), container)
        }

        private func count(_ kind: String, in container: NSAppleEventDescriptor) -> Int {
            let reply = send("core", "cnte", to: container, objectClass: kind)
            return max(0, Int(reply?.int32Value ?? 0))
        }

        func isPrivate(_ window: NSAppleEventDescriptor) -> Bool { get("NNin", from: window)?.booleanValue != false }

        func get(_ name: String, from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            guard let property = object("prop", "prop", .init(typeCode: code(name)), container) else { return nil }
            return send("core", "getd", to: property)
        }

        func run(_ script: String, in tab: NSAppleEventDescriptor, timeout: TimeInterval = 0.35) -> String? {
            send("CrSu", "ExJa", to: tab, script: script, timeout: timeout)?.stringValue
        }

        func focus(_ tab: NSAppleEventDescriptor) {
            _ = send("DiaT", "abFc", to: tab)
        }

        private func object(_ kind: String, _ form: String, _ data: NSAppleEventDescriptor,
                            _ parent: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            let object = NSAppleEventDescriptor.record()
            object.setDescriptor(.init(typeCode: code(kind)), forKeyword: UInt32(keyAEDesiredClass))
            object.setDescriptor(.init(enumCode: code(form)), forKeyword: UInt32(keyAEKeyForm))
            object.setDescriptor(data, forKeyword: UInt32(keyAEKeyData))
            object.setDescriptor(parent, forKeyword: UInt32(keyAEContainer))
            return object.coerce(toDescriptorType: typeObjectSpecifier)
        }

        private func send(_ suite: String, _ verb: String, to object: NSAppleEventDescriptor,
                          script: String? = nil, objectClass: String? = nil,
                          timeout: TimeInterval = 0.35) -> NSAppleEventDescriptor? {
            let event = NSAppleEventDescriptor(eventClass: code(suite), eventID: code(verb),
                                               targetDescriptor: receiver, returnID: Int16(kAutoGenerateReturnID),
                                               transactionID: Int32(kAnyTransactionID))
            event.setParam(object, forKeyword: keyDirectObject)
            if let script { event.setParam(.init(string: script), forKeyword: code("JvSc")) }
            if let objectClass { event.setParam(.init(typeCode: code(objectClass)), forKeyword: code("kocl")) }
            guard let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout),
                  (reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0) == 0 else { return nil }
            return reply.paramDescriptor(forKeyword: keyDirectObject)
        }

        private func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    }
}
