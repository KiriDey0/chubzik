import CoreGraphics
import Foundation

struct SlimePaw: Equatable {
    let side: CGFloat
    let amount: CGFloat
    var turn: CGFloat = 0

    private static let round: [[CGPoint]] = [
        [p(0.37, -0.93), p(0.63, -0.73), p(0.77, -0.52)],
        [p(0.91, -0.31), p(0.99, -0.05), p(0.98, 0.16)],
        [p(0.97, 0.37), p(0.91, 0.53), p(0.79, 0.67)],
        [p(0.62, 0.87), p(0.30, 0.91), p(0, 0.91)]
    ]
    private static let raised: [[CGPoint]] = [
        [p(0.40, -0.93), p(0.55, -0.58), p(0.72, -0.58)],
        [p(0.88, -0.58), p(1.00, -1.14), p(1.10, -1.10)],
        [p(1.22, -1.05), p(1.13, -0.43), p(0.96, 0.10)],
        [p(0.76, 0.63), p(0.53, 0.91), p(0, 0.91)]
    ]
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private func flank(_ direction: CGFloat) -> [[CGPoint]] {
        let lift = direction == side ? amount : 0
        let shift = -side * amount * 0.19
        return zip(Self.round, Self.raised).map { normal, extended in
            zip(normal, extended).map { a, b in
                let x = (a.x + (b.x - a.x) * lift) * direction + shift * (1 - a.x)
                let y = a.y + (b.y - a.y) * lift
                return Self.p(x * 13.55, -y * 13.75)
            }
        }
    }

    var tip: CGPoint { rotate(flank(side)[1][2]) }

    private func rotate(_ point: CGPoint) -> CGPoint {
        let angle = turn * amount
        return Self.p(point.x * cos(angle) - point.y * sin(angle),
                      point.x * sin(angle) + point.y * cos(angle))
    }

    func outline(in bounds: CGRect) -> CGPath {
        let right = flank(1)
        let left = flank(-1)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        func local(_ point: CGPoint) -> CGPoint {
            let rotated = rotate(point)
            return Self.p(center.x + rotated.x, center.y + rotated.y)
        }
        let top = Self.p(-side * amount * 0.19 * 13.55, 0.93 * 13.75)
        let path = CGMutablePath()
        path.move(to: local(top))
        for curve in right {
            path.addCurve(to: local(curve[2]), control1: local(curve[0]), control2: local(curve[1]))
        }
        for index in left.indices.reversed() {
            let curve = left[index]
            let end = index == 0 ? top : left[index - 1][2]
            path.addCurve(to: local(end), control1: local(curve[1]), control2: local(curve[0]))
        }
        path.closeSubpath()
        return path
    }
}

enum CompletionMode: String, CaseIterable, Identifiable {
    case soft = "Мягкий"
    case medium = "Средний"
    case high = "Высокий"

    var id: Self { self }
    var detail: String {
        switch self {
        case .soft: "Два рывка указателя."
        case .medium: "Пауза видео, два рывка и кнопка «К ответу»."
        case .high: "Пауза видео, если оно играет, и переход к полю ввода завершившегося диалога."
        }
    }
}

struct CompletionNudge {
    enum Action { case pause, openAnswer }

    struct Frame {
        var mascot: CGPoint
        var cursor: CGPoint?
        var paw: SlimePaw?
        var action: Action?
        var tug = false
        var cancelled = false
        var finished = false
    }

    private enum Target { case video, cursor }
    private struct Reach {
        let side: CGFloat
        var turn: CGFloat = 0
        func paw(_ amount: CGFloat) -> SlimePaw { .init(side: side, amount: amount, turn: turn) }
    }
    private enum Phase {
        case approach(Target, deadline: TimeInterval)
        case reach(Target, since: TimeInterval, reach: Reach, start: CGPoint)
        case tapRelease(since: TimeInterval, reach: Reach)
        case grip(started: TimeInterval, reach: Reach, origin: CGPoint, last: CGPoint, tugs: Int)
        case lead(started: TimeInterval, reach: Reach, origin: CGPoint)
        case waitForComposer(until: TimeInterval, reach: Reach)
        case carry(started: TimeInterval, reach: Reach, from: CGPoint, to: CGPoint, duration: Double)
        case release(since: TimeInterval, reach: Reach)
        case returning
    }

    private let display: CGRect?
    private let video: CGPoint?
    private var guidesToAnswer: Bool
    private let overhead: Bool
    private var lastTick: TimeInterval
    private var lastPointer: CGPoint?
    private var position: CGPoint
    private var phase: Phase

    init(at position: CGPoint, now: TimeInterval, display: CGRect? = nil, video: CGPoint? = nil,
         guidesToAnswer: Bool = false, overhead: Bool = false) {
        self.position = position
        self.display = display
        self.video = video
        self.guidesToAnswer = guidesToAnswer
        self.overhead = overhead
        self.lastTick = now
        phase = .approach(video == nil ? .cursor : .video, deadline: now + 1.8)
    }

    mutating func step(cursor: CGPoint, home: CGPoint, display: CGRect, now: TimeInterval,
                       mouseDown: Bool, reduceMotion: Bool) -> Frame {
        let elapsed = min(0.05, max(0, now - lastTick))
        lastTick = now
        let jumped = lastPointer.map { distance(cursor, $0) > 23 } ?? false
        lastPointer = cursor
        if mouseDown || jumped || self.display.map({ $0 != display }) == true {
            if case .returning = phase {} else {
                phase = .returning
                return Frame(mascot: position, cancelled: true)
            }
        }

        switch phase {
        case .approach(let target, let deadline):
            let point = location(target, cursor: cursor)
            let reach = reachFor(point, home: home, display: display, overhead: target == .cursor && overhead)
            let destination = contact(point, paw: reach.paw(0.92))
            let remaining = distance(position, destination)
            let step = reduceMotion ? .infinity : min(1900, max(135, remaining * 9)) * elapsed
            if remaining > 50, step < remaining {
                let axis = CGPoint(x: destination.x - position.x, y: destination.y - position.y)
                let bend = (reach.side * 0.23) * min(1, (remaining - 50) / 170)
                position.x += step * (axis.x - axis.y * bend) / remaining
                position.y += step * (axis.y + axis.x * bend) / remaining
            } else {
                move(toward: destination, by: step)
            }
            if distance(position, destination) < 1 {
                phase = .reach(target, since: now, reach: reach, start: position)
            } else if now >= deadline {
                phase = .returning
                return Frame(mascot: position, cancelled: true)
            }
        case .reach(let target, let since, let reach, let start):
            let point = location(target, cursor: cursor)
            let fraction = smooth((now - since) / (reduceMotion ? 0.12 : 0.23))
            let paw = reach.paw(0.92 * fraction)
            position = mix(start, contact(point, paw: paw), fraction: fraction)
            if fraction < 1 { return Frame(mascot: position, paw: paw) }
            if target == .cursor {
                phase = guidesToAnswer ? .lead(started: now, reach: reach, origin: cursor)
                    : .grip(started: now, reach: reach, origin: cursor, last: cursor, tugs: 0)
                return Frame(mascot: position, paw: paw)
            }
            phase = .tapRelease(since: now, reach: reach)
            return Frame(mascot: position, paw: paw, action: .pause)
        case .tapRelease(let since, let reach):
            let fraction = smooth((now - since) / 0.17)
            if fraction >= 1 {
                phase = .approach(.cursor, deadline: now + 1.8)
            }
            return Frame(mascot: position, paw: reach.paw(0.92 * (1 - fraction)))
        case .grip(let started, let reach, let origin, let last, var tugs):
            let age = now - started
            guard age < 1.82 else {
                phase = .release(since: now, reach: reach)
                return Frame(mascot: position, paw: reach.paw(0.92))
            }
            // A previous cursor warp may still be in flight when the next frame samples the pointer.
            // Keep the cue anchored and let a deliberate movement out of the grip cancel it.
            if distance(cursor, last) > 6 {
                phase = .returning
                return Frame(mascot: position, cancelled: true)
            }
            let first = smooth((age - 0.21) / 0.43)
            let second = smooth((age - 1.06) / 0.44)
            let scale: CGFloat = reduceMotion ? 0.45 : 1
            let tip = reach.paw(0.92).tip
            let length = hypot(tip.x, tip.y)
            let forward = scale * (8 * first + 7 * second)
            let bend = scale * (3 * first - 5 * second)
            let x = origin.x + (-tip.x * forward + tip.y * bend) / length
            let y = origin.y + (-tip.y * forward - tip.x * bend) / length
            let moved = CGPoint(x: min(display.maxX - 1, max(display.minX, x.rounded())),
                                y: min(display.maxY - 1, max(display.minY, y.rounded())))
            let tension = sin(.pi * first) + sin(.pi * second)
            let paw = reach.paw(0.92 + 0.08 * tension)
            position = contact(moved, paw: paw)
            let tug = (first > 0 && tugs == 0) || (second > 0 && tugs == 1)
            if tug { tugs += 1 }
            phase = .grip(started: started, reach: reach, origin: origin, last: moved, tugs: tugs)
            lastPointer = moved
            return Frame(mascot: position, cursor: moved == cursor ? nil : moved, paw: paw, tug: tug)
        case .lead(let started, let reach, let origin):
            let amount = smooth((now - started) / 0.19)
            let paw = reach.paw(0.92 + 0.08 * sin(.pi * amount))
            if !guidesToAnswer {
                phase = .grip(started: now, reach: reach, origin: cursor, last: cursor, tugs: 0)
                return Frame(mascot: position, paw: paw)
            }
            let tip = reach.paw(0.92).tip
            let length = hypot(tip.x, tip.y)
            let pull = (reduceMotion ? 3.0 : 7.0) * amount
            let moved = bounded(CGPoint(x: origin.x - tip.x * pull / length,
                                        y: origin.y - tip.y * pull / length), in: display)
            position = contact(moved, paw: paw)
            lastPointer = moved
            if amount >= 1 { phase = .waitForComposer(until: now + 1.85, reach: reach) }
            return Frame(mascot: position, cursor: moved == cursor ? nil : moved, paw: paw,
                         action: amount >= 1 ? .openAnswer : nil)
        case .waitForComposer(let until, let reach):
            let paw = reach.paw(0.92)
            position = contact(cursor, paw: paw)
            if now >= until { phase = .release(since: now, reach: reach) }
            return Frame(mascot: position, paw: paw)
        case .carry(let started, let reach, let from, let to, let duration):
            let amount = smooth((now - started) / duration)
            let length = distance(from, to)
            let bend = reduceMotion ? 0 : sin(.pi * amount) * min(30, length * 0.16)
            let progress = mix(from, to, fraction: amount)
            let moved = bounded(CGPoint(x: progress.x + (to.y - from.y) * bend / length,
                                        y: progress.y - (to.x - from.x) * bend / length), in: display)
            let paw = reach.paw(0.92)
            position = contact(moved, paw: paw)
            lastPointer = moved
            if amount >= 1 { phase = .release(since: now, reach: reach) }
            return Frame(mascot: position, cursor: moved == cursor ? nil : moved, paw: paw)
        case .release(let since, let reach):
            let fraction = smooth((now - since) / 0.18)
            if fraction >= 1 { phase = .returning }
            return Frame(mascot: position, paw: reach.paw(0.92 * (1 - fraction)))
        case .returning:
            move(toward: home, by: reduceMotion ? .infinity : 2400 * elapsed)
            return Frame(mascot: position, finished: position == home)
        }
        return Frame(mascot: position)
    }

    mutating func redirectToCursor() {
        guidesToAnswer = false
        switch phase {
        case .approach(.video, _), .reach(.video, _, _, _), .waitForComposer:
            phase = .approach(.cursor, deadline: lastTick + 1.8)
        default: break
        }
    }

    var awaitsComposer: Bool {
        if case .waitForComposer = phase { return true }
        return false
    }

    mutating func restartComposerWait(now: TimeInterval) {
        guard case .waitForComposer(_, let reach) = phase else { return }
        phase = .waitForComposer(until: now + 1.85, reach: reach)
    }

    mutating func guide(to point: CGPoint?, from cursor: CGPoint, now: TimeInterval, reduceMotion: Bool) {
        guard case .waitForComposer(let until, let reach) = phase, now < until else { return }
        guard let point, let display, display.insetBy(dx: 18, dy: 18).contains(point),
              distance(cursor, point) >= 8 else {
            phase = .release(since: now, reach: reach)
            return
        }
        let duration = reduceMotion ? 0.28 : min(0.80, max(0.38, 0.24 + distance(cursor, point) / 1100))
        phase = .carry(started: now, reach: reach, from: cursor, to: point, duration: duration)
    }

    private func location(_ target: Target, cursor: CGPoint) -> CGPoint {
        switch target {
        case .video: video ?? cursor
        case .cursor: cursor
        }
    }

    private func bounded(_ point: CGPoint, in display: CGRect) -> CGPoint {
        CGPoint(x: min(display.maxX - 1, max(display.minX, point.x.rounded())),
                y: min(display.maxY - 1, max(display.minY, point.y.rounded())))
    }

    private func reachFor(_ point: CGPoint, home: CGPoint, display: CGRect, overhead: Bool) -> Reach {
        let side: CGFloat = point.x >= home.x ? 1 : -1
        // Give the body room to land and to move with both tugs.
        let safe = display.insetBy(dx: 27, dy: 27)
        let primary = Reach(side: side)
        let alternate = Reach(side: -side)
        let fromAbove = oriented(side: side, angle: -.pi / 2)
        let fromBelow = oriented(side: side, angle: .pi / 2)
        let candidates = overhead && point.y <= display.maxY - 48
            ? [fromAbove, primary, alternate, fromBelow]
            : [primary, alternate, fromAbove, fromBelow]
        for reach in candidates where safe.contains(contact(point, paw: reach.paw(0.92))) {
            return reach
        }
        let edgeSide: CGFloat = point.x < display.midX ? -1 : 1
        let y: CGFloat = point.y > display.midY ? 1 : -1
        return oriented(side: edgeSide, angle: atan2(y, edgeSide))
    }

    private func oriented(side: CGFloat, angle: CGFloat) -> Reach {
        let tip = Reach(side: side).paw(0.92).tip
        let delta = angle - atan2(tip.y, tip.x)
        return Reach(side: side, turn: atan2(sin(delta), cos(delta)) / 0.92)
    }

    private func contact(_ point: CGPoint, paw: SlimePaw) -> CGPoint {
        let tip = paw.tip
        return CGPoint(x: point.x - tip.x, y: point.y - tip.y)
    }

    private mutating func move(toward target: CGPoint, by limit: CGFloat) {
        let length = distance(position, target)
        position = length <= limit ? target : mix(position, target, fraction: limit / length)
    }

    private func mix(_ from: CGPoint, _ to: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
    }

    private func smooth(_ fraction: Double) -> CGFloat {
        let p = min(1, max(0, fraction))
        return p * p * (3 - 2 * p)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
