import AppKit

final class ShelfDelivery {
    private let mascotWindow: OverlayPanel
    private let mascot: MascotView
    private let cargo: OverlayPanel
    private var timer: Timer?

    init(mascotWindow: OverlayPanel, mascot: MascotView, icon: NSImage) {
        self.mascotWindow = mascotWindow
        self.mascot = mascot
        let size: CGFloat = 24
        cargo = OverlayPanel(frame: CGRect(x: 0, y: 0, width: size, height: size))
        cargo.title = "Файл на полку"
        cargo.ignoresMouseEvents = true
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        cargo.contentView = image
    }

    func start(pickup: CGPoint, drop: CGPoint, home: CGPoint, finished: @escaping () -> Void) {
        let from = CGPoint(x: mascotWindow.frame.midX, y: mascotWindow.frame.midY)
        let side: CGFloat = pickup.x <= drop.x ? 1 : -1
        let load = SlimePaw(side: side, amount: 0.92)
        let rest = SlimePaw(side: side, amount: 0)
        let pickupCenter = offset(pickup, by: rest.tip, subtract: true)
        let dropCenter = offset(drop, by: load.tip, subtract: true)
        let approachTime = flightTime(from, pickupCenter)
        let gripTime = 0.18
        let carryTime = flightTime(pickupCenter, dropCenter)
        let dropTime = 0.20
        let returnTime = flightTime(dropCenter, home)
        let started = ProcessInfo.processInfo.systemUptime
        position(cargo, at: pickup)
        cargo.orderFrontRegardless()
        var letGo = false
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let grip = elapsed - approachTime
            let carry = grip - gripTime
            let release = carry - carryTime
            let returning = release - dropTime
            if grip < 0 {
                self.fly(from, to: pickupCenter, fraction: elapsed / approachTime, bend: -1)
            } else if carry < 0 {
                let paw = SlimePaw(side: side, amount: load.amount * self.smooth(grip / gripTime))
                self.position(self.mascotWindow, at: self.offset(pickup, by: paw.tip, subtract: true))
                self.mascot.extendPaw(paw)
            } else if release < 0 {
                let point = self.fly(pickup, to: drop, fraction: carry / carryTime, bend: 1, moving: self.cargo)
                self.position(self.mascotWindow, at: self.offset(point, by: load.tip, subtract: true))
                self.mascot.extendPaw(load)
            } else if returning < 0 {
                let fraction = self.smooth(release / dropTime)
                self.mascot.extendPaw(SlimePaw(side: side, amount: load.amount * (1 - fraction)))
                self.cargo.alphaValue = 1 - fraction
                self.position(self.cargo, at: CGPoint(x: drop.x, y: drop.y + 8 * fraction))
            } else {
                if !letGo {
                    letGo = true
                    self.cargo.orderOut(nil)
                    self.mascot.extendPaw(nil)
                    self.mascot.react(.file)
                }
                if returning < returnTime {
                    self.fly(dropCenter, to: home, fraction: returning / returnTime, bend: -1)
                } else {
                    self.position(self.mascotWindow, at: home)
                    self.stop()
                    finished()
                }
            }
        }
        timer.tolerance = 0.002
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cargo.orderOut(nil)
        mascot.extendPaw(nil)
    }

    @discardableResult private func fly(_ start: CGPoint, to end: CGPoint, fraction: Double, bend: CGFloat,
                                       moving window: OverlayPanel? = nil) -> CGPoint {
        let t = smooth(fraction)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(1, hypot(dx, dy))
        let arc = sin(.pi * t) * min(39, length * 0.13) * bend
        let point = CGPoint(x: start.x + dx * t - dy * arc / length, y: start.y + dy * t + dx * arc / length)
        position(window ?? mascotWindow, at: point)
        mascot.look(CGPoint(x: min(3, max(-3, (end.x - point.x) / 24)),
                           y: min(2.5, max(-2.5, (end.y - point.y) / 24))))
        return point
    }

    private func position(_ window: OverlayPanel, at point: CGPoint) {
        window.setFrameOrigin(CGPoint(x: point.x - window.frame.width / 2, y: point.y - window.frame.height / 2))
    }

    private func offset(_ point: CGPoint, by tip: CGPoint, subtract: Bool) -> CGPoint {
        let direction: CGFloat = subtract ? -1 : 1
        return CGPoint(x: point.x + tip.x * direction, y: point.y + tip.y * direction)
    }

    private func flightTime(_ from: CGPoint, _ to: CGPoint) -> TimeInterval {
        min(0.74, max(0.20, 0.10 + hypot(from.x - to.x, from.y - to.y) / 1050))
    }

    private func smooth(_ fraction: Double) -> CGFloat {
        let t = min(1, max(0, fraction))
        return t * t * (3 - 2 * t)
    }
}
