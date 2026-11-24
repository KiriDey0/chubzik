import AppKit
import QuartzCore

private let ivory = NSColor(srgbRed: 1, green: 0.95, blue: 0.86, alpha: 1)

class FileDropView: NSView {
    private static let finderFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    var onDrop: (([URL]) -> Bool)?
    var onDragTarget: (() -> Void)?
    private(set) var showsDropTarget = false {
        didSet { if oldValue != showsDropTarget { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, Self.finderFilenames])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return [] }
        showsDropTarget = true
        onDragTarget?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showsDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showsDropTarget = false
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return onDrop?(urls) == true }
        let paths = pasteboard.propertyList(forType: Self.finderFilenames) as? [String] ?? []
        let files = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        return !files.isEmpty && onDrop?(files) == true
    }
}

final class MascotView: FileDropView {
    enum Mood { case idle, working, awaiting }
    enum Gesture {
        case blink, curious(CGFloat), file, timer, attention, landing
        case chaseCrouch(CGFloat), chaseFeint(CGFloat), chaseJump(CGFloat, duration: TimeInterval), chaseCatch, chaseMiss
    }
    enum ChatExpression { case neutral, focus, capture, thinking, writing, done, stopped, error }

    var onPress: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onRelease: ((CGPoint) -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    var mood: Mood = .idle {
        didSet {
            guard oldValue != mood else { return }
            updateEyes()
            withoutActions { indicator.isHidden = mood != .awaiting }
        }
    }
    private let creature = CALayer()
    private let body = CAShapeLayer()
    private let shade = CAGradientLayer()
    private let shadeMask = CAShapeLayer()
    private let face = CALayer()
    private let cheeks = CAShapeLayer()
    private let indicator = CALayer()
    private let badge = CAShapeLayer()
    private var activePaw: SlimePaw?
    private var badgeClear: DispatchWorkItem?
    private var eyes: [CAShapeLayer] = []
    private var pressed = false
    private var gaze = CGPoint.zero
    private var chatExpression: ChatExpression = .neutral
    private var endSmile: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }

        let bodyBounds = CGRect(x: 0, y: 0, width: 28, height: 26)
        creature.name = "creature"
        creature.bounds = bodyBounds
        creature.anchorPoint = CGPoint(x: 0.5, y: 0.23)
        creature.position = CGPoint(x: frame.width / 2, y: 3 + bodyBounds.height * 0.23)
        layer.addSublayer(creature)

        let contour = SlimePaw(side: 1, amount: 0).outline(in: bodyBounds)
        shade.frame = bodyBounds.insetBy(dx: -4, dy: -4)
        shade.colors = [NSColor(srgbRed: 0.31, green: 0.32, blue: 0.35, alpha: 1).cgColor,
                        NSColor(srgbRed: 0.16, green: 0.165, blue: 0.19, alpha: 1).cgColor,
                        NSColor(srgbRed: 0.087, green: 0.09, blue: 0.11, alpha: 1).cgColor]
        shade.locations = [0, 0.53, 1]
        shade.startPoint = CGPoint(x: 0.28, y: 1)
        shade.endPoint = CGPoint(x: 0.68, y: 0)
        shadeMask.frame = bodyBounds.offsetBy(dx: 4, dy: 4)
        shadeMask.path = contour
        shade.mask = shadeMask
        creature.addSublayer(shade)

        body.frame = bodyBounds
        body.path = contour
        body.fillColor = NSColor.clear.cgColor
        body.strokeColor = NSColor(white: 0.80, alpha: 0.46).cgColor
        body.lineWidth = 0.65
        creature.addSublayer(body)

        face.frame = bodyBounds
        face.name = "face"
        creature.addSublayer(face)
        for x in [10.05, 17.95] {
            let eye = CAShapeLayer()
            eye.name = "eye"
            eye.bounds = CGRect(x: 0, y: 0, width: 3.8, height: 9.5)
            eye.position = CGPoint(x: x, y: 13.2)
            eye.path = CGPath(roundedRect: eye.bounds, cornerWidth: 1.9, cornerHeight: 1.9, transform: nil)
            eye.fillColor = ivory.cgColor
            face.addSublayer(eye)
            eyes.append(eye)
        }

        let marks = CGMutablePath()
        for start in [3.6, 20.0] {
            for stroke in 0..<3 {
                let x = start + Double(stroke) * 1.55
                marks.move(to: CGPoint(x: x, y: 7.3))
                marks.addLine(to: CGPoint(x: x + 1.1, y: 10.2))
            }
        }
        cheeks.frame = bodyBounds
        cheeks.name = "cheeks"
        cheeks.path = marks
        cheeks.lineCap = .round
        cheeks.lineWidth = 0.9
        cheeks.strokeColor = NSColor(srgbRed: 1, green: 0.48, blue: 0.55, alpha: 1).cgColor
        cheeks.opacity = 0
        creature.addSublayer(cheeks)

        indicator.frame = CGRect(x: 26, y: 24, width: 5, height: 5)
        indicator.name = "attention"
        indicator.cornerRadius = 2.5
        indicator.borderWidth = 0.6
        indicator.borderColor = NSColor(white: 0.15, alpha: 1).cgColor
        indicator.backgroundColor = NSColor(srgbRed: 1, green: 0.68, blue: 0.40, alpha: 1).cgColor
        indicator.isHidden = true
        layer.addSublayer(indicator)

        badge.frame = CGRect(x: 0.5, y: 21, width: 10, height: 10)
        badge.name = "reaction-badge"
        badge.lineWidth = 0.95
        badge.lineJoin = .round
        badge.lineCap = .round
        badge.fillColor = NSColor(srgbRed: 0.16, green: 0.14, blue: 0.18, alpha: 1).cgColor
        badge.opacity = 0
        layer.addSublayer(badge)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Чубзик")
    }

    required init?(coder: NSCoder) { nil }

    var reducedMotion = false {
        didSet {
            guard reducedMotion, !oldValue else { return }
            badgeClear?.cancel()
            for node in [creature, face, cheeks, badge, indicator, body, shadeMask] + eyes { node.removeAllAnimations() }
            gaze = .zero
            withoutActions {
                creature.setAffineTransform(.identity)
                face.setAffineTransform(.identity)
                badge.opacity = 0
            }
            updateEyes()
        }
    }

    private func withoutActions(_ update: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update()
        CATransaction.commit()
    }

    private var eyeScale: CGFloat {
        if pressed { return 0.88 }
        switch chatExpression {
        case .focus, .writing: return 1.12
        case .capture: return 1.2
        case .thinking: return 0.69
        case .stopped: return 0.88
        case .done, .error, .neutral: break
        }
        switch mood {
        case .idle: return 1
        case .working: return 0.69
        case .awaiting: return 1.12
        }
    }

    private func updateEyes() {
        withoutActions {
            for (index, eye) in eyes.enumerated() {
                let scale = chatExpression == .error && index == 0 ? 0.56 : eyeScale
                eye.setAffineTransform(CGAffineTransform(scaleX: 1, y: scale))
            }
        }
    }

    func look(_ value: CGPoint) {
        guard !pressed, !reducedMotion else { return }
        let isGlancing = face.animation(forKey: "curiosity") != nil
        guard isGlancing || hypot(value.x - gaze.x, value.y - gaze.y) >= 0.035 else { return }
        moveGaze(to: value)
    }

    private func moveGaze(to value: CGPoint) {
        let visible = face.presentation()?.transform ?? face.transform
        face.removeAnimation(forKey: "curiosity")
        gaze = value
        let target = CATransform3DMakeTranslation(value.x, value.y, 0)
        withoutActions { face.transform = target }
        guard !reducedMotion, !CATransform3DEqualToTransform(visible, target) else {
            face.removeAnimation(forKey: "gaze")
            return
        }
        let transition = CABasicAnimation(keyPath: "transform")
        transition.fromValue = NSValue(caTransform3D: visible)
        transition.toValue = NSValue(caTransform3D: target)
        transition.duration = 0.11
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        face.add(transition, forKey: "gaze")
    }

    func setChatExpression(_ expression: ChatExpression) {
        endSmile?.cancel()
        restoreEyeShape()
        chatExpression = expression
        updateEyes()
        let target: CGPoint
        switch expression {
        case .neutral: target = .zero
        case .focus: target = CGPoint(x: 2.2, y: -1.3)
        case .capture: target = CGPoint(x: -2.8, y: -1.6)
        case .thinking: target = CGPoint(x: 1.7, y: 0.4)
        case .writing: target = CGPoint(x: 2, y: 1.6)
        case .done: target = CGPoint(x: 1.5, y: 0.8)
        case .stopped, .error: target = CGPoint(x: -0.8, y: -0.4)
        }
        moveGaze(to: target)
        if expression == .capture {
            animateEyes([1.22, 0.12, 0.12, 0.97], times: [0, 0.46, 0.69, 1], duration: 0.15)
        } else if expression == .done {
            withoutActions {
                for eye in eyes {
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: 0.05, y: 4.3))
                    path.addQuadCurve(to: CGPoint(x: 3.75, y: 4.3), control: CGPoint(x: 1.9, y: 7.55))
                    eye.path = path
                    eye.strokeColor = ivory.cgColor
                    eye.fillColor = NSColor.clear.cgColor
                    eye.lineWidth = 1.25
                    eye.lineCap = .round
                }
            }
            let clear = DispatchWorkItem { [weak self] in self?.restoreEyeShape() }
            endSmile = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: clear)
        }
    }

    private func restoreEyeShape() {
        withoutActions {
            for eye in eyes {
                eye.path = CGPath(roundedRect: eye.bounds, cornerWidth: 1.9, cornerHeight: 1.9, transform: nil)
                eye.strokeColor = nil
                eye.fillColor = ivory.cgColor
            }
        }
    }

    func hold(_ on: Bool) {
        guard pressed != on else { return }
        pressed = on
        updateEyes()
        let old = creature.presentation()?.affineTransform() ?? creature.affineTransform()
        if on {
            creature.removeAnimation(forKey: "reaction")
            let visible = face.presentation()?.affineTransform() ?? face.affineTransform()
            face.removeAnimation(forKey: "curiosity")
            face.removeAnimation(forKey: "gaze")
            gaze = CGPoint(x: visible.tx, y: visible.ty)
            withoutActions { face.setAffineTransform(visible) }
            for eye in eyes { eye.removeAnimation(forKey: "expression") }
            cheeks.removeAnimation(forKey: "blush")
        }
        let squash = CGAffineTransform(scaleX: 1.07, y: 0.86)
        let target = on && !reducedMotion ? squash : .identity
        withoutActions {
            creature.setAffineTransform(target)
            if on { cheeks.opacity = 1 }
        }
        if on {
            keyframes(creature, poses: [old, .init(scaleX: 1.09, y: 0.82), target],
                      times: [0, 0.58, 1], duration: 0.13, key: "touch")
        } else {
            keyframes(creature, poses: [old, .init(scaleX: 0.972, y: 1.06),
                                       .init(scaleX: 1.026, y: 0.97), .identity],
                      times: [0, 0.33, 0.69, 1], duration: 0.27, key: "touch")
        }
    }

    func clearBlush() {
        guard !pressed else { return }
        let old = cheeks.presentation()?.opacity ?? cheeks.opacity
        withoutActions { cheeks.opacity = 0 }
        guard old > 0, !reducedMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = old
        fade.toValue = 0
        fade.duration = 0.13
        cheeks.add(fade, forKey: "blush")
    }

    func extendPaw(_ paw: SlimePaw?, tug: Bool = false) {
        if tug {
            animateEyes([eyeScale, 0.47, 0.69, eyeScale], times: [0, 0.28, 0.68, 1], duration: 0.32)
        }
        guard paw != activePaw else { return }
        if paw != nil, activePaw == nil {
            creature.removeAnimation(forKey: "reaction")
            creature.removeAnimation(forKey: "touch")
            for layer in [body, shadeMask] { layer.removeAnimation(forKey: "paw") }
        }
        activePaw = paw
        let contour = (paw ?? SlimePaw(side: 1, amount: 0)).outline(in: body.bounds)
        withoutActions {
            body.path = contour
            shadeMask.path = contour
        }
    }

    private func gesturePaw(side: CGFloat, amount: CGFloat, duration: TimeInterval) {
        guard activePaw == nil, !reducedMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = [0, amount, amount * 0.82, 0].map { value in
            SlimePaw(side: side, amount: value).outline(in: body.bounds)
        }
        animation.keyTimes = [0, 0.30, 0.55, 1]
        animation.timingFunctions = Array(repeating: .init(name: .easeInEaseOut), count: 3)
        animation.duration = duration
        for layer in [body, shadeMask] { layer.add(animation, forKey: "paw") }
    }

    func react(_ gesture: Gesture) {
        guard !pressed else { return }
        if reducedMotion {
            if case .file = gesture { showBadge(file: true) }
            return
        }
        switch gesture {
        case .blink:
            animateEyes([eyeScale, 0.12, 0.12, eyeScale * 1.035, eyeScale],
                        times: [0, 0.29, 0.38, 0.73, 1], duration: 0.23)
        case let .curious(direction):
            gesturePaw(side: direction < 0 ? -1 : 1, amount: 0.80, duration: 1.26)
            let angle = -direction * 0.115
            bodyMotion([.init(rotationAngle: -angle * 0.22), .init(rotationAngle: angle),
                        .init(rotationAngle: angle * 0.82), .identity],
                       times: [0, 0.12, 0.31, 0.74, 1], duration: 1.26)
            let baseline = CGAffineTransform(translationX: gaze.x, y: gaze.y)
            let glance = CGAffineTransform(translationX: direction * 3.8, y: -1.5)
            let visible = face.presentation()?.affineTransform() ?? baseline
            face.removeAnimation(forKey: "gaze")
            keyframes(face, poses: [visible, glance, glance, baseline, baseline],
                      times: [0, 0.16, 0.65, 0.89, 1], duration: 1.26, key: "curiosity")
            animateEyes([eyeScale, eyeScale * 1.14, eyeScale * 1.12, 0.15, eyeScale],
                        times: [0, 0.19, 0.69, 0.87, 1], duration: 1.26)
        case .file:
            gesturePaw(side: -1, amount: 0.94, duration: 0.62)
            showBadge(file: true)
        case .timer:
            bodyMotion([.init(scaleX: 1.05, y: 0.90), pop(2.8), pop(0.5), pop(1.8), .identity],
                       times: [0, 0.13, 0.29, 0.46, 0.63, 1], duration: 0.66)
            showBadge(file: false)
        case .attention:
            bodyMotion([.init(scaleX: 1.055, y: 0.89), pop(2.6), .init(rotationAngle: 0.07),
                        pop(1.7), .identity], times: [0, 0.13, 0.30, 0.47, 0.67, 1], duration: 0.70)
            animateEyes([eyeScale, eyeScale * 1.12, 0.15, eyeScale], times: [0, 0.29, 0.63, 1], duration: 0.55)
            keyframes(indicator, poses: [.identity, .init(scaleX: 1.32, y: 1.32), .identity],
                      times: [0, 0.40, 1], duration: 0.52, key: "signal")
        case .landing:
            bodyMotion([.init(scaleX: 1.08, y: 0.90), .init(scaleX: 0.99, y: 1.02), .identity],
                       times: [0, 0.27, 0.62, 1], duration: 0.24)
        case .chaseCrouch(let direction):
            let tuck = CGAffineTransform(translationX: -direction * 1.6, y: -1.1)
                .scaledBy(x: 1.10, y: 0.72)
            let lean = CGAffineTransform(translationX: direction * 1.4, y: -0.8)
                .rotated(by: -direction * 0.13).scaledBy(x: 1.08, y: 0.76)
            bodyMotion([tuck, lean, lean], times: [0, 0.33, 0.68, 1], duration: 0.30)
            animateEyes([eyeScale, 0.59, 0.62, 0.75], times: [0, 0.32, 0.74, 1], duration: 0.29)
        case .chaseFeint(let direction):
            let fake = CGAffineTransform(translationX: direction * 4.4, y: 0.8)
                .rotated(by: -direction * 0.18).scaledBy(x: 1.07, y: 0.82)
            let tuck = CGAffineTransform(translationX: -direction * 1.4, y: -0.8)
                .scaledBy(x: 1.10, y: 0.72)
            bodyMotion([fake, tuck, tuck], times: [0, 0.28, 0.70, 1], duration: 0.24)
            animateEyes([0.71, 1.05, 0.65], times: [0, 0.33, 1], duration: 0.24)
        case .chaseJump(let direction, let duration):
            let stretch = CGAffineTransform(rotationAngle: -direction * 0.27).scaledBy(x: 1.16, y: 0.90)
            bodyMotion([stretch, stretch, .identity], times: [0, 0.28, 0.70, 1], duration: duration)
            animateEyes([0.75, 1.14, eyeScale], times: [0, 0.40, 1], duration: duration)
        case .chaseCatch:
            bodyMotion([.init(scaleX: 1.10, y: 0.83), .init(scaleX: 0.97, y: 1.03), .identity],
                       times: [0, 0.25, 0.59, 1], duration: 0.31)
            animateEyes([eyeScale, 0.40, 0.71, eyeScale], times: [0, 0.22, 0.67, 1], duration: 0.36)
        case .chaseMiss:
            bodyMotion([.init(scaleX: 1.14, y: 0.78), .init(rotationAngle: 0.13),
                        .init(rotationAngle: -0.073), .identity],
                       times: [0, 0.18, 0.43, 0.66, 1], duration: 0.42)
            animateEyes([eyeScale, 1.29, 1.18, 0.14, eyeScale],
                        times: [0, 0.22, 0.59, 0.76, 1], duration: 0.48)
        }
    }

    func travel(toward displacement: CGPoint, duration: Double) {
        let angle = -min(1, max(-1, displacement.x / 95)) * 0.14
        let lean = CGAffineTransform(rotationAngle: angle).scaledBy(x: 0.97, y: 1.015)
        bodyMotion([lean, lean, .identity], times: [0, 0.23, 0.67, 1], duration: duration)
    }

    private func pop(_ height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: height).scaledBy(x: 0.958, y: 1.017)
    }

    private func bodyMotion(_ poses: [CGAffineTransform], times: [NSNumber], duration: Double) {
        let current = creature.presentation()?.affineTransform() ?? creature.affineTransform()
        creature.removeAnimation(forKey: "touch")
        keyframes(creature, poses: [current] + poses, times: times, duration: duration, key: "reaction")
    }

    private func showBadge(file: Bool) {
        badgeClear?.cancel()
        badgeClear = nil
        let path = CGMutablePath()
        if file {
            path.move(to: CGPoint(x: 2.5, y: 1.5))
            path.addLine(to: CGPoint(x: 2.5, y: 8.5))
            path.addLine(to: CGPoint(x: 6, y: 8.5))
            path.addLine(to: CGPoint(x: 8, y: 6.5))
            path.addLine(to: CGPoint(x: 8, y: 1.5))
            path.closeSubpath()
            path.move(to: CGPoint(x: 4, y: 4))
            path.addLine(to: CGPoint(x: 6.5, y: 4))
        } else {
            path.addEllipse(in: CGRect(x: 1.5, y: 1.5, width: 7, height: 7))
            path.move(to: CGPoint(x: 5, y: 7))
            path.addLine(to: CGPoint(x: 5, y: 5))
            path.addLine(to: CGPoint(x: 6.4, y: 4.3))
        }
        withoutActions {
            badge.path = path
            badge.strokeColor = (file ? NSColor(srgbRed: 0.75, green: 0.89, blue: 0.77, alpha: 1) : ivory).cgColor
            badge.opacity = reducedMotion ? 1 : 0
        }
        if reducedMotion {
            let clear = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.withoutActions { self.badge.opacity = 0 }
                self.badgeClear = nil
            }
            badgeClear = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: clear)
            return
        }
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 1, 1, 0]
        flash.keyTimes = [0, 0.17, 0.72, 1]
        flash.duration = 0.97
        badge.add(flash, forKey: "badge")
    }

    private func animateEyes(_ scales: [CGFloat], times: [NSNumber], duration: Double) {
        for (index, eye) in eyes.enumerated() {
            keyframes(eye, poses: scales.map { .init(scaleX: 1, y: $0) },
                      times: times, duration: duration + Double(index) * 0.03, key: "expression")
        }
    }

    private func keyframes(_ node: CALayer, poses: [CGAffineTransform], times: [NSNumber], duration: Double, key: String) {
        guard !reducedMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = poses.map { NSValue(caTransform3D: CATransform3DMakeAffineTransform($0)) }
        animation.keyTimes = times
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: times.count - 1)
        animation.duration = duration
        node.add(animation, forKey: key)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onRelease?(NSEvent.mouseLocation) }
    override func accessibilityPerformPress() -> Bool {
        onPress?(NSEvent.mouseLocation)
        onRelease?(NSEvent.mouseLocation)
        return true
    }
}

final class OverlayPanel: NSPanel {
    private let keyboardAllowed: Bool

    init(frame: CGRect, keyboard: Bool = false, nonactivating: Bool = true) {
        keyboardAllowed = keyboard
        let style: NSWindow.StyleMask = nonactivating ? [.borderless, .nonactivatingPanel] : [.borderless]
        super.init(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { keyboardAllowed }
    override var canBecomeMain: Bool { false }
}
