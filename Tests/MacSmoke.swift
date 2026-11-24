import AppKit
import ApplicationServices
import CoreGraphics

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--capture-shortcut-host" {
    let receipt = URL(fileURLWithPath: CommandLine.arguments[2])
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let focus = NSWindow(contentRect: NSRect(x: 280, y: 185, width: 410, height: 275),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
    focus.title = "Проверка локального сочетания"
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
        if event.keyCode == 13, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] {
            try? Data("received".utf8).write(to: receipt, options: .atomic)
            return nil
        }
        return event
    }
    focus.makeKeyAndOrderFront(nil)
    app.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        try? Data(String(getpid()).utf8).write(to: receipt.appendingPathExtension("ready"), options: .atomic)
    }
    app.run()
    if let monitor { NSEvent.removeMonitor(monitor) }
    exit(0)
}

let pid = Int32(CommandLine.arguments[1])!
let binary = CommandLine.arguments[2]
let marker = URL(fileURLWithPath: CommandLine.arguments[3])
let mode = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "normal"
let panelScale: CGFloat = 1.25
let compactPanelWidth: CGFloat = 336
let fullPanelWidth: CGFloat = 400

func matchesSize(_ measured: CGFloat?, _ unscaled: CGFloat) -> Bool {
    guard let measured else { return false }
    return abs(measured - unscaled * panelScale) <= 1
}

func windowInfo(_ name: String) -> [String: Any]? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
    return windows.first { window in
        window[kCGWindowOwnerPID as String] as? Int32 == pid && window[kCGWindowName as String] as? String == name
    }
}

func window(_ name: String) -> CGRect? {
    guard let bounds = windowInfo(name)?[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
}

func wait(_ label: String, seconds: Double = 2, _ condition: () -> Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() {
            print("PASS", label)
            return
        }
        Thread.sleep(forTimeInterval: 0.035)
    }
    fputs("FAIL \(label)\n", stderr)
    exit(1)
}

func accessible(role: String? = nil, _ match: (String) -> Bool) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
    }
    var nodes = [app]
    for _ in 0..<250 {
        guard let node = nodes.popLast() else { break }
        if (role == nil || attribute(node, kAXRoleAttribute) as? String == role),
           [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute].contains(where: {
            (attribute(node, $0) as? String).map(match) ?? false
        }) { return node }
        nodes.append(contentsOf: attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return nil
}

func press(_ title: String) {
    var button: AXUIElement?
    wait("the action \(title) is available") {
        button = accessible(role: kAXButtonRole) { $0 == title }
        return button != nil
    }
    precondition(AXUIElementPerformAction(button!, kAXPressAction as CFString) == .success)
}

func waitForQuickChatComposer(_ label: String = "Вопрос") {
    wait("the chat composer takes keyboard focus") {
        guard let composer = accessible(role: kAXTextFieldRole, { $0 == label }) else { return false }
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(composer, kAXFocusedAttribute as CFString, &focused) == .success
            && focused as? Bool == true
    }
}

func sendQuickChatDraft(_ text: String) {
    wait("the question is in the chat composer") {
        accessible(role: kAXTextFieldRole) { $0 == text } != nil
    }
    press("Отправить")
}

func savedQuickChatDrafts() -> [[String: Any]] {
    let url = marker.deletingLastPathComponent().appendingPathComponent("quick-chat-drafts.json")
    guard let data = try? Data(contentsOf: url),
          let drafts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return drafts
}

func chooseQuickChatMenuItem(_ title: String) {
    mouse(.mouseMoved, CGPoint(x: 735, y: 14))
    event(["type": "show"])
    wait("the notch chat menu is accessible") { accessible { $0 == "Диалоги Codex" } != nil }
    let menu = accessible { $0 == "Диалоги Codex" }!
    precondition(AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success)
    wait("the chat menu item \(title) is available") {
        accessible(role: kAXMenuItemRole) { $0 == title } != nil
    }
    let entry = accessible(role: kAXMenuItemRole) { $0 == title }!
    precondition(AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success)
}

func writeFixtureImage(to url: URL, color: NSColor = NSColor(deviceRed: 0.1, green: 0.8, blue: 0.2, alpha: 1)) throws {
    let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                 samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<32 {
        for x in 0..<32 { pixels.setColor(color, atX: x, y: y) }
    }
    try pixels.representation(using: .png, properties: [:])!.write(to: url)
}

func mouse(_ type: CGEventType, _ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.flags = []
    if type == .leftMouseDown || type == .leftMouseUp { event?.setIntegerValueField(.mouseEventClickState, value: 1) }
    event?.post(tap: .cghidEventTap)
}

func click(_ point: CGPoint) {
    mouse(.mouseMoved, point)
    mouse(.leftMouseDown, point)
    Thread.sleep(forTimeInterval: 0.04)
    mouse(.leftMouseUp, point)
}

func typeText(_ text: String) {
    let characters = Array(text.utf16)
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
        event?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        event?.post(tap: .cghidEventTap)
    }
}

func key(_ code: CGKeyCode, flags: CGEventFlags = [], hold: Double = 0) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = down ? flags : []
        event?.post(tap: .cghidEventTap)
        if down && hold > 0 { Thread.sleep(forTimeInterval: hold) }
    }
}

func scroll(x: Int32, y: Int32, beforeRelease: (() -> Void)? = nil) {
    for (phase, dx, dy) in [(1, x, y), (2, x, y), (2, x, y), (4, 0, 0)] {
        if phase == 4 { beforeRelease?() }
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: dy, wheel2: dx, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        event?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }
}

func capture(_ name: String) {
    guard let directory = ProcessInfo.processInfo.environment["CHUBZIK_SMOKE_SCREENSHOTS"],
          let id = windowInfo("Островок")?[kCGWindowNumber as String] else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l", String(describing: id), "-o", directory + "/" + name + ".png"]
    try! process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0)
}

func event(_ object: [String: Any]) {
    let bytes = try! JSONSerialization.data(withJSONObject: object)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["--event-json", String(data: bytes, encoding: .utf8)!]
    try! process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0)
}

guard CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else {
    fputs("Missing pre-existing access for native UI verification.\n", stderr)
    exit(2)
}
let oldPoint = CGEvent(source: nil)?.location
defer { if let oldPoint { mouse(.mouseMoved, oldPoint) } }

if mode == "media-progress-clock" {
    func position(_ value: String) -> Bool {
        accessible(role: kAXStaticTextRole) { $0 == value } != nil
    }
    func playback(elapsed: Int, playing: Bool) {
        event(["type": "fixture-source-media", "source": "com.lad.music", "id": "progress-clock",
               "title": "Проверка шкалы", "playing": playing, "elapsed": elapsed, "duration": 200])
    }
    mouse(.mouseMoved, CGPoint(x: 735, y: 12))
    event(["type": "show"])
    press("Музыка")
    playback(elapsed: 50, playing: true)
    wait("the native timeline advances without more player events", seconds: 4) { position("0:52") }
    playback(elapsed: 75, playing: false)
    wait("the native timeline uses the exact paused position") { position("1:15") }
    Thread.sleep(forTimeInterval: 1.25)
    precondition(position("1:15"), "The paused timeline continued counting")
    press("Играть")
    wait("resuming continues from the same position", seconds: 4) { position("1:17") }
} else if mode == "media-source-heartbeat" {
    let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
    let arDia = "com.kiridey.ardia.personal"
    let lad = "com.lad.music"
    let video = "Активный ролик ArDia"
    let song = "Следующий трек Лада"
    func shows(_ title: String) -> Bool { accessible(role: kAXStaticTextRole) { $0 == title } != nil }
    func playback(_ source: String, _ id: String, _ title: String, _ playing: Bool, elapsed: Int = 5) {
        event(["type": "fixture-source-media", "source": source, "id": id, "title": title,
               "playing": playing, "elapsed": elapsed, "duration": 200])
    }
    mouse(.mouseMoved, CGPoint(x: 735, y: 12))
    event(["type": "show"])
    press("Музыка")
    wait("Lad is the initial player") { shows("Ночной маршрут") }
    playback(arDia, "web", video, true)
    wait("starting a different player selects it") { shows(video) }
    playback(lad, "demo", "Ночной маршрут", true, elapsed: 31)
    Thread.sleep(forTimeInterval: 0.28)
    wait("an elapsed-time update from Lad does not steal playback control", seconds: 0.6) { shows(video) }
    playback(lad, "next", song, true)
    Thread.sleep(forTimeInterval: 0.28)
    wait("a background track change preserves the current source", seconds: 0.6) { shows(video) }
    press("Пауза")
    wait("Pause reaches ArDia and falls back to the playing Lad track") {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("fixture media command " + arDia + " web pause")
            && shows(song)
    }
    playback(arDia, "web", video, true)
    wait("resuming ArDia selects it again") { shows(video) }
    playback(arDia, "web", video, false)
    wait("pausing ArDia selects the still-playing Lad track") { shows(song) }
    playback(lad, "next", song, false)
    playback(arDia, "web", video, false, elapsed: 38)
    Thread.sleep(forTimeInterval: 0.28)
    wait("updates from a paused player do not replace the last selected source", seconds: 0.6) { shows(song) }
} else if mode == "media-source-handoff" {
    let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
    func shows(_ title: String) -> Bool { accessible(role: kAXStaticTextRole) { $0 == title } != nil }
    func commanded(_ command: String) -> Bool {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("fixture media command " + command)
    }
    mouse(.mouseMoved, CGPoint(x: 735, y: 12))
    event(["type": "show"])
    press("Музыка")
    event(["type": "fixture-source-media", "source": "com.kiridey.ardia.personal", "id": "web",
           "title": "Ролик в ArDia", "playing": true])
    wait("the automatic source switches to the newer player") { shows("Ролик в ArDia") }
    event(["type": "fixture-system-media", "source": "com.lad.music.helper", "id": "system-track",
           "title": "Лад через Now Playing", "playing": false])
    let menu = accessible { $0 == "Источник воспроизведения" }!
    precondition(AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success)
    wait("the local Lad source is selectable") { accessible(role: kAXMenuItemRole) { $0 == "Лад" } != nil }
    let lad = accessible(role: kAXMenuItemRole) { $0 == "Лад" }!
    precondition(AXUIElementPerformAction(lad, kAXPressAction as CFString) == .success)
    wait("the chosen Lad source is shown") { shows("Ночной маршрут") }
    press("Пауза")
    wait("Pause targets the native Lad connection") { commanded("com.lad.music demo pause") }
    event(["type": "fixture-source-bye", "source": "com.lad.music"])
    wait("disconnecting the local integration keeps the chosen player through Now Playing") {
        shows("Лад через Now Playing") && !shows("Ролик в ArDia")
    }
    press("Играть")
    wait("Play targets the current Lad Now Playing session") { commanded("com.lad.music.helper system-track play") }
    event(["type": "fixture-source-media", "source": "com.lad.music", "id": "restored",
           "title": "Лад переподключился", "playing": false])
    wait("the direct Lad session takes over again") { shows("Лад переподключился") }
    press("Играть")
    wait("Play returns to the native connection") { commanded("com.lad.music restored play") }
    precondition(!commanded("com.kiridey.ardia.personal web"))
} else if mode == "media-seek-accessibility" || mode == "media-late-seek" {
    let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
    mouse(.mouseMoved, CGPoint(x: 735, y: 12))
    event(["type": "show"])
    press("Музыка")
    wait("the playback slider is available") { accessible(role: kAXSliderRole) { $0 == "Позиция воспроизведения" } != nil }
    let slider = accessible(role: kAXSliderRole) { $0 == "Позиция воспроизведения" }!
    func commanded(_ id: String) -> Bool {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("fixture media command com.lad.music " + id + " seek")
    }
    if mode == "media-late-seek" {
        func read(_ attribute: String) -> AXValue {
            var value: CFTypeRef?
            precondition(AXUIElementCopyAttributeValue(slider, attribute as CFString, &value) == .success)
            return value as! AXValue
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        precondition(AXValueGetValue(read(kAXPositionAttribute), .cgPoint, &point))
        precondition(AXValueGetValue(read(kAXSizeAttribute), .cgSize, &size))
        let start = CGPoint(x: point.x + size.width * 0.18, y: point.y + size.height / 2)
        let end = CGPoint(x: point.x + size.width * 0.73, y: start.y)
        mouse(.mouseMoved, start)
        mouse(.leftMouseDown, start)
        Thread.sleep(forTimeInterval: 0.08)
        mouse(.leftMouseDragged, end)
        event(["type": "fixture-source-media", "source": "com.lad.music", "id": "different-track",
               "title": "Другой трек", "duration": 200, "elapsed": 25, "playing": false])
        Thread.sleep(forTimeInterval: 0.2)
        mouse(.leftMouseUp, end)
        wait("another track has taken over the slider") { accessible { $0 == "Другой трек" } != nil }
        Thread.sleep(forTimeInterval: 0.15)
        precondition(!commanded("different-track"), "The old drag must never seek the replacement track")
        let currentSlider = accessible(role: kAXSliderRole) { $0 == "Позиция воспроизведения" }!
        precondition(AXUIElementPerformAction(currentSlider, kAXIncrementAction as CFString) == .success)
        wait("the new track accepts its own seek") { commanded("different-track") }
    } else {
        precondition(AXUIElementPerformAction(slider, kAXIncrementAction as CFString) == .success)
        wait("accessibility adjustment seeks the selected track") { commanded("demo") }
    }
} else if mode == "meeting-updated-link" {
    let windowName = "Встреча у чёлки"
    let id = "test-room"
    let original = "https://example.com/test-room"
    let corrected = "https://example.com/updated-room"
    let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
    func opened(_ url: String) -> Bool {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("fixture meeting opened " + url)
    }
    func updateLink(_ url: String) {
        event(["type": "fixture-meeting", "action": "update-link", "id": id, "path": url])
    }
    func join(_ label: String) {
        wait(label) { window(windowName) != nil && accessible { $0 == "Войти во встречу «Тестовая встреча»" } != nil }
        let button = window(windowName)!
        click(CGPoint(x: button.midX, y: button.midY))
    }
    mouse(.mouseMoved, CGPoint(x: 500, y: 350))
    event(["type": "fixture-meeting", "id": id, "title": "Тестовая встреча", "elapsed": 60])
    join("the initial room is available")
    wait("the original link opens and is marked joined") { opened(original) && window(windowName) == nil }
    updateLink(original)
    Thread.sleep(forTimeInterval: 0.22)
    precondition(window(windowName) == nil, "An unchanged link must stay joined")
    updateLink(corrected)
    join("a new link restores Join for the same meeting occurrence")
    wait("the corrected link opens and is marked joined") { opened(corrected) && window(windowName) == nil }
} else if mode == "meeting-overlap" || mode == "meeting-stale-choice" || mode == "meeting-updated-choice" {
    let meeting = "Встреча у чёлки"
    let activity = "Таймер у чёлки"
    let first = "Открытие проекта"
    let second = "Встреча с редактором"
    let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
    func result() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    mouse(.mouseMoved, CGPoint(x: 500, y: 350))
    wait("timer badge is visible before the meeting") { window(activity) != nil }
    let initial = window(activity)!
    event(["type": "fixture-meeting", "id": "test-first", "title": first, "elapsed": 60])
    wait("the first meeting has a direct join button") {
        window(meeting) != nil && accessible { $0 == "Войти во встречу «\(first)»" } != nil
    }
    event(["type": "fixture-meeting", "action": "append", "id": "test-second", "title": second, "elapsed": 302])
    wait("overlapping meetings offer a choice when the second enters its join window", seconds: 5) {
        accessible { $0 == "Встречи: 2" } != nil
    }
    let button = window(meeting)!
    precondition(button.maxX < window(activity)!.minX, "The meetings button must not overlap the timer")
    click(CGPoint(x: button.midX, y: button.midY))
    func meetingItem(_ title: String) -> AXUIElement? { accessible(role: kAXMenuItemRole) { $0.contains(title) } }
    wait("the menu lists both meeting names") { meetingItem(first) != nil && meetingItem(second) != nil }
    if mode == "meeting-stale-choice" {
        event(["type": "fixture-meeting", "action": "remove", "id": "test-second"])
    } else if mode == "meeting-updated-choice" {
        event(["type": "fixture-meeting", "action": "update-link", "id": "test-second", "path": "https://example.com/updated-room"])
    }
    precondition(AXUIElementPerformAction(meetingItem(second)!, kAXPressAction as CFString) == .success)
    let shouldOpen = mode != "meeting-stale-choice"
    let selectedURL = mode == "meeting-updated-choice" ? "https://example.com/updated-room" : "https://example.com/test-second"
    wait(shouldOpen ? "selecting the later meeting opens only its URL and leaves the earlier shortcut"
                    : "a meeting removed while the menu was open does not launch") {
        result().contains("fixture meeting opened " + selectedURL) == shouldOpen
            && !result().contains("fixture meeting opened https://example.com/test-first")
            && accessible { $0 == "Войти во встречу «\(first)»" } != nil
    }
    if meetingItem(first) != nil { key(53) }
    wait("the meeting menu closes") { meetingItem(first) == nil }
    if mode == "meeting-updated-choice" {
        precondition(!result().contains("fixture meeting opened https://example.com/test-second"))
    }
    let remaining = window(meeting)!
    click(CGPoint(x: remaining.midX, y: remaining.midY))
    wait("joining the last meeting restores the timer position") {
        result().contains("fixture meeting opened https://example.com/test-first")
            && result().contains("fixture meeting opened " + selectedURL) == shouldOpen
            && window(meeting) == nil && window(activity) == initial
    }
} else if mode.hasPrefix("timer-") {
    let activity = "Таймер у чёлки"
    let storedTimer = marker.deletingLastPathComponent().appendingPathComponent("timer.json")
    struct SavedTimer: Decodable {
        let end: Date
        let phase: String
        let pausedSeconds: TimeInterval?
    }
    func savedTimer() -> SavedTimer? {
        guard let bytes = try? Data(contentsOf: storedTimer) else { return nil }
        return try? JSONDecoder().decode(SavedTimer.self, from: bytes)
    }
    struct SavedStopwatch: Decodable {
        let started: Date?
        let elapsed: TimeInterval
    }
    func savedStopwatch() -> SavedStopwatch? {
        let store = storedTimer.deletingLastPathComponent().appendingPathComponent("stopwatch.json")
        guard let bytes = try? Data(contentsOf: store) else { return nil }
        return try? JSONDecoder().decode(SavedStopwatch.self, from: bytes)
    }
    func text(_ label: String) -> Bool { accessible(role: kAXStaticTextRole) { $0 == label } != nil }
    func openTimers() {
        let screen = CGDisplayBounds(CGMainDisplayID())
        mouse(.mouseMoved, CGPoint(x: screen.midX, y: 14))
        event(["type": "show"])
        press("Таймеры и заметка")
        wait("the timer page is visible") { text("Секундомер") }
    }
    if mode == "timer-write-failure" {
        let manager = FileManager.default
        let stopwatchFile = storedTimer.deletingLastPathComponent().appendingPathComponent("stopwatch.json")
        try manager.createDirectory(at: storedTimer, withIntermediateDirectories: false)
        try manager.createDirectory(at: stopwatchFile, withIntermediateDirectories: false)
        openTimers()
        press("1 мин")
        wait("failed timer start leaves the countdown stopped") {
            text("Не удалось сохранить таймер") && accessible(role: kAXButtonRole) { $0 == "1 мин" } != nil
                && savedTimer() == nil
        }
        press("Старт секундомера")
        wait("failed stopwatch start leaves the stopwatch stopped") {
            text("Не удалось сохранить секундомер") && accessible(role: kAXButtonRole) { $0 == "Старт секундомера" } != nil
                && savedStopwatch() == nil
        }
        try manager.removeItem(at: stopwatchFile)
        press("Старт секундомера")
        wait("retry starts and saves the stopwatch") { savedStopwatch()?.started != nil }
        press("Пауза секундомера")
        wait("the stopwatch can still be paused") { savedStopwatch()?.started == nil }
        try manager.removeItem(at: storedTimer)
        press("1 мин")
        wait("retry starts and saves the countdown") { savedTimer()?.phase == "timer" }
        let backup = storedTimer.appendingPathExtension("backup")
        try manager.moveItem(at: storedTimer, to: backup)
        try manager.createDirectory(at: storedTimer, withIntermediateDirectories: false)
        press("Пауза")
        wait("failed pause leaves the countdown running") {
            text("Не удалось сохранить таймер") && accessible(role: kAXButtonRole) { $0 == "Продолжить" } == nil
        }
        event(["type": "fixture-timer-clock", "action": "change", "elapsed": 90])
        wait("expiry still updates the panel when the disk is unavailable") {
            text("Не удалось сохранить таймер") && accessible(role: kAXButtonRole) { $0 == "1 мин" } != nil
        }
        try manager.removeItem(at: storedTimer)
        try manager.moveItem(at: backup, to: storedTimer)
        wait("the finished countdown is written after storage recovers", seconds: 13) {
            savedTimer() == nil && !text("Не удалось сохранить таймер")
        }
        let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
        let notices = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "Таймер закончился")
        precondition(notices.count == 2, "Storage retry must not repeat a timer completion")
    } else if mode == "timer-paused-priority" {
        wait("the activity badge is visible") { window(activity) != nil }
        wait("a paused countdown takes priority over a paused stopwatch") {
            text("0:42") && text("Фокус на паузе")
        }
    } else if mode == "timer-clock-wake" {
        let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
        func count(_ notice: String) -> Int {
            (try? String(contentsOf: log, encoding: .utf8))?.components(separatedBy: notice).count ?? 1
        }
        let focusEnd = savedTimer()!.end
        precondition(focusEnd.timeIntervalSinceNow > 2)
        event(["type": "fixture-timer-clock", "elapsed": -120])
        Thread.sleep(forTimeInterval: max(0, focusEnd.timeIntervalSinceNow) + 0.5)
        wait("a backward wall-time correction cannot finish the focus phase early") {
            savedTimer()?.phase == "focus" && count("Время отдохнуть") == 1
        }
        event(["type": "fixture-timer-clock", "action": "change", "elapsed": 50])
        wait("a forward clock change starts only the remaining part of the break") {
            savedTimer()?.phase == "rest" && savedTimer()?.end == focusEnd.addingTimeInterval(300)
        }
        wait("the focus completion is signalled once") { count("Время отдохнуть") == 2 }
        event(["type": "fixture-timer-clock", "action": "sleep", "elapsed": 50])
        wait("display sleep hides the timer badge") { window(activity) == nil }
        event(["type": "fixture-timer-clock", "action": "change", "elapsed": 55])
        Thread.sleep(forTimeInterval: 0.3)
        precondition(window(activity) == nil && savedTimer()?.phase == "rest")
        event(["type": "fixture-timer-clock", "action": "wake", "elapsed": 450])
        wait("wake finishes the expired break once") {
            savedTimer() == nil && count("Перерыв закончился") == 2 && window(activity) == nil
        }
        event(["type": "fixture-timer-clock", "action": "wake", "elapsed": 451])
        Thread.sleep(forTimeInterval: 0.2)
        precondition(count("Время отдохнуть") == 2 && count("Перерыв закончился") == 2)
        print("PASS a second wake event does not repeat either notification")
    } else if mode == "timer-stopwatch-clock-seed" {
        openTimers()
        press("Старт секундомера")
        wait("the stopwatch is running") { savedStopwatch()?.started != nil }
        event(["type": "fixture-timer-clock", "action": "change", "elapsed": 7200])
        Thread.sleep(forTimeInterval: 1.2)
        press("Пауза секундомера")
        wait("a two-hour clock jump leaves the stopwatch within a few seconds") {
            guard let saved = savedStopwatch(), saved.started == nil else { return false }
            return (1..<12).contains(saved.elapsed)
        }
        press("Старт секундомера")
        wait("the restarted stopwatch saves its new running interval") { savedStopwatch()?.started != nil }
    } else if mode == "timer-stopwatch-clock-restore" {
        let previous = savedStopwatch()!
        precondition(previous.started != nil)
        wait("the saved running stopwatch reappears after relaunch") { window(activity) != nil && text("Секундомер") }
        event(["type": "fixture-timer-clock", "action": "sleep", "elapsed": -7200])
        wait("display sleep hides the stopwatch badge") { window(activity) == nil }
        Thread.sleep(forTimeInterval: 1.2)
        event(["type": "fixture-timer-clock", "action": "wake", "elapsed": -7200])
        wait("waking the display restores the stopwatch badge") { window(activity) != nil && text("Секундомер") }
        openTimers()
        press("Пауза секундомера")
        wait("relaunch, display wake and a backward clock jump preserve elapsed time") {
            guard let saved = savedStopwatch(), saved.started == nil else { return false }
            return (1..<35).contains(saved.elapsed - previous.elapsed)
        }
    } else if mode == "timer-restart-seed" {
        openTimers()
        press("1 мин")
        wait("the countdown starts using the normal panel action") { savedTimer()?.phase == "timer" }
        press("Пауза")
        wait("the countdown is paused and saved") {
            savedTimer()?.pausedSeconds != nil && accessible { $0 == "Продолжить" } != nil
        }
        let seconds = savedTimer()!.pausedSeconds!
        press("Старт секундомера")
        wait("a running stopwatch takes priority over the paused countdown") { text("Секундомер") && !text("Таймер на паузе") }
        press("Пауза секундомера")
        wait("pausing the stopwatch brings back the countdown") { text("Таймер на паузе") }
        mouse(.mouseMoved, CGPoint(x: 120, y: 600))
        wait("the timer remains paused when the panel closes") {
            window("Островок") == nil && savedTimer()?.pausedSeconds == seconds
        }
    } else if mode == "timer-restart-restore" {
        wait("the countdown remains paused after restarting") { text("Таймер на паузе") && savedTimer()?.pausedSeconds != nil }
        let seconds = savedTimer()!.pausedSeconds!
        openTimers()
        press("Продолжить")
        wait("resume preserves the time left before the restart") {
            guard let resumed = savedTimer() else { return false }
            return resumed.pausedSeconds == nil && abs(resumed.end.timeIntervalSinceNow - seconds) < 1
        }
        press("Стоп")
        wait("stopping the timer restores the stopwatch display") {
            savedTimer() == nil && text("Секундомер на паузе")
        }
    }
} else if mode == "completion-nudge" || mode == "completion-nudge-fullscreen" {
    let name = "Чубзик"
    wait("mascot starts visible") { window(name) != nil }
    let home = window(name)
    let screen = CGDisplayBounds(CGMainDisplayID())
    let point = CGPoint(x: screen.midX - 150, y: screen.midY + 80)
    mouse(.mouseMoved, point)
    Thread.sleep(forTimeInterval: 0.1)
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    event(["type": "fixture-completion-mode", "action": "Мягкий"])

    let hook = Process()
    hook.executableURL = URL(fileURLWithPath: binary)
    hook.arguments = ["--fixture-codex-hook"]
    let input = Pipe()
    hook.standardInput = input
    try hook.run()
    input.fileHandleForWriting.write(Data("""
        {"hook_event_name":"Stop","session_id":"00000000-0000-0000-0000-000000000001"}
        """.utf8))
    try input.fileHandleForWriting.close()
    hook.waitUntilExit()
    precondition(hook.terminationStatus == 0)

    wait("completion mascot reaches the pointer") {
        guard let frame = window(name) else { return false }
        return hypot(frame.midX - point.x, frame.midY - point.y) < 33
    }
    var firstPull: TimeInterval?
    var secondPull: TimeInterval?
    let arrival = ProcessInfo.processInfo.systemUptime
    var departure: TimeInterval?
    while ProcessInfo.processInfo.systemUptime - arrival < 2.5 {
        let now = ProcessInfo.processInfo.systemUptime
        if departure == nil {
            let near = window(name).map { hypot($0.midX - point.x, $0.midY - point.y) < 40 } ?? false
            if !near { departure = now }
        }
        let cursor = CGEvent(source: nil)?.location ?? point
        let travel = hypot(cursor.x - point.x, cursor.y - point.y)
        precondition(travel < 17, "Completion moved the pointer too far: \(travel)")
        if travel > 4, firstPull == nil { firstPull = now }
        if travel > 11, secondPull == nil { secondPull = now }
        Thread.sleep(forTimeInterval: 0.006)
    }
    precondition(firstPull != nil && secondPull != nil &&
                 (0.65...1.1).contains(secondPull! - firstPull!), "Expected two separate pointer pulls")
    let dwell = (departure ?? arrival) - arrival
    precondition((1.85...2.50).contains(dwell), "Expected about two seconds at the pointer, saw \(dwell)")
    print("PASS exactly two short pulls from a Stop hook without a pending request")
    print("PASS stayed at the pointer for \(String(format: "%.2f", dwell)) seconds")
    wait("mascot returns to its original visibility and position") { window(name) == home }
    precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == front)
    let end = CGEvent(source: nil)?.location ?? point
    precondition(end.x > point.x && (13...17).contains(hypot(end.x - point.x, end.y - point.y)))
    precondition(window("Островок") == nil, "Completion opened the notch panel")
} else if mode == "completion-single-video" {
    let screen = CGDisplayBounds(CGMainDisplayID())
    mouse(.mouseMoved, CGPoint(x: screen.midX - 150, y: screen.midY + 80))
    let chat = "00000000-0000-0000-0000-000000000001"
    let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
    event(["type": "fixture-completion-mode", "action": "Высокий"])
    event(["type": "fixture-completion-done", "chat": chat, "title": "Целевой тестовый диалог"])
    wait("an individual completion pauses video before opening its own conversation", seconds: 6) {
        guard let progress = try? String(contentsOf: log, encoding: .utf8),
              let pause = progress.range(of: "completion touched video"),
              let handoff = progress.range(of: "fixture opened Codex chat " + chat) else { return false }
        return pause.lowerBound < handoff.lowerBound
    }
} else if mode.hasPrefix("completion-burst-") {
    let screen = CGDisplayBounds(CGMainDisplayID())
    let point = CGPoint(x: screen.midX - 150, y: screen.midY + 80)
    let first = "00000000-0000-0000-0000-000000000001"
    let second = "00000000-0000-0000-0000-000000000002"
    let third = "00000000-0000-0000-0000-000000000003"
    let signal = "Ответ у чёлки"
    let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHUBZIK_FIXTURE_LOG"]!)
    func events() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    func done(_ chat: String, _ title: String) { event(["type": "fixture-completion-done", "chat": chat, "title": title]) }
    func badge(_ count: Int) -> Bool { accessible { $0.hasPrefix("Codex · \(count) готово") } != nil }

    let home = window("Чубзик")
    mouse(.mouseMoved, point)
    event(["type": "fixture-completion-mode", "action": mode.hasSuffix("video") ? "Высокий" : "Мягкий"])
    done(first, "Первый тестовый диалог")
    done(second, "Второй тестовый диалог")
    wait("two completed dialogues share the notch button") { badge(2) }
    wait("the gesture gives both tugs", seconds: 5) {
        events().components(separatedBy: "completion tug").count == 3
    }
    wait("the mascot returns after the batch") { window("Чубзик") == home }
    if mode.hasSuffix("video") {
        wait("a grouped completion leaves the video playing") {
            !events().contains("completion touched video") && !events().contains("fixture opened Codex chat")
        }
    } else if mode.hasSuffix("overlap") {
        let chat = "Быстрый чат Чубзика"
        event(["type": "fixture-quick-chat"])
        wait("the quick chat opens while Codex results are waiting") { window(chat) != nil }
        waitForQuickChatComposer()
        let question = "Проверка одновременных ответов"
        typeText(question)
        sendQuickChatDraft(question)
        wait("the quick chat request is in flight") { window(chat)?.height == 155 }
        key(53)
        wait("the quick chat is hidden") { window(chat) == nil }
        wait("the finished quick chat has the notch shortcut", seconds: 6) {
            accessible { $0.hasPrefix("К ответу —") } != nil
        }
        let heldAt = CGEvent(source: nil)!.location
        mouse(.leftMouseDown, heldAt)
        done(third, "Третий тестовый диалог")
        Thread.sleep(forTimeInterval: 0.6)
        mouse(.leftMouseUp, heldAt)
        wait("the quick chat shortcut survives another Codex completion") {
            accessible { $0.hasPrefix("К ответу —") } != nil
        }
        event(["type": "fixture-quick-chat"])
        wait("opening the quick-chat answer restores all three Codex shortcuts") {
            accessible { $0 == "Это тестовый ответ." } != nil && badge(3)
        }
    } else {
        let heldAt = CGEvent(source: nil)!.location
        mouse(.leftMouseDown, heldAt)
        done(third, "Третий тестовый диалог")
        Thread.sleep(forTimeInterval: 0.6)
        let positionWhileHeld = CGEvent(source: nil)?.location
        mouse(.leftMouseUp, heldAt)
        precondition(positionWhileHeld == heldAt, "A completion must not move a held pointer")
        wait("the held click keeps all three completed dialogues available") { badge(3) }
        let button = window(signal)!
        click(CGPoint(x: button.midX, y: button.midY))
        wait("the first and last completed dialogues are listed") {
            accessible(role: kAXMenuItemRole) { $0 == "Первый тестовый диалог" } != nil &&
            accessible(role: kAXMenuItemRole) { $0 == "Третий тестовый диалог" } != nil
        }
        let item = accessible(role: kAXMenuItemRole) { $0 == "Третий тестовый диалог" }!
        precondition(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success)
        wait("opening a grouped result removes only the acknowledged chat") {
            badge(2) && events().contains("fixture opened Codex chat " + third)
        }
        event(["type": "work", "chat": second])
        wait("a new task withdraws only its own completion") {
            accessible { $0.hasPrefix("К ответу —") } != nil
        }
        let remaining = window(signal)!
        click(CGPoint(x: remaining.midX, y: remaining.midY))
        wait("opening the last confirmed result clears the shortcut") {
            window(signal) == nil && events().contains("fixture opened Codex chat " + first)
        }
    }
} else if mode == "completion-focus-change" {
    let name = "Чубзик"
    wait("the mascot is visible") { window(name) != nil }
    let home = window(name)!
    let cursor = CGPoint(x: home.midX - 135, y: home.midY + 160)
    mouse(.mouseMoved, cursor)
    event(["type": "fixture-completion-mode", "action": "Мягкий"])
    event(["type": "fixture-completion-done", "chat": "00000000-0000-0000-0000-000000000001"])
    wait("the completion gesture takes the pointer", seconds: 3) {
        (CGEvent(source: nil)?.location).map { hypot($0.x - cursor.x, $0.y - cursor.y) > 3 } == true
    }
    event(["type": "fixture-pointer-context", "action": "activate"])
    wait("an application change sends the mascot home immediately", seconds: 0.65) { window(name) == home }
    let released = CGEvent(source: nil)!.location
    Thread.sleep(forTimeInterval: 0.55)
    precondition(CGEvent(source: nil)?.location == released)
    wait("the completion result remains available at the notch") { window("Ответ у чёлки") != nil }
} else if mode == "cursor-chase" || mode == "cursor-chase-space-change" {
    let name = "Чубзик"
    wait("mascot is at home") { window(name) != nil }
    let home = window(name)!
    let point = CGPoint(x: home.midX - 140, y: home.midY + 180)
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    precondition(front != nil && front != pid)
    mouse(.mouseMoved, point)
    Thread.sleep(forTimeInterval: 0.06)
    event(["type": "fixture-cursor-chase"])
    wait("mascot leaves the notch to chase") {
        (window(name)?.midY ?? .zero) > home.midY + 55
    }
    wait("mascot leaps and pulls the real cursor", seconds: 4) {
        guard let cursor = CGEvent(source: nil)?.location, let mascot = window(name) else { return false }
        return hypot(cursor.x - point.x, cursor.y - point.y) > 18
            && abs(mascot.midX - cursor.x) < 25 && abs(mascot.midY - cursor.y) < 25
    }
    let moved = CGEvent(source: nil)!.location
    mouse(.mouseMoved, CGPoint(x: moved.x - 55, y: moved.y - 16))
    wait("cursor stays close to the mascot while resisting", seconds: 0.25) {
        guard let cursor = CGEvent(source: nil)?.location, let mascot = window(name) else { return false }
        return cursor.x > moved.x - 19 && abs(mascot.midX - cursor.x) < 25
    }
    if mode == "cursor-chase-space-change" {
        event(["type": "fixture-pointer-context", "action": "space"])
        wait("a Space change sends the mascot home immediately", seconds: 0.65) { window(name) == home }
        let released = CGEvent(source: nil)!.location
        Thread.sleep(forTimeInterval: 0.55)
        precondition(window(name) == home && CGEvent(source: nil)?.location == released)
        print("PASS a Space change releases the pointer and ends the game")
    } else {
        key(53, hold: 0.045)
        mouse(.mouseMoved, point)
        wait("Escape releases the cursor during the flight home", seconds: 0.20) {
            CGEvent(source: nil)?.location == point
        }
        wait("Escape in another app sends mascot home") { window(name) == home }
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == front)
        Thread.sleep(forTimeInterval: 0.6)
        precondition(window(name) == home && CGEvent(source: nil)?.location == point)
        print("PASS cursor is free after Escape")
    }
} else if mode == "quick-chat-busy-image" {
    let chatName = "Быстрый чат Чубзика"
    let image = marker.appendingPathExtension("png")
    try writeFixtureImage(to: image)
    defer { try? FileManager.default.removeItem(at: image) }
    mouse(.mouseMoved, CGPoint(x: 500, y: 350))
    NSRunningApplication(processIdentifier: pid)?.activate()
    event(["type": "fixture-quick-chat"])
    wait("chat opens") { window(chatName)?.height == 52 }
    waitForQuickChatComposer()
    let draft = "Проверка вложения во время ответа"
    typeText(draft)
    sendQuickChatDraft(draft)
    wait("test reply is still loading") { window(chatName)?.height == 155 }
    key(53)
    wait("in-flight chat is hidden") { window(chatName) == nil }
    event(["type": "fixture-quick-chat-image", "path": image.path])
    wait("the chat reopens and shows a queued attachment") { window(chatName)?.height == 189 }
    wait("the image is in the next draft after the answer") { window(chatName)?.height == 334 }
    key(53)
    wait("Escape closes the quick chat") { window(chatName) == nil }
} else if mode == "quick-chat-partial-error" || mode == "quick-chat-partial-stop" {
    let chatName = "Быстрый чат Чубзика"
    let partial = "Часть ответа уже пришла."
    mouse(.mouseMoved, CGPoint(x: 500, y: 350))
    NSRunningApplication(processIdentifier: pid)?.activate()
    event(["type": "fixture-quick-chat"])
    wait("chat opens") { window(chatName)?.height == 52 }
    waitForQuickChatComposer()
    let draft = "Проверка прерванного ответа"
    typeText(draft)
    sendQuickChatDraft(draft)
    wait("the first part of the answer is displayed") { accessible { $0 == partial } != nil }
    let stopped = mode == "quick-chat-partial-stop"
    if stopped { press("Остановить") }
    let message = stopped ? "Остановлено" : "Ответ не загрузился"
    wait("partial text survives interruption") {
        accessible { $0 == message } != nil && accessible { $0 == partial } != nil
    }
    key(53)
    wait("the interrupted chat hides") { window(chatName) == nil }
    event(["type": "fixture-quick-chat"])
    wait("the interrupted answer is still readable after reopening") { accessible { $0 == partial } != nil }
    press("Повторить")
    wait("retry completes the original request") { accessible { $0 == "Это тестовый ответ." } != nil }
} else if mode == "quick-chat-transfer-codex" || mode == "quick-chat-transfer-history" {
    let chat = "Быстрый чат Чубзика"
    let image = marker.appendingPathExtension("png")
    let folder = marker.deletingLastPathComponent()
    let withHistory = mode == "quick-chat-transfer-history"
    let query = (withHistory ? "Чубзик QA история " : "Чубзик QA перенос ") + folder.lastPathComponent
    try writeFixtureImage(to: image)
    mouse(.mouseMoved, CGPoint(x: 500, y: 350))
    NSRunningApplication(processIdentifier: pid)?.activate()
    event(["type": "fixture-quick-chat-image", "path": image.path])
    wait("the quick chat has an image") { window(chat)?.height == 117 }
    waitForQuickChatComposer()
    if withHistory {
        let firstQuestion = "Что видно на тестовом снимке?"
        typeText(firstQuestion)
        sendQuickChatDraft(firstQuestion)
        wait("the completed question and answer show in Chubzik") {
            accessible { $0 == "На тестовом снимке виден зелёный прямоугольник." } != nil
        }
        waitForQuickChatComposer("Уточнение")
    }
    typeText(query)
    wait("the unsent query is ready") { accessible(role: kAXTextFieldRole) { $0 == query } != nil }
    wait("the transfer button is in the upper-right corner") {
        guard let panel = window(chat), let button = accessible(role: kAXButtonRole, { $0 == "Продолжить в Codex" }) else { return false }
        var raw: CFTypeRef?
        var position = CGPoint.zero
        guard AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetValue(raw as! AXValue, .cgPoint, &position)
        else { return false }
        return position.x >= panel.maxX - 45 && position.y <= panel.minY + 12
    }
    press("Продолжить в Codex")
    wait("the folder picker is open") { window("Папка для диалога Codex") != nil }
    Thread.sleep(forTimeInterval: 0.45)
    key(53)
    wait("canceling the picker keeps the draft and image") {
        window("Папка для диалога Codex") == nil && accessible { $0 == query } != nil
            && accessible(role: kAXButtonRole) { $0 == (withHistory ? "Открыть снимок" : "Убрать изображение") } != nil
    }
    press("Продолжить в Codex")
    wait("the folder picker reopens") { window("Папка для диалога Codex") != nil }
    key(5, flags: [.maskCommand, .maskShift])
    Thread.sleep(forTimeInterval: 0.4)
    typeText(folder.path)
    key(36)
    Thread.sleep(forTimeInterval: 0.65)
    key(36)
    wait("the completed handoff closes the quick chat", seconds: 12) {
        window(chat) == nil && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
    }
    wait("Codex opens the transferred conversation", seconds: 10) {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else { return false }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        var title: CFTypeRef?
        return AXUIElementCopyAttributeValue(raw as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
            && (title as? String) == query
    }
} else if mode == "quick-chat-attachment-remove" {
    let chatName = "Быстрый чат Чубзика"
    let image = marker.appendingPathExtension("png")
    try writeFixtureImage(to: image)
    defer { try? FileManager.default.removeItem(at: image) }
    mouse(.mouseMoved, CGPoint(x: 500, y: 350))
    NSRunningApplication(processIdentifier: pid)?.activate()
    event(["type": "fixture-quick-chat"])
    wait("chat opens") { window(chatName)?.height == 52 }
    waitForQuickChatComposer()
    let draft = "Черновик должен остаться"
    typeText(draft)
    event(["type": "fixture-quick-chat-image", "path": image.path])
    press("Отменить загрузку изображения")
    Thread.sleep(forTimeInterval: 1.1)
    wait("a cancelled import does not attach a file") { window(chatName)?.height == 52 }
    key(53)
    wait("the draft is hidden") { window(chatName) == nil }
    event(["type": "fixture-quick-chat"])
    wait("the draft text survives reopening") { accessible { $0 == draft } != nil }
    event(["type": "fixture-quick-chat-image", "path": image.path])
    wait("the image can be attached again") { window(chatName)?.height == 117 }
    press("Убрать изображение")
    wait("removing the attachment keeps the draft text") {
        window(chatName)?.height == 52 && accessible { $0 == draft } != nil
    }
} else if mode.hasPrefix("quick-chat-restart-") {
    let chatName = "Быстрый чат Чубзика"
    let firstQuestion = "Диалог для восстановления"
    let followUp = "Черновик уточнения"
    let newChatDraft = "Открытый черновик"
    let imageQuestion = "Вопрос о тестовом изображении"
    let selectedText = "Фрагмент для вопроса\nВторая строка"
    let interrupted = "Часть ответа уже пришла."
    let withImage = mode.contains("-image-")
    let image = marker.appendingPathExtension("png")
    if withImage || mode.hasSuffix("-seed") || mode.hasSuffix("-reattach") { try writeFixtureImage(to: image) }
    defer { try? FileManager.default.removeItem(at: image) }
    mouse(.mouseMoved, CGPoint(x: 500, y: 350))
    key(49, flags: .maskAlternate)
    wait("the quick chat opens") { window(chatName) != nil }

    if mode == "quick-chat-restart-storage-seed" {
        let directory = marker.deletingLastPathComponent()
        let archive = directory.appendingPathComponent("quick-chats.json")
        let drafts = directory.appendingPathComponent("quick-chat-drafts.json")
        let backup = directory.appendingPathComponent("quick-chat-drafts.backup.json")
        let files = FileManager.default
        let answer = "Это тестовый ответ."
        let warning = "Чат пока не сохранён"

        func archivedAnswer() -> String? {
            guard let bytes = try? Data(contentsOf: archive),
                  let chats = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
                  let entries = chats.first?["entries"] as? [[String: Any]] else { return nil }
            return entries.first?["answer"] as? String
        }

        try files.createDirectory(at: archive, withIntermediateDirectories: false)
        waitForQuickChatComposer()
        typeText(firstQuestion)
        sendQuickChatDraft(firstQuestion)
        wait("the question is recoverable while waiting for its answer") {
            savedQuickChatDrafts().first?["question"] as? String == firstQuestion
        }
        wait("the answer arrives even though the history path is unavailable") {
            accessible { $0 == answer } != nil
        }
        wait("a failed history write preserves the recoverable question") {
            savedQuickChatDrafts().first?["question"] as? String == firstQuestion
        }
        wait("the chat shows that the answer is still unsaved") { accessible { $0 == warning } != nil }

        try files.moveItem(at: drafts, to: backup)
        try files.createDirectory(at: drafts, withIntermediateDirectories: false)
        try files.removeItem(at: archive)
        wait("history retries without user input even when drafts still cannot be saved", seconds: 7) {
            archivedAnswer() == answer && accessible { $0 == warning } != nil
        }
        waitForQuickChatComposer("Уточнение")
        typeText(followUp)
        wait("the latest follow-up remains editable") { accessible(role: kAXTextFieldRole) { $0 == followUp } != nil }
        precondition(kill(pid, SIGTERM) == 0)
        press("Продолжить работу")
        wait("canceling quit keeps the follow-up and the answer") {
            accessible { $0 == followUp } != nil && accessible { $0 == answer } != nil
                && accessible(role: kAXButtonRole) { $0 == "Продолжить работу" } == nil
        }
        try files.removeItem(at: drafts)
        try files.moveItem(at: backup, to: drafts)
        wait("the newest follow-up is saved once its path recovers", seconds: 7) {
            let saved = savedQuickChatDrafts().first
            return saved?["exchangeCount"] as? Int == 1 && saved?["text"] as? String == followUp
                && saved?["question"] == nil && accessible { $0 == warning } == nil
        }
    } else if mode == "quick-chat-restart-storage-restore" {
        wait("the finished answer and the latest follow-up return together after restart") {
            accessible { $0 == firstQuestion } != nil && accessible { $0 == "Это тестовый ответ." } != nil
                && accessible(role: kAXTextFieldRole) { $0 == followUp } != nil
        }
    } else if mode == "quick-chat-restart-context-seed" {
        event(["type": "fixture-quick-chat", "title": selectedText])
        wait("selected text alone creates a recoverable draft") {
            let saved = savedQuickChatDrafts().first
            return accessible { $0 == "Выделенный текст: " + selectedText } != nil
                && saved?["selectedText"] as? String == selectedText && saved?["text"] as? String == ""
        }
    } else if mode == "quick-chat-restart-context-restore" {
        wait("selected text returns with both lines after restart") {
            accessible { $0 == "Выделенный текст: " + selectedText } != nil
        }
        waitForQuickChatComposer()
        typeText(firstQuestion)
        sendQuickChatDraft(firstQuestion)
        wait("only one copy of the restored context is included in the sent question") {
            let url = marker.deletingLastPathComponent().appendingPathComponent("quick-chats.json")
            guard let data = try? Data(contentsOf: url),
                  let chats = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let entries = chats.first?["entries"] as? [[String: Any]] else { return false }
            return entries.first?["question"] as? String == firstQuestion + "\n\nВыделенный текст:\n" + selectedText
                && savedQuickChatDrafts().isEmpty
        }
    } else if mode == "quick-chat-restart-context-remove" {
        press("Убрать выделенный текст")
        wait("removing selected text clears the empty saved draft") {
            savedQuickChatDrafts().isEmpty && accessible { $0 == "Выделенный текст: " + selectedText } == nil
        }
    } else if mode == "quick-chat-restart-compose-seed" {
        waitForQuickChatComposer()
        typeText(firstQuestion)
        sendQuickChatDraft(firstQuestion)
        wait("the first exchange is completed") { accessible { $0 == "Это тестовый ответ." } != nil }
        waitForQuickChatComposer("Уточнение")
        typeText(followUp)
        key(53)
        wait("the conversation hides before creating a new chat") { window(chatName) == nil }
        chooseQuickChatMenuItem("Новый чат")
        waitForQuickChatComposer()
        typeText(newChatDraft)
        event(["type": "fixture-quick-chat-image", "path": image.path])
        wait("two separate drafts are autosaved and only attachment metadata is stored") {
            let drafts = savedQuickChatDrafts()
            return drafts.count == 2 && drafts.first?["text"] as? String == newChatDraft
                && drafts.first?["composerHadImage"] as? Bool == true && drafts.last?["text"] as? String == followUp
                && Set(drafts[0].keys) == ["id", "exchangeCount", "text", "questionHadImage", "composerHadImage"]
        }
    } else if mode == "quick-chat-restart-compose-restore" {
        wait("Option Space restores the latest text draft after restart") {
            accessible(role: kAXTextFieldRole) { $0 == newChatDraft } != nil
        }
        wait("the user is told to reattach an image from before restart") {
            accessible { $0 == "Прикрепи изображение заново" } != nil && window(chatName)?.height == 96
        }
        key(53)
        wait("the restored draft hides") { window(chatName) == nil }
        chooseQuickChatMenuItem(firstQuestion)
        wait("the selected conversation opens with its own follow-up and transcript") {
            accessible(role: kAXTextFieldRole) { $0 == followUp } != nil && accessible { $0 == firstQuestion } != nil
        }
        waitForQuickChatComposer("Уточнение")
        sendQuickChatDraft(followUp)
        wait("sending the follow-up removes only its own saved draft") {
            savedQuickChatDrafts().compactMap { $0["text"] as? String } == [newChatDraft]
        }
    } else if mode == "quick-chat-restart-image-seed" {
        waitForQuickChatComposer()
        event(["type": "fixture-quick-chat-image", "path": image.path])
        wait("the input has an image") { window(chatName)?.height == 117 }
        typeText(imageQuestion)
        sendQuickChatDraft(imageQuestion)
        wait("an unfinished answer with image metadata is saved while streaming") {
            let saved = savedQuickChatDrafts().first
            return accessible { $0 == interrupted } != nil && saved?["question"] as? String == imageQuestion
                && saved?["partial"] as? String == interrupted && saved?["questionHadImage"] as? Bool == true
        }
    } else if mode == "quick-chat-restart-image-restore" {
        wait("the interrupted question and partial answer are visible on restart") {
            accessible { $0 == imageQuestion } != nil && accessible { $0 == interrupted } != nil
                && accessible { $0 == "Запрос прерван. Прикрепи изображение заново" } != nil
        }
        let retry = accessible(role: kAXButtonRole) { $0 == "Повторить" }!
        var enabled: CFTypeRef?
        precondition(AXUIElementCopyAttributeValue(retry, kAXEnabledAttribute as CFString, &enabled) == .success
                     && enabled as? Bool == false)
        print("PASS retry is disabled until the user attaches an image")
        event(["type": "fixture-quick-chat-image", "path": image.path])
        wait("the replacement image is attached") { window(chatName)?.height == 334 }
        press("Повторить")
        wait("retry sends the original question with its replacement image") {
            accessible { $0 == "На тестовом снимке виден зелёный прямоугольник." } != nil
        }
        wait("the finished exchange removes the interrupted draft") { savedQuickChatDrafts().isEmpty }
    } else if mode == "quick-chat-restart-attachment-seed" {
        waitForQuickChatComposer()
        typeText(firstQuestion)
        sendQuickChatDraft(firstQuestion)
        wait("the answer is still loading") { window(chatName)?.height == 155 }
        key(53)
        wait("the loading chat is hidden") { window(chatName) == nil }
        event(["type": "fixture-quick-chat-image", "path": image.path])
        wait("the image is queued for the next message") { window(chatName)?.height == 189 }
        wait("the first answer and next attachment are visible") { window(chatName)?.height == 334 }
        key(53)
        wait("an attachment-only follow-up is saved without image bytes") {
            let drafts = savedQuickChatDrafts()
            guard drafts.count == 1, let draft = drafts.first else { return false }
            return window(chatName) == nil && draft["exchangeCount"] as? Int == 1
                && draft["text"] as? String == "" && draft["composerHadImage"] as? Bool == true
                && Set(draft.keys) == ["id", "exchangeCount", "text", "questionHadImage", "composerHadImage"]
        }
    } else if mode.hasPrefix("quick-chat-restart-attachment-restore") {
        wait("the completed chat reopens with its missing attachment reminder") {
            accessible { $0 == firstQuestion } != nil && accessible { $0 == "Прикрепи изображение заново" } != nil
        }
        waitForQuickChatComposer("Уточнение")
        typeText(followUp)
        wait("the send button stays disabled until the attachment is handled") {
            guard let send = accessible(role: kAXButtonRole, { $0 == "Отправить" }) else { return false }
            var enabled: CFTypeRef?
            return AXUIElementCopyAttributeValue(send, kAXEnabledAttribute as CFString, &enabled) == .success
                && enabled as? Bool == false
        }
        key(36)
        Thread.sleep(forTimeInterval: 0.12)
        wait("Return keeps the follow-up while its image is missing") {
            accessible(role: kAXTextFieldRole) { $0 == followUp } != nil
                && accessible { $0 == "Прикрепи изображение заново" } != nil
        }
        let reattach = mode.hasSuffix("-reattach")
        if reattach {
            event(["type": "fixture-quick-chat-image", "path": image.path])
        } else {
            press("Убрать вложение")
        }
        wait("resolving the missing attachment keeps the typed follow-up") {
            accessible(role: kAXTextFieldRole) { $0 == followUp } != nil
                && accessible { $0 == "Прикрепи изображение заново" } == nil
        }
        sendQuickChatDraft(followUp)
        let answer = reattach ? "На тестовом снимке виден зелёный прямоугольник." : "Это тестовый ответ."
        wait("the follow-up completes and its draft is removed") {
            savedQuickChatDrafts().isEmpty && accessible { $0 == followUp } != nil
                && accessible { $0 == answer } != nil
        }
    }
} else if mode.hasPrefix("quick-chat-capture-context-") {
    let chatName = "Быстрый чат Чубзика"
    let capture = "Выбор области"
    let draft = "Черновик перед сменой контекста"
    mouse(.mouseMoved, CGPoint(x: 450, y: 270))
    event(["type": "fixture-quick-chat"])
    wait("the quick chat opens") { window(chatName)?.height == 52 }
    waitForQuickChatComposer()
    typeText(draft)
    wait("the draft is present") { accessible(role: kAXTextFieldRole) { $0 == draft } != nil }
    if mode.hasSuffix("shortcut") {
        let command = Process()
        let host = ProcessInfo.processInfo.environment["CHUBZIK_SHORTCUT_HOST"]!
        let receipt = marker.appendingPathExtension("key")
        let ready = receipt.appendingPathExtension("ready")
        command.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        command.arguments = ["-n", "-a", host, "--args", "--capture-shortcut-host", receipt.path]
        try command.run()
        command.waitUntilExit()
        precondition(command.terminationStatus == 0)
        var hostPID: pid_t?
        wait("the external key probe starts") {
            hostPID = (try? String(contentsOf: ready, encoding: .utf8)).flatMap { pid_t($0) }
            return hostPID != nil
        }
        let externalPID = hostPID!
        defer { _ = kill(externalPID, SIGTERM) }
        key(13, flags: [.maskCommand, .maskShift])
        wait("the external app receives Command Shift W without arming the chat") {
            FileManager.default.fileExists(atPath: receipt.path) && window(capture) == nil
        }
        _ = kill(externalPID, SIGTERM)
        wait("the external app has left the foreground") {
            kill(externalPID, 0) != 0
        }
        event(["type": "fixture-quick-chat"])
        waitForQuickChatComposer()
    }
    key(13, flags: [.maskCommand, .maskShift])
    wait("the focused chat arms its area selector") { window(capture) != nil }
    key(13, flags: [.maskCommand, .maskShift])
    wait("the same chord disarms the selector") { window(capture) == nil }
    key(13, flags: [.maskCommand, .maskShift])
    wait("the selector can be armed again") { window(capture) != nil }
    let start = CGPoint(x: 250, y: 370), end = CGPoint(x: 425, y: 550)
    mouse(.mouseMoved, start)
    mouse(.leftMouseDown, start)
    Thread.sleep(forTimeInterval: 0.05)
    mouse(.leftMouseDragged, end)
    let action = mode.hasSuffix("app") ? "activate" : "space"
    event(["type": "fixture-pointer-context", "action": action])
    let deadline = ProcessInfo.processInfo.systemUptime + 0.55
    while window(capture) != nil && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    let selectorWasDismissed = window(capture) == nil
    mouse(.leftMouseUp, end)
    wait("a context switch cancels the selection before release") { selectorWasDismissed && window(capture) == nil }
    Thread.sleep(forTimeInterval: 0.2)
    wait("releasing the stale drag leaves the text draft and adds no image") {
        window(chatName)?.height == 52 && accessible(role: kAXTextFieldRole) { $0 == draft } != nil
    }
} else if mode == "quick-chat" || mode == "quick-chat-region" {
    let chatName = "Быстрый чат Чубзика"
    mouse(.mouseMoved, CGPoint(x: 450, y: 270))
    Thread.sleep(forTimeInterval: 0.045)
    if mode == "quick-chat-region" {
        NSRunningApplication(processIdentifier: pid)?.activate()
        event(["type": "fixture-quick-chat"])
    }
    else { key(49, flags: .maskAlternate) }
    wait("quick chat opens") { window(chatName) != nil }
    let before = window(chatName)!
    mouse(.mouseMoved, CGPoint(x: 265, y: 630))
    Thread.sleep(forTimeInterval: 0.04)
    let latest = CGPoint(x: 875, y: 570)
    mouse(.mouseMoved, latest)
    wait("chat follows on pointer movement") {
        guard let after = window(chatName) else { return false }
        return abs(after.midY - before.midY) > 150 && abs(after.midX - before.midX) > 100
    }
    wait("mascot catches the latest position without a third motion event", seconds: 2) {
        guard let mascot = window("Чубзик") else { return false }
        return abs(mascot.midX - latest.x) < 76 && abs(mascot.midY - latest.y) < 75
    }
    let settled = window("Чубзик")!
    mouse(.mouseMoved, CGPoint(x: 430, y: 620))
    wait("mascot starts following a new direction") { (window("Чубзик")?.midX ?? .infinity) < settled.midX - 45 }
    let beforeReversal = window("Чубзик")!
    mouse(.mouseMoved, CGPoint(x: 1020, y: 270))
    wait("chat mascot follows a second turn promptly", seconds: 0.25) {
        (window("Чубзик")?.midY ?? .infinity) < beforeReversal.midY - 45
    }
    let after = window(chatName)!
    key(48)
    Thread.sleep(forTimeInterval: 0.28)
    wait("Tab leaves the composer without attaching an image") { window(chatName)?.height == after.height }
    if mode == "quick-chat-region" {
        let capture = "Выбор области"
        precondition(window(capture) == nil)
        key(13, flags: [.maskCommand, .maskShift])
        wait("Command Shift W arms region selection") { window(capture) != nil }
        let start = CGPoint(x: 530, y: 480)
        mouse(.mouseMoved, start)
        Thread.sleep(forTimeInterval: 0.18)
        precondition(window(capture) != nil && window(chatName)?.height == after.height
                     && windowInfo(chatName)?[kCGWindowAlpha as String] as? Double == 1,
                     "Moving to the start point must not begin a selection")
        click(start)
        Thread.sleep(forTimeInterval: 0.18)
        precondition(window(chatName)?.height == after.height, "A click captured an image")
        mouse(.leftMouseDown, start)
        mouse(.leftMouseDragged, CGPoint(x: start.x + 7, y: start.y + 7))
        mouse(.leftMouseUp, CGPoint(x: start.x + 7, y: start.y + 7))
        Thread.sleep(forTimeInterval: 0.18)
        precondition(window(chatName)?.height == after.height, "A short drag captured an image")
        print("PASS click and short drag leave the composer unchanged")
        let end = CGPoint(x: start.x + 120, y: start.y + 85)
        mouse(.leftMouseDown, start)
        mouse(.leftMouseDragged, end)
        Thread.sleep(forTimeInterval: 0.08)
        precondition(windowInfo(chatName)?[kCGWindowAlpha as String] as? Double == 0 || window(chatName) == nil)
        key(53)
        mouse(.leftMouseUp, end)
        wait("Escape cancels selection without adding an image") {
            window(capture) == nil && window(chatName)?.height == after.height
                && windowInfo(chatName)?[kCGWindowAlpha as String] as? Double == 1
        }
        key(13, flags: [.maskCommand, .maskShift])
        wait("Command Shift W arms the next selection") { window(capture) != nil }
        mouse(.mouseMoved, start)
        Thread.sleep(forTimeInterval: 0.04)
        mouse(.leftMouseDown, start)
        mouse(.leftMouseDragged, end)
        Thread.sleep(forTimeInterval: 0.08)
        mouse(.leftMouseUp, end)
        wait("area drag attaches exactly one image and disarms selection") {
            window(chatName)?.height == 117 && window(capture) == nil
        }
        typeText("Проверка вложения")
        key(36)
        wait("fixture answer appears in the transcript") { window(chatName)?.height == 269 }
        key(13, flags: [.maskCommand, .maskShift])
        wait("Command Shift W arms selection in an existing dialogue") { window(capture) != nil }
        mouse(.mouseMoved, start)
        mouse(.leftMouseDown, start)
        mouse(.leftMouseDragged, end)
        Thread.sleep(forTimeInterval: 0.08)
        mouse(.leftMouseUp, end)
        wait("image is attached to a follow-up draft") { window(chatName)?.height == 334 && window(capture) == nil }
        event(["type": "fixture-quick-chat-image", "path": marker.appendingPathExtension("missing.png").path])
        wait("failed replacement shows an error and keeps the previous attachment") { window(chatName)?.height == 378 }
    }
    key(53)
    wait("Escape closes the quick chat") { window(chatName) == nil }
} else if mode == "file-shortcut-conflict" || mode == "file-shortcut-restart" {
    let root = marker.deletingLastPathComponent()
    let download = root.appendingPathComponent("shortcut-download.txt")
    let codex = root.appendingPathComponent("shortcut-codex.txt")
    for file in [download, codex] { try Data("Fixture".utf8).write(to: file) }
    let settings = "Настройки Чубзика"
    let card = "Файл у указателя"
    func openSettings() {
        mouse(.mouseMoved, CGPoint(x: 735, y: 22))
        event(["type": "show"])
        press("Настройки")
        wait("settings opens") { window(settings) != nil }
        press("Файлы")
    }
    func picker(_ value: String) -> AXUIElement? {
        accessible(role: kAXPopUpButtonRole) { $0 == value }
    }
    func center(of element: AXUIElement) -> CGPoint? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var origin = CGPoint.zero
        var bounds = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &bounds), bounds.width > 0, bounds.height > 0 else { return nil }
        return CGPoint(x: origin.x + bounds.width / 2, y: origin.y + bounds.height / 2)
    }
    func choose(_ value: String, from current: String) {
        var point: CGPoint?
        wait("the file shortcut picker shows \(current)") {
            point = picker(current).flatMap(center)
            return point != nil
        }
        click(point!)
        wait("the menu offers \(value)") {
            point = accessible(role: kAXMenuItemRole, { $0 == value }).flatMap(center)
            return point != nil
        }
        click(point!)
        wait("the shortcut menu closes") { accessible(role: kAXMenuItemRole, { $0 == value }) == nil }
    }
    func warn(_ shortcut: String) -> Bool { accessible { $0 == "Не удалось назначить \(shortcut)." } != nil }
    func closeSettings() {
        key(53)
        wait("settings closes") { window(settings) == nil }
        var frontmost: pid_t?
        var lastChange = ProcessInfo.processInfo.systemUptime
        wait("window focus settles before the hotkey is pressed", seconds: 4) {
            let now = ProcessInfo.processInfo.systemUptime
            let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if current != frontmost {
                frontmost = current
                lastChange = now
            }
            return frontmost != nil && now - lastChange >= 0.5
        }
    }
    func receives(_ code: CGKeyCode, _ file: URL) {
        mouse(.mouseMoved, CGPoint(x: 620, y: 340))
        key(code, flags: [.maskControl, .maskAlternate])
        wait("the global shortcut delivers \(file.lastPathComponent)") {
            window(card) != nil && accessible { $0 == file.lastPathComponent } != nil
        }
        key(53)
        wait("the file card closes") { window(card) == nil }
    }
    event(["type": "download", "source": "com.kiridey.ardia.personal", "path": download.path])
    event(["type": "fixture-hook-done", "source": "codex-hook", "files": [codex.path]])
    openSettings()
    if mode == "file-shortcut-conflict" {
        choose("⌃⌥R", from: "⌃⌥F")
        wait("an internal collision leaves both previous selections in place") {
            warn("⌃⌥R") && picker("⌃⌥F") != nil && picker("⌃⌥R") != nil
        }
        closeSettings()
        receives(3, download)
        receives(15, codex)

        openSettings()
        choose("⌃⌥U", from: "⌃⌥R")
        wait("Codex can move to an available chord") { picker("⌃⌥U") != nil }
        choose("⌃⌥R", from: "⌃⌥F")
        wait("the old Codex chord can now be assigned to downloads") {
            picker("⌃⌥R") != nil && picker("⌃⌥U") != nil && !warn("⌃⌥R")
        }
    } else {
        wait("relaunch restores both selected chords without warnings") {
            picker("⌃⌥R") != nil && picker("⌃⌥U") != nil && !warn("⌃⌥R") && !warn("⌃⌥U")
        }
    }
    closeSettings()
    receives(15, download)
    receives(32, codex)
} else if mode == "file-handoff-history" {
    let cardName = "Файл у указателя"
    let root = marker.deletingLastPathComponent()
    let first = root.appendingPathComponent("Первый результат.txt")
    let latest = [root.appendingPathComponent("Последний результат.txt"), root.appendingPathComponent("Дополнение.txt")]
    for file in [first] + latest { try Data("Тест файла".utf8).write(to: file) }
    defer { for file in [first] + latest { try? FileManager.default.removeItem(at: file) } }
    func report(_ files: [URL]) {
        event(["type": "fixture-hook-done", "source": "codex-hook", "files": files.map(\.path)])
    }
    func shows(_ file: URL) -> Bool {
        window(cardName) != nil && accessible { $0 == file.lastPathComponent } != nil
    }
    mouse(.mouseMoved, CGPoint(x: 620, y: 340))
    report([first])
    report([latest[0], latest[1], latest[0]])
    report([])
    key(15, flags: [.maskControl, .maskAlternate])
    wait("the latest reply with files is delivered") { shows(latest[0]) }
    wait("only the selected reply's distinct files are counted") { accessible { $0 == "1/2" } != nil }
    key(124)
    wait("Right switches to the second file from the same reply") { shows(latest[1]) }
    key(53)
    wait("the file card closes") { window(cardName) == nil }
    for file in latest { try FileManager.default.removeItem(at: file) }
    key(15, flags: [.maskControl, .maskAlternate])
    wait("after the latest files are deleted the previous result is delivered") { shows(first) }
    precondition(accessible { $0 == "1/2" || $0 == "2/2" } == nil)
} else if mode == "file-handoff-keeps-drag" {
    let cardName = "Файл у указателя"
    let root = marker.deletingLastPathComponent()
    let first = root.appendingPathComponent("drag-origin.txt")
    let next = root.appendingPathComponent("drag-next.txt")
    for file in [first, next] { try Data("Fixture".utf8).write(to: file) }
    func download(_ file: URL) {
        event(["type": "download", "source": "com.kiridey.ardia.personal", "path": file.path])
    }
    func brings(_ file: URL) -> Bool {
        window(cardName) != nil && accessible { $0 == file.lastPathComponent } != nil
    }
    mouse(.mouseMoved, CGPoint(x: 620, y: 340))
    download(first)
    event(["type": "fixture-bring-download"])
    wait("the first file card is available") { brings(first) }
    let card = window(cardName)!
    let start = CGPoint(x: card.minX + 23, y: card.midY)
    let end = CGPoint(x: start.x + 55, y: start.y + 54)
    mouse(.mouseMoved, start)
    mouse(.leftMouseDown, start)
    Thread.sleep(forTimeInterval: 0.08)
    mouse(.leftMouseDragged, end)
    func draggingOriginal() -> Bool {
        guard let rawURL = NSPasteboard(name: .drag).string(forType: .fileURL), let url = URL(string: rawURL) else { return false }
        return url.resolvingSymlinksInPath() == first.resolvingSymlinksInPath()
    }
    let dragDeadline = Date().addingTimeInterval(2)
    while !draggingOriginal(), Date() < dragDeadline { Thread.sleep(forTimeInterval: 0.035) }
    if !draggingOriginal() {
        key(53)
        mouse(.leftMouseUp, end)
        preconditionFailure("AppKit did not expose the original file URL in the drag")
    }
    print("PASS AppKit starts dragging the original file URL")
    download(next)
    event(["type": "fixture-bring-download"])
    Thread.sleep(forTimeInterval: 0.28)
    let preservedAfterHandoff = brings(first) && window(cardName) == card && draggingOriginal()
    event(["type": "fixture-quick-chat"])
    Thread.sleep(forTimeInterval: 0.28)
    let preservedAfterChat = brings(first) && window(cardName) == card && draggingOriginal()
        && window("Быстрый чат Чубзика") == nil
    let cancelPoint = CGPoint(x: 230, y: 10)
    mouse(.leftMouseDragged, cancelPoint)
    key(53)
    Thread.sleep(forTimeInterval: 0.2)
    mouse(.leftMouseUp, cancelPoint)
    precondition(preservedAfterHandoff, "A second request replaced the card while its file was being dragged")
    precondition(preservedAfterChat, "Opening Quick Chat interrupted the active file drag")
    Thread.sleep(forTimeInterval: 0.75)
    mouse(.mouseMoved, CGPoint(x: 620, y: 340))
    event(["type": "fixture-bring-download"])
    wait("after cancelling the drag a new request selects the latest file") { brings(next) }
    event(["type": "fixture-quick-chat"])
    wait("quick chat opens after the drag is over") {
        window("Быстрый чат Чубзика") != nil && window(cardName) == nil
    }
} else if mode == "file-handoff-missing-in-flight" {
    let cursor = CGPoint(x: 620, y: 340)
    let file = marker.appendingPathExtension("txt")
    try Data("Fixture".utf8).write(to: file)
    mouse(.mouseMoved, cursor)
    event(["type": "download", "source": "com.kiridey.ardia.personal", "path": file.path])
    event(["type": "fixture-bring-download"])
    wait("the handoff cargo is in flight") { window("Чубзик несёт файл") != nil }
    try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("moved"))
    wait("a file moved during flight is reported before a drag can start") {
        window("Файл у указателя") != nil && accessible { $0 == "Файл больше недоступен" } != nil
    }
    wait("the unavailable notice expires", seconds: 3) { window("Файл у указателя") == nil }
} else if mode == "file-handoff-edges" {
    let cardName = "Файл у указателя"
    let cursor = CGPoint(x: 620, y: 340)
    mouse(.mouseMoved, cursor)
    event(["type": "fixture-bring-codex-file"])
    wait("the empty Codex card fits its complete message") {
        guard let card = window(cardName) else { return false }
        let text = "Нет файлов в результатах Codex" as NSString
        let width = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return card.width >= ceil(width) + 24
    }
    wait("the empty card dismisses", seconds: 3) { window(cardName) == nil }

    let file = marker.appendingPathExtension("txt")
    try Data("Fixture".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    event(["type": "download", "source": "com.kiridey.ardia.personal", "path": file.path])
    Thread.sleep(forTimeInterval: 0.15)
    event(["type": "fixture-bring-download"])
    wait("a completed download reaches the cursor") { window(cardName) != nil }
    try FileManager.default.removeItem(at: file)
    let card = window(cardName)!
    let start = CGPoint(x: card.minX + 26, y: card.midY)
    let end = CGPoint(x: start.x + 85, y: start.y + 32)
    mouse(.mouseMoved, start)
    mouse(.leftMouseDown, start)
    Thread.sleep(forTimeInterval: 0.07)
    mouse(.leftMouseDragged, end)
    Thread.sleep(forTimeInterval: 0.08)
    mouse(.leftMouseUp, end)
    wait("the unavailable file card disappears", seconds: 3) { window(cardName) == nil }
} else if mode == "shelf-search-skip-missing" {
    mouse(.mouseMoved, CGPoint(x: 735, y: 20))
    event(["type": "fixture-shelf"])
    wait("the two search matches are listed") {
        accessible { $0.hasPrefix("ChubzikSearch 1.txt") } != nil && accessible { $0 == "ChubzikSearch 2.txt" } != nil
    }
    press("Найти файл")
    wait("the shelf search field is focused") {
        guard let field = accessible(role: kAXTextFieldRole, { $0 == "Поиск файлов на полке" }) else { return false }
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &focused) == .success
            && focused as? Bool == true
    }
    typeText("ChubzikSearch")
    key(36)
    wait("Return opens the existing result after skipping the missing file", seconds: 6) {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        return windows.contains {
            $0[kCGWindowOwnerPID as String] as? Int32 != pid
                && ($0[kCGWindowName as String] as? String)?.contains("ChubzikSearch 2") == true
        }
    }
} else if mode == "shelf-search-renamed-file" {
    let root = marker.deletingLastPathComponent()
    let original = root.appendingPathComponent("Before.txt")
    let renamed = root.appendingPathComponent("Invoice.txt")
    mouse(.mouseMoved, CGPoint(x: 735, y: 20))
    event(["type": "fixture-shelf"])
    wait("the original file is visible") { accessible { $0 == original.lastPathComponent } != nil }
    let store = root.appendingPathComponent("shelf.json")
    wait("the shelf records the current file") {
        guard let data = try? Data(contentsOf: store),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bookmarks = saved["bookmarks"] as? [String: String] else { return false }
        return bookmarks[original.path] != nil
    }
    press("Найти файл")
    func searchKeepsFocus() -> Bool {
        guard let field = accessible(role: kAXTextFieldRole, { $0 == "Поиск файлов на полке" }) else { return false }
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &focused) == .success
            && focused as? Bool == true
    }
    wait("the shelf search takes keyboard focus", searchKeepsFocus)
    typeText("Invoice")
    wait("search starts with no matching files") { accessible { $0 == "Файлы не найдены" } != nil }
    try FileManager.default.moveItem(at: original, to: renamed)
    wait("search finds a renamed file without reopening the shelf", seconds: 5) {
        accessible { $0 == renamed.lastPathComponent } != nil
    }
    precondition(searchKeepsFocus(), "Refreshing the search stole keyboard focus")
} else if mode == "shelf-case-rename" || mode == "shelf-thumbnail-replaced" || mode == "shelf-undo-pinned" {
    let root = marker.deletingLastPathComponent()
    let original = root.appendingPathComponent("Preview.png")
    let stored = root.appendingPathComponent("shelf.json")
    mouse(.mouseMoved, CGPoint(x: 735, y: 20))
    event(["type": "fixture-shelf"])
    wait("the original file is visible on the shelf") { accessible { $0 == original.lastPathComponent } != nil }
    wait("the shelf has the original bookmark") {
        guard let bytes = try? Data(contentsOf: stored),
              let shelf = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let bookmarks = shelf["bookmarks"] as? [String: String] else { return false }
        return bookmarks[original.path] != nil
    }
    Thread.sleep(forTimeInterval: 0.6)
    if mode == "shelf-undo-pinned" {
        let shelf = window("Островок")!
        click(CGPoint(x: shelf.minX + 65, y: shelf.minY + 102))
        key(51)
        wait("Backspace removes the shelf link while leaving the original file") {
            FileManager.default.fileExists(atPath: original.path) && accessible { $0 == original.lastPathComponent } == nil
        }
        press("Отменить")
        wait("Undo restores the original file link and pin") {
            guard let bytes = try? Data(contentsOf: stored),
                  let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            return state["paths"] as? [String] == [original.path] && state["pins"] as? [String] == [original.path]
                && accessible { $0 == original.lastPathComponent } != nil
        }
    } else if mode == "shelf-case-rename" {
        let shelf = window("Островок")!
        click(CGPoint(x: shelf.minX + 65, y: shelf.minY + 102))
        let renamed = root.appendingPathComponent("preview.png")
        try FileManager.default.moveItem(at: original, to: renamed)
        wait("a case-only rename updates the open shelf and keeps the pin", seconds: 6) {
            guard let bytes = try? Data(contentsOf: stored),
                  let shelf = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let paths = shelf["paths"] as? [String], let pins = shelf["pins"] as? [String] else { return false }
            return accessible { $0 == renamed.lastPathComponent } != nil && paths == pins
                && paths.map { URL(fileURLWithPath: $0).lastPathComponent } == [renamed.lastPathComponent]
        }
        key(49)
        wait("Quick Look opens the renamed file without selecting it again") { window(renamed.lastPathComponent) != nil }
    } else {
        capture("shelf-before-replacement")
        let replacement = root.appendingPathComponent("replacement.png")
        try writeFixtureImage(to: replacement, color: NSColor(deviceRed: 0.91, green: 0.13, blue: 0.17, alpha: 1))
        _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
        Thread.sleep(forTimeInterval: 3.4)
        capture("shelf-after-replacement")
    }
} else if mode == "shelf-replaced-file" || mode == "shelf-replaced-restart" {
    let root = marker.deletingLastPathComponent()
    let original = root.appendingPathComponent("Текущий файл.txt")
    let archived = root.appendingPathComponent("Старая версия.txt")
    let renamed = root.appendingPathComponent("Переименованная новая версия.txt")
    let store = root.appendingPathComponent("shelf.json")

    func storedShelf() -> [String: Any] {
        guard let data = try? Data(contentsOf: store) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    func bookmark() -> String? { (storedShelf()["bookmarks"] as? [String: String])?[original.path] }

    if mode == "shelf-replaced-restart" {
        try FileManager.default.moveItem(at: original, to: renamed)
    }
    mouse(.mouseMoved, CGPoint(x: 735, y: 20))
    event(["type": "fixture-shelf"])
    if mode == "shelf-replaced-file" {
        wait("the original file is listed and tracked") {
            accessible { $0 == original.lastPathComponent } != nil && bookmark() != nil
        }
        let previousBookmark = bookmark()
        try FileManager.default.moveItem(at: original, to: archived)
        try Data("replacement".utf8).write(to: original, options: .atomic)
        wait("replacing a file at the same path updates the saved reference", seconds: 6) {
            bookmark().map { $0 != previousBookmark } == true && storedShelf()["pins"] as? [String] == [original.path]
        }
    } else {
        wait("after restart the shelf follows the replacement and keeps its pin", seconds: 6) {
            let shelf = storedShelf()
            let paths = shelf["paths"] as? [String]
            return paths == shelf["pins"] as? [String]
                && paths?.map { URL(fileURLWithPath: $0).lastPathComponent } == [renamed.lastPathComponent]
                && accessible { $0 == renamed.lastPathComponent } != nil
        }
        let previousContents = try String(contentsOf: archived, encoding: .utf8)
        precondition(previousContents == "original")
        let panel = window("Островок")!
        click(CGPoint(x: panel.minX + 65, y: panel.minY + 102))
        key(49)
        wait("Quick Look opens the relocated replacement") { window(renamed.lastPathComponent) != nil }
        key(53)
        wait("closing Quick Look returns to the shelf") { window(renamed.lastPathComponent) == nil && window("Островок") != nil }
        let start = CGPoint(x: panel.minX + 65, y: panel.minY + 102)
        let end = CGPoint(x: start.x + 90, y: panel.maxY + 38)
        mouse(.mouseMoved, start)
        mouse(.leftMouseDown, start)
        Thread.sleep(forTimeInterval: 0.08)
        mouse(.leftMouseDragged, end)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var draggedReplacement = false
        while !draggedReplacement, ProcessInfo.processInfo.systemUptime < deadline {
            let path = NSPasteboard(name: .drag).string(forType: .fileURL).flatMap(URL.init(string:))
            draggedReplacement = path?.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath()
            Thread.sleep(forTimeInterval: 0.035)
        }
        key(53)
        mouse(.leftMouseUp, end)
        precondition(draggedReplacement, "The shelf drag must export the relocated replacement")
        print("PASS dragging from the shelf exports the relocated replacement")
    }
} else if mode == "shelf-renamed-file" || mode == "shelf-renamed-restart" {
    let root = marker.deletingLastPathComponent()
    let original = root.appendingPathComponent("Исходный файл.txt")
    let target = root.appendingPathComponent("Папка назначения/Новое имя.txt")
    let afterRestart = root.appendingPathComponent("После перезапуска.txt")
    let store = root.appendingPathComponent("shelf.json")
    func storedShelf() -> [String: Any] {
        guard let data = try? Data(contentsOf: store) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    mouse(.mouseMoved, CGPoint(x: 735, y: 20))
    event(["type": "fixture-shelf"])
    if mode == "shelf-renamed-file" {
        wait("the original file appears on the shelf") { accessible { $0 == original.lastPathComponent } != nil }
        wait("the legacy shelf records the existing file") {
            (storedShelf()["bookmarks"] as? [String: String])?[original.path] != nil
        }
        try FileManager.default.moveItem(at: original, to: target)
    }
    let expected = mode == "shelf-renamed-file" ? target : afterRestart
    func pointsToMovedFile(_ key: String) -> Bool {
        let paths = storedShelf()[key] as? [String]
        return paths?.count == 1
            && paths?.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == expected.resolvingSymlinksInPath().path
    }
    wait("moving a pinned file updates the current shelf", seconds: 6) {
        accessible { $0 == expected.lastPathComponent } != nil
            && pointsToMovedFile("paths") && pointsToMovedFile("pins")
    }
    let shelf = window("Островок")!
    click(CGPoint(x: shelf.minX + 65, y: shelf.minY + 102))
    Thread.sleep(forTimeInterval: 0.12)
    key(49)
    wait("Quick Look opens the file at its new location") { window(expected.lastPathComponent) != nil }
} else if mode == "shelf-file-availability" {
    let filename = "Восстановленный.txt"
    let file = marker.deletingLastPathComponent().appendingPathComponent(filename)
    defer { try? FileManager.default.removeItem(at: file) }
    let ax = AXUIElementCreateApplication(pid)
    func read(_ node: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, attr as CFString, &value) == .success ? value : nil
    }
    func label() -> String? {
        var todo = (read(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        var count = 0
        while let node = todo.popLast(), count < 250 {
            count += 1
            if let name = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
                .compactMap({ read(node, $0) as? String }).first(where: { $0.hasPrefix(filename) }) { return name }
            todo.append(contentsOf: read(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return nil
    }
    mouse(.mouseMoved, CGPoint(x: 735, y: 20))
    event(["type": "fixture-shelf"])
    wait("shelf shows the missing state") { label()?.contains("Файл недоступен") == true }
    let shelf = window("Островок")
    try Data("restored".utf8).write(to: file)
    wait("the same open shelf refreshes after the file appears", seconds: 4) { label() == filename && shelf == window("Островок") }
    try FileManager.default.removeItem(at: file)
    wait("the same open shelf refreshes after deletion", seconds: 4) { label()?.contains("Файл недоступен") == true }
} else if mode == "shelf-keyboard" {
    func key(_ code: CGKeyCode) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
    }
    event(["type": "fixture-shelf"])
    wait("panel appears for shelf test") { window("Островок") != nil }
    let frame = window("Островок")!
    Thread.sleep(forTimeInterval: 0.34)
    click(CGPoint(x: frame.minX + 65, y: frame.minY + 102))
    Thread.sleep(forTimeInterval: 0.12)
    key(124)
    Thread.sleep(forTimeInterval: 0.08)
    capture("shelf-keyboard-focus")
    key(49)
    wait("Right and Space preview the adjacent file") {
        window("Второй с длинным названием для проверки усечения текста.txt") != nil
    }
    key(53)
    wait("Escape returns to the shelf") { window("Островок") == frame }
    Thread.sleep(forTimeInterval: 0.25)
    key(123)
    key(49)
    wait("selection and keyboard focus survive the preview") { window("Первый.txt") != nil }
} else if mode == "task-write-failure" {
    let store = marker.deletingLastPathComponent().appendingPathComponent("tasks.json")
    let title = "Проверка сохранения задачи"
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
    mouse(.mouseMoved, CGPoint(x: 735, y: 20))
    event(["type": "show"])
    press("Задачи")
    wait("the new task field appears") {
        accessible(role: kAXTextFieldRole) { $0 == "Новая задача" } != nil
    }
    Thread.sleep(forTimeInterval: 0.38)
    let editor = accessible(role: kAXTextFieldRole) { $0 == "Новая задача" }!
    var rawPosition: CFTypeRef?
    var position = CGPoint.zero
    precondition(AXUIElementCopyAttributeValue(editor, kAXPositionAttribute as CFString, &rawPosition) == .success)
    precondition(AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position))
    click(CGPoint(x: position.x + 14, y: position.y + 8))
    wait("the new task field has focus") {
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(editor, kAXFocusedAttribute as CFString, &focused) == .success
            && focused as? Bool == true
    }
    typeText(title)
    wait("the task text reaches the input") { accessible(role: kAXTextFieldRole) { $0 == title } != nil }
    press("Добавить")
    wait("a failed write keeps the draft and avoids showing an unsaved task") {
        accessible(role: kAXTextFieldRole) { $0 == title } != nil
            && accessible { $0 == "Не удалось сохранить задачу" } != nil
            && accessible(role: kAXButtonRole) { $0 == title } == nil
    }
    try FileManager.default.removeItem(at: store)
    press("Добавить")
    func savedDone() -> Bool? {
        guard let bytes = try? Data(contentsOf: store),
              let tasks = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
              tasks.count == 1, tasks.first?["title"] as? String == title else { return nil }
        return tasks.first?["done"] as? Bool
    }
    wait("retry saves one task and clears its input") {
        savedDone() == false && accessible(role: kAXTextFieldRole) { $0 == title } == nil
    }
    let backup = store.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: store, to: backup)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
    press(title)
    wait("an unsuccessful toggle keeps the task active") {
        accessible(role: kAXButtonRole) { $0 == title } != nil && accessible { $0 == "Не удалось сохранить задачу" } != nil
    }
    try FileManager.default.removeItem(at: store)
    try FileManager.default.moveItem(at: backup, to: store)
    press(title)
    wait("retry persists the completed task") { savedDone() == true }
} else if mode == "note-write-recovery" {
    let note = marker.deletingLastPathComponent().appendingPathComponent("note.json")
    let manager = FileManager.default
    let warning = "Заметка пока не сохранена"
    let draft = "Заметка при сбое записи"

    func savedNote() -> String? {
        guard let data = try? Data(contentsOf: note) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    try manager.createDirectory(at: note, withIntermediateDirectories: false)
    mouse(.mouseMoved, CGPoint(x: 735, y: 20))
    event(["type": "show"])
    press("Таймеры и заметка")
    wait("the note section is ready") {
        accessible(role: kAXStaticTextRole) { $0 == "Секундомер" } != nil
    }
    Thread.sleep(forTimeInterval: 0.32)
    let panel = window("Островок")!
    click(CGPoint(x: panel.minX + 46, y: panel.minY + 146))
    Thread.sleep(forTimeInterval: 0.12)
    typeText(draft)
    wait("a failed write keeps the draft and shows a warning") {
        accessible { $0 == draft } != nil && accessible { $0 == warning } != nil
    }
    typeText("!")
    wait("the editor accepts a newer revision during the failure") {
        accessible { $0 == draft + "!" } != nil
    }
    Thread.sleep(forTimeInterval: 0.5)
    try manager.removeItem(at: note)
    wait("the automatic retry saves the newest revision and clears the warning", seconds: 7) {
        savedNote() == draft + "!" && accessible { $0 == warning } == nil
    }

    let backup = note.appendingPathExtension("backup")
    try manager.moveItem(at: note, to: backup)
    try manager.createDirectory(at: note, withIntermediateDirectories: false)
    typeText("?")
    wait("another failed write keeps the new revision") {
        accessible { $0 == draft + "!?" } != nil && accessible { $0 == warning } != nil
    }
    precondition(kill(pid, SIGTERM) == 0)
    press("Продолжить работу")
    wait("canceling quit preserves the process and its draft") {
        accessible { $0 == draft + "!?" } != nil
            && accessible(role: kAXButtonRole) { $0 == "Продолжить работу" } == nil
    }
    try manager.removeItem(at: note)
    try manager.moveItem(at: backup, to: note)
    wait("saving resumes after quit was canceled", seconds: 7) { savedNote() == draft + "!?" }
} else if mode == "panel-space-change" {
    let note = marker.deletingLastPathComponent().appendingPathComponent("note.json")
    let outside = CGPoint(x: 1100, y: 560)
    let text = "Заметка при смене рабочего стола"
    func currentNote() -> String? {
        guard let data = try? Data(contentsOf: note) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
    func switchSpace() {
        event(["type": "fixture-pointer-context", "action": "space"])
    }
    func openPanel() {
        event(["type": "show"])
        wait("the panel opens") { window("Островок") != nil }
    }

    mouse(.mouseMoved, outside)
    openPanel()
    press("Таймеры и заметка")
    wait("the note section is ready") { accessible(role: kAXStaticTextRole) { $0 == "Секундомер" } != nil }
    Thread.sleep(forTimeInterval: 0.32)
    let panel = window("Островок")!
    click(CGPoint(x: panel.minX + 46, y: panel.minY + 146))
    Thread.sleep(forTimeInterval: 0.12)
    typeText(text)
    mouse(.mouseMoved, outside)
    wait("the note is saved while the editor remains open") {
        currentNote() == text && window("Островок") == panel
    }
    typeText("!")
    wait("the final edit reaches the live editor") { accessible { $0 == text + "!" } != nil }
    switchSpace()
    wait("an unpinned panel left behind on another Space closes") { window("Островок") == nil }
    wait("closing on a Space change preserves the final edit") { currentNote() == text + "!" }

    openPanel()
    wait("the reopened panel shows the saved note") { accessible { $0 == text + "!" } != nil }
    press("Закрепить панель")
    wait("the panel is pinned") { accessible { $0 == "Открепить панель" } != nil }
    mouse(.mouseMoved, outside)
    switchSpace()
    Thread.sleep(forTimeInterval: 0.35)
    precondition(window("Островок") == panel && accessible { $0 == "Открепить панель" } != nil)
    print("PASS the pinned panel stays open on a Space change")
} else if mode == "shortcut" {
    let initiallyVisible = window("Островок") != nil
    func pressShortcut() {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 38, keyDown: down)
            event?.flags = down ? [.maskControl, .maskAlternate] : []
            event?.post(tap: .cghidEventTap)
        }
    }
    pressShortcut()
    wait("global shortcut toggles the panel") { (window("Островок") != nil) != initiallyVisible }
    Thread.sleep(forTimeInterval: 0.28)
    pressShortcut()
    wait("same shortcut restores the prior visibility") { (window("Островок") != nil) == initiallyVisible }
} else if mode == "fullscreen" {
    wait("the mascot stays visible while the fullscreen panel is closed") {
        window("Чубзик") != nil && window("Островок") == nil
    }
    mouse(.mouseMoved, CGPoint(x: 735, y: 7))
    wait("fullscreen hover reveals compact player") { matchesSize(window("Островок")?.width, compactPanelWidth) }
    let preview = window("Островок")!
    Thread.sleep(forTimeInterval: 0.28)
    click(CGPoint(x: preview.midX + 18 * panelScale, y: preview.maxY - 8))
    wait("fullscreen background click expands player") { matchesSize(window("Островок")?.width, fullPanelWidth) }
    mouse(.mouseMoved, CGPoint(x: 450, y: 445))
    wait("fullscreen pointer exit closes only the panel", seconds: 1.55) {
        window("Островок") == nil && window("Чубзик") != nil
    }
} else if mode == "reduced" {
    wait("mascot visible with reduced motion") { window("Чубзик") != nil }
    let home = window("Чубзик")!
    mouse(.mouseMoved, CGPoint(x: 655, y: 420))
    event(["type": "ask"])
    Thread.sleep(forTimeInterval: 0.80)
    precondition(window("Чубзик") == home, "Reduced Motion allowed cursor pursuit")
    event(["type": "clear"])
    let origin = CGPoint(x: home.midX, y: home.midY)
    let destination = CGPoint(x: origin.x + 170, y: origin.y + 145)
    mouse(.mouseMoved, origin)
    mouse(.leftMouseDown, origin)
    Thread.sleep(forTimeInterval: 0.08)
    mouse(.leftMouseDragged, destination)
    wait("direct drag works with reduced motion") {
        abs((window("Чубзик")?.midX ?? 0) - destination.x) < 5
    }
    mouse(.leftMouseUp, destination)
    Thread.sleep(forTimeInterval: 1.83)
    precondition(abs((window("Чубзик")?.midX ?? 0) - destination.x) < 5)
    wait("reduced motion returns home after the pause", seconds: 0.40) { window("Чубзик") == home }
    mouse(.mouseMoved, CGPoint(x: 735, y: 8))
    wait("reduced motion opens compact preview") { matchesSize(window("Островок")?.width, compactPanelWidth) }
    let preview = window("Островок")!
    click(CGPoint(x: preview.midX - 3 * 23 * panelScale, y: preview.minY + 26 * panelScale))
    wait("selecting the active music icon expands the preview") { matchesSize(window("Островок")?.width, fullPanelWidth) }
} else {
    mouse(.mouseMoved, CGPoint(x: 460, y: 310))
    Thread.sleep(forTimeInterval: 0.16)
    wait("native mascot visible") { window("Чубзик") != nil }
    let home = window("Чубзик")!
    let pad = CGPoint(x: home.midX, y: home.midY)
    let trap = CGPoint(x: pad.x + 170, y: pad.y + 143)
    precondition(home.minX > 735 && home.minY < 10)

    mouse(.mouseMoved, CGPoint(x: 735, y: 8))
    wait("hover shows compact player") { matchesSize(window("Островок")?.width, compactPanelWidth) && matchesSize(window("Островок")?.height, 100) }
    let preview = window("Островок")!
    capture("hover-player")
    Thread.sleep(forTimeInterval: 0.25)
    click(CGPoint(x: preview.maxX - 57 * panelScale, y: preview.minY + 61 * panelScale))
    Thread.sleep(forTimeInterval: 0.18)
    precondition(window("Островок") == preview, "Transport click changed the panel presentation")
    capture("hover-player-paused")
    click(CGPoint(x: preview.midX + 18 * panelScale, y: preview.maxY - 8))
    wait("background click expands only music") { matchesSize(window("Островок")?.width, fullPanelWidth) && (window("Островок")?.height ?? 0) > 165 * panelScale }
    let expanded = window("Островок")!
    precondition(expanded.minY == preview.minY && abs(expanded.midX - preview.midX) <= 0.5, "The panel moved away from the notch")
    capture("full-player")
    click(CGPoint(x: expanded.midX + 87, y: expanded.minY + 181))
    Thread.sleep(forTimeInterval: 0.12)
    capture("full-player-skipped")
    let outside = CGPoint(x: 1300, y: 540)
    let nearEdge = CGPoint(x: expanded.maxX + 4, y: expanded.midY)
    let inside = CGPoint(x: expanded.midX, y: expanded.midY)
    mouse(.mouseMoved, nearEdge)
    Thread.sleep(forTimeInterval: 0.65)
    precondition(window("Островок") == expanded, "The panel closed before the end of the grace period")
    mouse(.mouseMoved, inside)
    Thread.sleep(forTimeInterval: 0.50)
    precondition(window("Островок") == expanded, "Returning did not cancel the pending close")
    print("PASS pointer return cancels the pending close")
    mouse(.mouseMoved, outside)
    Thread.sleep(forTimeInterval: 0.105)
    mouse(.mouseMoved, inside)
    Thread.sleep(forTimeInterval: 0.32)
    precondition(window("Островок") == expanded, "Returning during the close should restore the current panel")
    print("PASS pointer return reverses the closing transition")
    mouse(.mouseMoved, nearEdge)
    Thread.sleep(forTimeInterval: 0.34)
    mouse(.mouseMoved, outside)
    wait("moving far away shortens the current timeout", seconds: 0.45) { window("Островок") == nil }

    mouse(.mouseMoved, CGPoint(x: 735, y: 8))
    wait("next hover returns to compact music") { window("Островок") == preview }
    mouse(.mouseMoved, CGPoint(x: preview.midX, y: preview.midY))
    scroll(x: -10, y: -25)
    precondition(window("Островок") == preview, "Vertical scrolling changed the section")
    scroll(x: -5, y: 0)
    Thread.sleep(forTimeInterval: 0.24)
    precondition(window("Островок") == preview, "A short swipe committed to a new page")
    scroll(x: -36, y: 1) {
        precondition(window("Островок") == preview, "The page committed before the fingers lifted")
    }
    wait("horizontal gesture opens shelf at the shared size") { window("Островок") == expanded }
    scroll(x: 36, y: 1)
    wait("returning to music keeps the shared full size") { window("Островок") == expanded }
    Thread.sleep(forTimeInterval: 0.62)
    capture("full-player-swiped")

    func select(_ index: Int) {
        click(CGPoint(x: expanded.midX + CGFloat(index - 3) * 23 * panelScale,
                      y: expanded.minY + 26 * panelScale))
        Thread.sleep(forTimeInterval: 0.33)
        precondition(window("Островок") == expanded, "Changing section changed the shared window size")
    }

    select(2)
    capture("tools")
    if let dataDirectory = ProcessInfo.processInfo.environment["CHUBZIK_DATA_DIR"] {
        let note = URL(fileURLWithPath: dataDirectory).appendingPathComponent("note.json")
        click(CGPoint(x: expanded.minX + 46, y: expanded.minY + 146))
        typeText("Прове")
        mouse(.mouseMoved, outside)
        Thread.sleep(forTimeInterval: 0.48)
        precondition(window("Островок") == expanded, "Pointer exit interrupted text editing")
        typeText("рка")
        wait("note stays focused while the pointer leaves") {
            guard let data = try? Data(contentsOf: note) else { return false }
            return (try? JSONDecoder().decode(String.self, from: data)) == "Проверка"
        }
        click(outside)
        wait("outside click closes a focused note") { window("Островок") == nil }
        event(["type": "show"])
        wait("quick reopen restores the last section") { window("Островок") == expanded }
        select(3)
        capture("tasks-empty")
        let tasks = URL(fileURLWithPath: dataDirectory).appendingPathComponent("tasks.json")
        click(CGPoint(x: expanded.minX + 80, y: expanded.minY + 69))
        typeText("Тестовая задача")
        CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        wait("adding a task leaves the panel at the same height") {
            guard let text = try? String(contentsOf: tasks, encoding: .utf8) else { return false }
            return text.contains("Тестовая задача") && window("Островок") == expanded
        }
        capture("tasks-filled")
    }
    select(4)
    capture("calendar")
    click(CGPoint(x: expanded.minX + 206, y: expanded.minY + 70))
    Thread.sleep(forTimeInterval: 0.14)
    precondition(window("Островок") == expanded)
    capture("calendar-next-month")
    select(5)
    capture("weather")
    mouse(.mouseMoved, outside)
    wait("weather hides after leaving", seconds: 1.55) { window("Островок") == nil }
    mouse(.mouseMoved, pad)
    mouse(.leftMouseDown, pad)
    Thread.sleep(forTimeInterval: 0.14)
    for step in 1...10 {
        let u = Double(step) / 10
        mouse(.leftMouseDragged, CGPoint(x: pad.x + (trap.x - pad.x) * u, y: pad.y + (trap.y - pad.y) * u))
        Thread.sleep(forTimeInterval: 0.025)
    }
    wait("drag moves the real window") { abs((window("Чубзик")?.midX ?? 0) - trap.x) < 5 }
    mouse(.leftMouseUp, trap)
    Thread.sleep(forTimeInterval: 0.40)
    wait("mascot stays after release") { abs((window("Чубзик")?.midX ?? 0) - trap.x) < 5 }
    wait("mascot returns to the same home", seconds: 3) { window("Чубзик") == home }

    let distant = CGPoint(x: pad.x + 320, y: pad.y + 270)
    mouse(.mouseMoved, pad)
    mouse(.leftMouseDown, pad)
    Thread.sleep(forTimeInterval: 0.09)
    mouse(.leftMouseDragged, distant)
    wait("mascot reaches the longer drag destination") {
        abs((window("Чубзик")?.midX ?? 0) - distant.x) < 5
    }
    mouse(.leftMouseUp, distant)
    Thread.sleep(forTimeInterval: 1.92)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.45
    var caught: CGPoint?
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let character = window("Чубзик"), character.midX < distant.x - 12, character.midX > home.midX + 100 {
            caught = CGPoint(x: character.midX, y: character.midY)
            break
        }
        Thread.sleep(forTimeInterval: 0.008)
    }
    guard let caught else { fatalError("No intermediate position on the return path") }
    mouse(.mouseMoved, caught)
    // Read the moving window again immediately before the press.
    let atPress = window("Чубзик").map { CGPoint(x: $0.midX, y: $0.midY) } ?? caught
    mouse(.leftMouseDown, atPress)
    Thread.sleep(forTimeInterval: 0.19)
    precondition(abs((window("Чубзик")?.midX ?? 0) - atPress.x) < 20,
                 "Re-grabbing the mascot did not stop its flight")
    mouse(.leftMouseUp, atPress)
    wait("re-grabbed mascot still returns after release", seconds: 3) { window("Чубзик") == home }

    let chase = CGPoint(x: 670, y: 415)
    mouse(.mouseMoved, chase)
    event(["type": "ask"])
    wait("attention follows cursor") {
        guard let character = window("Чубзик") else { return false }
        return hypot(character.midX - chase.x, character.midY - chase.y) < 75
    }
    let next = CGPoint(x: 450, y: 505)
    mouse(.mouseMoved, next)
    wait("attention follows next meaningful movement") {
        guard let character = window("Чубзик") else { return false }
        return hypot(character.midX - next.x, character.midY - next.y) < 75
    }
    event(["type": "clear"])
    wait("clearing attention returns mascot right of notch") { window("Чубзик") == home }

    try! Data("fixture".utf8).write(to: marker)
    event(["type": "download", "source": "com.kiridey.ardia.personal", "path": marker.path])
    event(["type": "show"])
    wait("panel opens after download") { window("Островок") == expanded }
    capture("download-keeps-current-section")
    select(1)
    capture("shelf")
    let shelf = window("Островок")!
    mouse(.mouseMoved, CGPoint(x: shelf.midX, y: shelf.midY))
    Thread.sleep(forTimeInterval: 0.04)
    mouse(.mouseMoved, CGPoint(x: 400, y: 333))
    wait("pointer exit hides shelf", seconds: 1.55) { window("Островок") == nil }
    mouse(.mouseMoved, CGPoint(x: 735, y: 8))
    wait("hover opens shelf directly") { window("Островок") == shelf }
}
