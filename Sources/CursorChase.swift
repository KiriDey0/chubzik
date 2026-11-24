import Foundation

struct CursorChase {
    enum Cue: Equatable {
        case crouch(CGFloat), feint(CGFloat), jump(CGFloat, duration: TimeInterval), catchCursor, miss, land
    }

    enum Attack: CaseIterable {
        case quick, pounce, feint

        var distance: CGFloat {
            switch self {
            case .quick: return 48
            case .pounce: return 104
            case .feint: return 154
            }
        }

        var windup: TimeInterval {
            switch self {
            case .quick: return 0.20
            case .pounce: return 0.31
            case .feint: return 0.46
            }
        }
    }

    enum PullPath: CaseIterable {
        case straight, arc, weave

        func bend(at progress: CGFloat) -> CGFloat {
            switch self {
            case .straight: return 0
            case .arc: return 55 * sin(.pi * progress)
            case .weave: return 32 * sin(.pi * progress) * (1 + sin(2 * .pi * progress))
            }
        }
    }

    enum Bearing: Int, CaseIterable {
        case west, northwest, north, northeast, east, southeast, south, southwest

        var offset: CGPoint {
            let diagonal = 1 / sqrt(CGFloat(2))
            switch self {
            case .west: return CGPoint(x: -1, y: 0)
            case .northwest: return CGPoint(x: -diagonal, y: diagonal)
            case .north: return CGPoint(x: 0, y: 1)
            case .northeast: return CGPoint(x: diagonal, y: diagonal)
            case .east: return CGPoint(x: 1, y: 0)
            case .southeast: return CGPoint(x: diagonal, y: -diagonal)
            case .south: return CGPoint(x: 0, y: -1)
            case .southwest: return CGPoint(x: -diagonal, y: -diagonal)
            }
        }

        func difference(from other: Bearing) -> Int {
            let steps = abs(rawValue - other.rawValue)
            return min(steps, Self.allCases.count - steps)
        }
    }

    struct Round {
        let attack: Attack
        let pullPath: PullPath
        let pullDuration: TimeInterval
        var bearing: Bearing = .west

        static func random(after previous: Round? = nil, launchedFrom bearing: Bearing? = nil) -> Round {
            Round(attack: Attack.allCases.filter { $0 != previous?.attack }.randomElement() ?? .quick,
                  pullPath: PullPath.allCases.filter { $0 != previous?.pullPath }.randomElement() ?? .straight,
                  pullDuration: Double.random(in: 0.7...2.5),
                  bearing: Bearing.allCases.filter {
                      guard let bearing else { return true }
                      return $0.difference(from: bearing) % 4 != 0
                  }.randomElement() ?? .west)
        }
    }

    struct Frame {
        var mascot: CGPoint
        var cursor: CGPoint?
        var cue: Cue?
        var paw: SlimePaw? = nil
    }

    private struct Grip {
        let started: TimeInterval
        let origin: CGPoint
        let destination: CGPoint
        let direction: CGFloat
        let rise: CGFloat
        let mascotOffset: CGPoint
        var lastCursor: CGPoint
        var resistance = CGPoint.zero
    }

    private enum Phase {
        case stalk
        case crouch(until: TimeInterval, bearing: Bearing, feintAt: TimeInterval?)
        case jump(started: TimeInterval, duration: TimeInterval, origin: CGPoint, target: CGPoint, height: CGFloat)
        case grip(Grip)
        case recover(until: TimeInterval)
    }

    private var phase = Phase.stalk
    private var round: Round
    private var lastBearing: Bearing?
    private var position: CGPoint
    private var lastTick: TimeInterval
    private var lastBounds: CGRect?

    init(at position: CGPoint, now: TimeInterval, round: Round = .random()) {
        self.position = position
        lastTick = now
        self.round = round
    }

    mutating func step(cursor: CGPoint, now: TimeInterval, bounds: CGRect,
                       mouseDown: Bool, reduceMotion: Bool) -> Frame {
        let elapsed = min(0.05, max(0, now - lastTick))
        lastTick = now
        if lastBounds != bounds {
            phase = .stalk
            position = clamp(position, to: bounds)
            lastBounds = bounds
        }
        var targetCursor: CGPoint?
        var cue: Cue?

        switch phase {
        case .stalk:
            let (bearing, waiting) = approach(to: cursor, in: bounds)
            let separation = distance(position, waiting)
            position = interpolate(position, waiting, by: separation == 0 ? 1 : min(1, 580 * elapsed / separation))
            if separation < 13 && !mouseDown {
                let feintAt = round.attack == .feint ? now + 0.20 : nil
                phase = .crouch(until: now + round.attack.windup, bearing: bearing, feintAt: feintAt)
                cue = .crouch(-bearing.offset.x)
            }
        case .crouch(let deadline, let bearing, let feintAt):
            if mouseDown || distance(position, cursor) > round.attack.distance + 80 {
                phase = .stalk
            } else if now >= deadline {
                let target = clamp(CGPoint(x: cursor.x + bearing.offset.x * 10,
                                            y: cursor.y + bearing.offset.y * 10), to: bounds)
                let length = distance(position, target)
                let duration = min(0.36, 0.12 + length / 710)
                lastBearing = bearing
                phase = .jump(started: now, duration: duration, origin: position,
                              target: target, height: min(32, max(9, length * 0.2)))
                cue = .jump((target.x - position.x) / max(1, length), duration: duration)
            } else if let feintAt, now >= feintAt {
                phase = .crouch(until: deadline, bearing: bearing, feintAt: nil)
                cue = .feint(-bearing.offset.x)
            }
        case .jump(let started, let duration, let origin, let target, let height):
            let progress = min(1, (now - started) / duration)
            position = interpolate(origin, target, by: MascotTravel.progress(at: progress))
            if !reduceMotion { position.y += height * sin(.pi * progress) }
            position = clamp(position, to: bounds)
            if progress >= 1 {
                if !mouseDown && distance(position, cursor) < 24 {
                    let length = 74 + round.pullDuration * 39
                    let preferred: CGFloat = origin.x <= target.x ? -1 : 1
                    let room = preferred < 0 ? cursor.x - bounds.minX : bounds.maxX - cursor.x
                    let direction = room >= length ? preferred : (cursor.x < bounds.midX ? 1 : -1)
                    let rise: CGFloat = cursor.y > bounds.midY ? -1 : 1
                    let destination = clamp(CGPoint(x: cursor.x + direction * length,
                                                    y: cursor.y + rise * 18), to: bounds)
                    let offset = CGPoint(x: position.x - cursor.x, y: position.y - cursor.y)
                    phase = .grip(Grip(started: now, origin: cursor, destination: destination,
                                       direction: direction, rise: rise, mascotOffset: offset, lastCursor: cursor))
                    cue = .catchCursor
                } else {
                    phase = .recover(until: now + 0.52)
                    cue = .miss
                }
            }
        case .grip(var grip):
            let progress = (now - grip.started) / round.pullDuration
            if progress >= 1 || mouseDown {
                phase = .recover(until: now + 0.50)
                cue = .land
            } else {
                grip.resistance.x = grip.resistance.x * 0.84 + (cursor.x - grip.lastCursor.x) * 0.30
                grip.resistance.y = grip.resistance.y * 0.84 + (cursor.y - grip.lastCursor.y) * 0.30
                let strength = hypot(grip.resistance.x, grip.resistance.y)
                if strength > 13 {
                    grip.resistance.x *= 13 / strength
                    grip.resistance.y *= 13 / strength
                }
                let ease = MascotTravel.progress(at: progress)
                var pull = interpolate(grip.origin, grip.destination, by: ease)
                if !reduceMotion { pull.y += grip.rise * round.pullPath.bend(at: ease) }
                let target = clamp(CGPoint(x: pull.x + grip.resistance.x, y: pull.y + grip.resistance.y), to: bounds)
                let turn = MascotTravel.progress(at: min(1, (now - grip.started) / 0.15))
                let paw = SlimePaw(side: -grip.direction, amount: 0.95 * turn)
                let offset = interpolate(grip.mascotOffset, CGPoint(x: -paw.tip.x, y: -paw.tip.y), by: turn)
                position = CGPoint(x: target.x + offset.x, y: target.y + offset.y)
                if distance(target, cursor) >= 1 {
                    grip.lastCursor = target
                    targetCursor = target
                } else {
                    grip.lastCursor = cursor
                }
                phase = .grip(grip)
                return Frame(mascot: position, cursor: targetCursor, cue: cue, paw: paw)
            }
        case .recover(let deadline):
            if now >= deadline {
                round = .random(after: round, launchedFrom: lastBearing)
                phase = .stalk
            }
        }
        return Frame(mascot: position, cursor: targetCursor, cue: cue)
    }

    private func approach(to cursor: CGPoint, in bounds: CGRect) -> (Bearing, CGPoint) {
        let pivot = clamp(cursor, to: bounds)
        let range = round.attack.distance
        var best: (bearing: Bearing, point: CGPoint, difference: Int)?
        for bearing in Bearing.allCases {
            let direction = bearing.offset
            let point = CGPoint(x: pivot.x + direction.x * range, y: pivot.y + direction.y * range)
            guard clamp(point, to: bounds) == point else { continue }
            let changesVerticalToHorizontal = abs(round.bearing.offset.y) == 1 && direction.y == 0
            let difference = bearing.difference(from: round.bearing) + (changesVerticalToHorizontal ? 2 : 0)
            if difference == 0 { return (bearing, point) }
            if difference < (best?.difference ?? .max) { best = (bearing, point, difference) }
        }
        if let best { return (best.bearing, best.point) }
        let offset = round.bearing.offset
        return (round.bearing, clamp(CGPoint(x: pivot.x + offset.x * range, y: pivot.y + offset.y * range), to: bounds))
    }

    private func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
                y: min(bounds.maxY, max(bounds.minY, point.y)))
    }

    private func interpolate(_ from: CGPoint, _ to: CGPoint, by progress: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}
