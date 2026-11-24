import AppKit
import ApplicationServices
import QuartzCore
import QuickLookThumbnailing

final class FileHandoff {
    let window: OverlayPanel
    private let card: FileHandoffCard
    private var files: [URL]
    private let cargo: OverlayPanel
    private var index = 0
    private var motion: Timer?
    private var arrows: FileCardArrows?
    private weak var animatedMascot: MascotView?
    private var flightEnded: (() -> Void)?
    var selectionChanged: (() -> Void)?
    var becameEmpty: (() -> Void)?
    var finished: (() -> Void)?
    var onPick: ((URL) -> Void)?
    var isDragging: Bool { card.isDragging }
    var isFlying: Bool { motion != nil }

    init(files: [URL], cursor: CGPoint, display: CGRect, emptyMessage: String, inPicker: Bool = false) {
        self.files = files
        let width: CGFloat
        if files.isEmpty { width = max(209, FileHandoffCard.messageWidth(emptyMessage)) }
        else { width = (files.count > 1 ? 262 : 209) + (inPicker ? 32 : 0) }
        let height: CGFloat = 46
        let safe = display.insetBy(dx: 9, dy: 9)
        let preferredY = cursor.y - height - 14
        let frame = CGRect(x: min(max(safe.minX, cursor.x - 9), safe.maxX - width),
                           y: min(max(safe.minY, preferredY < safe.minY ? cursor.y + 14 : preferredY),
                                  safe.maxY - height), width: width, height: height)
        window = OverlayPanel(frame: frame)
        window.title = "Файл у указателя"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
        card = FileHandoffCard(frame: CGRect(origin: .zero, size: frame.size), choices: files.count > 1, inPicker: inPicker)
        window.contentView = card
        cargo = OverlayPanel(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
        cargo.title = "Чубзик несёт файл"
        cargo.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 6)
        cargo.ignoresMouseEvents = true
        card.onSelect = { [weak self] direction in self?.step(direction) }
        card.onDrop = { [weak self] in self?.finished?() }
        card.onPick = { [weak self] in
            guard let self, self.files.indices.contains(self.index) else { return }
            self.onPick?(self.files[self.index])
        }
        card.onMissingFile = { [weak self] in self?.refreshSelection(offset: 0, direction: 1) }
        card.onDragState = { [weak self] in
            self?.updateArrowKeys()
            self?.selectionChanged?()
        }
        if files.isEmpty { card.showMessage(emptyMessage) }
        else { updateSelection() }
    }

    func show() {
        if !files.isEmpty { refreshSelection(offset: 0, direction: 1) }
        window.orderFrontRegardless()
        updateArrowKeys()
        selectionChanged?()
    }

    private func updateArrowKeys() {
        guard files.count > 1, !isDragging else { arrows = nil; return }
        if arrows == nil { arrows = FileCardArrows { [weak self] direction in self?.step(direction) } }
    }

    func step(_ direction: Int) {
        guard window.isVisible, !isDragging, files.count > 1 else { return }
        refreshSelection(offset: 1, direction: direction)
    }

    private func refreshSelection(offset: Int, direction: Int) {
        guard files.indices.contains(index) else { return }
        let previous = files
        let current = previous[index]
        files = previous.filter { CodexResultFiles.localFile(at: $0.path) != nil }
        guard !files.isEmpty else {
            arrows = nil
            card.showMessage("Файл больше недоступен")
            becameEmpty?()
            return
        }
        let available = Set(files)
        var position = (index + direction * offset + previous.count) % previous.count
        while !available.contains(previous[position]) {
            position = (position + direction + previous.count) % previous.count
        }
        let selected = previous[position]
        index = files.firstIndex(of: selected) ?? 0
        if current != selected || files.count != previous.count { updateSelection() }
        updateArrowKeys()
    }

    private func updateSelection() {
        let url = files[index]
        card.setFile(url, icon: NSWorkspace.shared.icon(forFile: url.path), index: index, count: files.count)
    }

    func fly(mascotWindow: OverlayPanel, mascot: MascotView, home: CGPoint, start: CGPoint,
             display: CGRect, onReturn: @escaping () -> Void) {
        animatedMascot = mascot
        flightEnded = onReturn
        let iconPoint = CGPoint(x: window.frame.minX + FileHandoffCard.iconCenterX, y: window.frame.midY)
        let side: CGFloat = iconPoint.x - display.minX > 55 ? 1 : -1
        let held = SlimePaw(side: side, amount: 0.92, turn: -side * 0.58)
        let gripOffset = CGPoint(x: side * 10, y: 0)
        let approachEnd = iconPoint - held.tip - gripOffset + CGPoint(x: -side * 4, y: 6)
        let placeEnd = iconPoint - held.tip - gripOffset
        let retreat = placeEnd + CGPoint(x: -side * 10, y: 5)
        let approach = travelTime(start, approachEnd, minimum: 0.40)
        let returning = travelTime(retreat, start, minimum: 0.41)
        let preparation = 0.14
        let arriving = preparation + approach
        let releasing = arriving + 0.20
        let goingHome = releasing + 0.13
        let begin = ProcessInfo.processInfo.systemUptime
        let icon = NSImageView(frame: CGRect(origin: .zero, size: cargo.frame.size))
        icon.image = card.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        cargo.contentView = icon
        cargo.alphaValue = 0
        cargo.orderFrontRegardless()
        var putDown = false

        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let time = ProcessInfo.processInfo.systemUptime - begin
            var center: CGPoint
            var look: CGPoint
            var paw: SlimePaw?
            if time < preparation {
                let ready = self.ease(time / preparation)
                center = start + CGPoint(x: -side * 4 * ready, y: -3 * ready)
                look = approachEnd
                paw = SlimePaw(side: side, amount: held.amount * ready, turn: held.turn)
                self.cargo.alphaValue = ready
            } else if time < arriving {
                let u = self.ease((time - preparation) / approach)
                let from = start + CGPoint(x: -side * 4, y: -3)
                center = self.arc(from, approachEnd, at: u, bend: 1)
                look = self.arc(from, approachEnd, at: min(1, u + 0.12), bend: 1)
                paw = SlimePaw(side: side, amount: held.amount, turn: held.turn + side * sin(.pi * u) * 0.28)
                self.cargo.alphaValue = 1
            } else if time < releasing {
                let u = self.ease((time - arriving) / (releasing - arriving))
                center = approachEnd + (placeEnd - approachEnd) * u
                look = iconPoint
                paw = held
            } else {
                if !putDown {
                    putDown = true
                    self.cargo.orderOut(nil)
                    self.card.reveal()
                    self.show()
                }
                if time < goingHome {
                    let u = self.ease((time - releasing) / (goingHome - releasing))
                    center = placeEnd + (retreat - placeEnd) * u
                    look = iconPoint
                    paw = SlimePaw(side: side, amount: held.amount * (1 - u), turn: held.turn)
                } else if time < goingHome + returning {
                    let u = self.ease((time - goingHome) / returning)
                    center = self.arc(retreat, start, at: u, bend: 0.8)
                    look = self.arc(retreat, start, at: min(1, u + 0.15), bend: 0.8)
                    paw = nil
                } else {
                    self.move(mascotWindow, to: home)
                    self.stopFlight()
                    return
                }
            }
            self.move(mascotWindow, to: center)
            mascot.extendPaw(paw)
            mascot.look(CGPoint(x: min(3, max(-3, (look.x - center.x) / 8)),
                                y: min(2.5, max(-2.5, (look.y - center.y) / 8))))
            if !putDown, let paw {
                self.move(self.cargo, to: center + paw.tip + gripOffset)
            }
        }
        timer.tolerance = 0.002
        motion = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func move(_ window: NSWindow, to center: CGPoint) {
        window.setFrameOrigin(CGPoint(x: center.x - window.frame.width / 2, y: center.y - window.frame.height / 2))
    }

    private func arc(_ from: CGPoint, _ to: CGPoint, at t: CGFloat, bend: CGFloat) -> CGPoint {
        let delta = to - from
        let distance = max(1, hypot(delta.x, delta.y))
        let curve = sin(.pi * t) * min(62, distance * 0.21) * bend
        return from + delta * t + CGPoint(x: -delta.y / distance * curve, y: delta.x / distance * curve)
    }

    private func ease(_ fraction: Double) -> CGFloat {
        let t = min(1, max(0, fraction))
        return t * t * (3 - 2 * t)
    }

    private func travelTime(_ from: CGPoint, _ to: CGPoint, minimum: TimeInterval) -> TimeInterval {
        min(0.88, max(minimum, 0.24 + hypot(from.x - to.x, from.y - to.y) / 1250))
    }

    private func stopFlight() {
        motion?.invalidate()
        motion = nil
        cargo.orderOut(nil)
        animatedMascot?.extendPaw(nil)
        animatedMascot = nil
        let onReturn = flightEnded
        flightEnded = nil
        onReturn?()
    }

    func dismiss() {
        arrows = nil
        stopFlight()
        window.orderOut(nil)
    }
}

private final class FileCardArrows {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let change: (Int) -> Void

    init?(_ change: @escaping (Int) -> Void) {
        self.change = change
        guard AXIsProcessTrusted(), let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, context in
                let passthrough = Unmanaged.passUnretained(event)
                guard let context else { return passthrough }
                let keys = Unmanaged<FileCardArrows>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = keys.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return passthrough
                }
                guard type == .keyDown,
                      event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
                    return passthrough
                }
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                guard key == 123 || key == 124 else { return passthrough }
                DispatchQueue.main.async { [weak keys] in keys?.change(key == 123 ? -1 : 1) }
                return nil
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return nil }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

private final class FileHandoffCard: NSView, NSDraggingSource {
    static let iconCenterX: CGFloat = 23
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static func messageWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: titleFont]).width) + 26
    }
    private let background = NSView()
    private let matte = NSVisualEffectView()
    private let thumbnail = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private var selectionButtons: [NSButton] = []
    private var pickerButton: NSButton?
    private var file: URL?
    private var press: NSEvent?
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private(set) var isDragging = false
    var onSelect: ((Int) -> Void)?
    var onDrop: (() -> Void)?
    var onPick: (() -> Void)?
    var onMissingFile: (() -> Void)?
    var onDragState: (() -> Void)?
    var icon: NSImage? { thumbnail.image }

    init(frame: CGRect, choices: Bool, inPicker: Bool) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        background.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderColor = NSColor(white: 0.90, alpha: 0.21).cgColor
        background.layer?.borderWidth = 1
        addSubview(background)
        matte.frame = background.bounds
        matte.material = .hudWindow
        matte.blendingMode = .behindWindow
        matte.state = .active
        background.addSubview(matte)
        let tint = NSView(frame: background.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.079, green: 0.083, blue: 0.095, alpha: 0.86).cgColor
        background.addSubview(tint)

        thumbnail.frame = CGRect(x: Self.iconCenterX - 13, y: frame.midY - 13, width: 26, height: 26)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        addSubview(thumbnail)

        label.frame = CGRect(x: 44, y: 15, width: frame.width - (choices ? 128 : 54), height: 17)
        label.font = Self.titleFont
        label.textColor = NSColor(white: 0.94, alpha: 1)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)

        let right = frame.width - (inPicker ? 32 : 0)
        if inPicker {
            let title = "Подставить в диалог"
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: title)!,
                                  target: self, action: #selector(pick))
            button.frame = CGRect(x: frame.width - 31, y: 11, width: 24, height: 24)
            button.isBordered = false
            button.toolTip = title
            button.setAccessibilityLabel(title)
            addSubview(button)
            pickerButton = button
        }
        if choices {
            for (symbol, tooltip, x, action) in [
                ("chevron.left", "Предыдущий файл", right - 78, #selector(previous)),
                ("chevron.right", "Следующий файл", right - 27, #selector(next))
            ] {
                let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!,
                                      target: self, action: action)
                button.frame = CGRect(x: x, y: 11, width: 24, height: 24)
                button.isBordered = false
                button.toolTip = tooltip
                addSubview(button)
                selectionButtons.append(button)
            }
            counter.frame = CGRect(x: right - 57, y: 17, width: 33, height: 13)
            counter.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            counter.textColor = .secondaryLabelColor
            counter.alignment = .center
            addSubview(counter)
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
    }

    @objc private func previous() { onSelect?(-1) }
    @objc private func next() { onSelect?(1) }
    @objc private func pick() { onPick?() }

    func showMessage(_ text: String) {
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
        thumbnailRequest = nil
        file = nil
        thumbnail.image = nil
        updateSelectionControls(count: 0)
        pickerButton?.isHidden = true
        label.frame.origin.x = 12
        label.frame.size.width = bounds.width - 24
        label.stringValue = text
        label.toolTip = nil
    }

    func setFile(_ url: URL, icon: NSImage, index: Int, count: Int) {
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
        file = url
        thumbnail.image = icon
        updateSelectionControls(count: count)
        pickerButton?.isHidden = false
        label.frame.origin.x = 44
        label.frame.size.width = bounds.width - (count > 1 ? 128 : 54) - (pickerButton == nil ? 0 : 32)
        label.stringValue = url.lastPathComponent
        label.toolTip = url.lastPathComponent
        counter.stringValue = "\(index + 1)/\(count)"
        let request = QLThumbnailGenerator.Request(fileAt: url, size: thumbnail.bounds.size, scale: 2,
                                                    representationTypes: .thumbnail)
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak request] result, _ in
            DispatchQueue.main.async {
                guard let self, let request, self.thumbnailRequest === request, let result else { return }
                self.thumbnail.image = result.nsImage
            }
        }
    }

    private func updateSelectionControls(count: Int) {
        for button in selectionButtons { button.isHidden = count < 2 }
        counter.isHidden = count < 2
    }

    func reveal() {
        let reveal = CAShapeLayer()
        reveal.frame = background.bounds
        reveal.fillColor = NSColor.black.cgColor
        let start = CGPath(roundedRect: CGRect(x: 10, y: 10, width: 26, height: 26),
                           cornerWidth: 6, cornerHeight: 6, transform: nil)
        let end = CGPath(roundedRect: background.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        reveal.path = end
        background.layer?.mask = reveal
        let size = CABasicAnimation(keyPath: "path")
        size.fromValue = start
        size.toValue = end
        size.duration = 0.19
        size.timingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1, 0.22, 1)
        reveal.add(size, forKey: "open")
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.19
        for view in subviews where view !== thumbnail && view !== background {
            view.wantsLayer = true
            view.layer?.add(appear, forKey: "open")
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton || hit == nil ? hit : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { press = event }
    override func mouseUp(with event: NSEvent) {
        let shouldPick = press != nil && pickerButton?.isHidden == false
        press = nil
        if shouldPick, bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let press, let file else { return }
        let start = convert(press.locationInWindow, from: nil)
        guard hypot(start.x - point.x, start.y - point.y) >= 4 else { return }
        self.press = nil
        guard let url = CodexResultFiles.localFile(at: file.path) else {
            onMissingFile?()
            return
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = icon ?? NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(CGRect(x: start.x - 16, y: start.y - 16, width: 32, height: 32), contents: image)
        isDragging = true
        onDragState?()
        beginDraggingSession(with: [item], event: press, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        if operation == [] { onDragState?() }
        else { onDrop?() }
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
private func * (point: CGPoint, scale: CGFloat) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }
