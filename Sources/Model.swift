import Foundation
import CoreGraphics
import Darwin

enum PanelPage: String, CaseIterable, Identifiable {
    case music = "Музыка"
    case shelf = "Полка"
    case quick = "Таймеры и заметка"
    case tasks = "Задачи"
    case calendar = "Календарь"
    case weather = "Погода"
    case notices = "Журнал"
    var id: Self { self }

    var icon: String {
        switch self {
        case .music: "music.note"
        case .shelf: "tray"
        case .quick: "timer"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .weather: "cloud.sun"
        case .notices: "bell"
        }
    }
}

struct CodexPendingRequest: Codable, Identifiable, Equatable {
    let chat: String?
    let title: String?

    var id: String? { chat }
    var label: String { title ?? chat.map { "Чат · " + $0.suffix(8) } ?? "Запрос Codex" }

    static func register(_ request: Self, in pending: inout [Self]) {
        pending.removeAll { $0.chat == request.chat }
        pending.insert(request, at: 0)
    }

    static func resolve(_ chat: String?, in pending: inout [Self]) {
        pending.removeAll { $0.chat == chat }
    }
}

enum PanelOpening {
    static func page(last: PanelPage, preferred: PanelPage, dismissedAt: TimeInterval?, now: TimeInterval) -> PanelPage {
        guard let dismissedAt, now - dismissedAt < 25 else { return preferred }
        return last
    }
}

enum PanelSwipe {
    static func commits(distance: CGFloat, velocity: CGFloat, sampleAge: TimeInterval) -> Bool {
        abs(distance) >= 54 || (abs(distance) >= 26 && sampleAge < 0.10 &&
                               abs(velocity) >= 500 && distance * velocity > 0)
    }

    static func progress(distance: CGFloat, width: CGFloat, hasNeighbor: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        let travel = hasNeighbor ? abs(distance) : min(18, sqrt(abs(distance)) * 1.8)
        return min(1, travel / width)
    }
}

enum PanelExitGrace {
    static func delay(at point: CGPoint, panel: CGRect, notch: CGRect) -> TimeInterval {
        let distance = min(distance(from: point, to: panel), distance(from: point, to: notch))
        let proximity = 1 - min(distance / 240, 1)
        return 0.04 + 0.91 * proximity * proximity
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX),
              max(rect.minY - point.y, 0, point.y - rect.maxY))
    }
}

enum NotchSurface {
    static func path(in rect: CGRect, notchWidth: CGFloat, scale: CGFloat) -> CGPath {
        let shoulder = min(13 * scale, rect.height * 0.25)
        let halfNotch = min(notchWidth / 2, rect.width / 2)
        let excess = rect.width / 2 - halfNotch
        let radius = min(17 * scale, (rect.height - shoulder) / 2, excess * 0.68)
        let bridge = min(13 * scale, excess - radius)
        let left = rect.midX - halfNotch
        let right = rect.midX + halfNotch
        let top = rect.minY + shoulder
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.addCurve(to: CGPoint(x: right + bridge, y: top),
                      control1: CGPoint(x: right, y: top * 0.67 + rect.minY * 0.33),
                      control2: CGPoint(x: right + bridge * 0.55, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius), control: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top), control: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: left - bridge, y: top))
        path.addCurve(to: CGPoint(x: left, y: rect.minY),
                      control1: CGPoint(x: left - bridge * 0.55, y: top),
                      control2: CGPoint(x: left, y: top * 0.67 + rect.minY * 0.33))
        path.closeSubpath()
        return path
    }
}

enum MascotTravel {
    static func progress(at fraction: Double) -> CGFloat {
        let edge = 0.16
        let time = min(1, max(0, fraction))
        let ramp = min(time, 1 - time) / edge
        if ramp >= 1 { return (time - edge / 2) / (1 - edge) }
        let distance = edge * ramp * ramp * ramp * (1 - ramp / 2) / (1 - edge)
        return time < 0.5 ? distance : 1 - distance
    }
}

enum QuickChatHop {
    static let duration = 1.0 / 12
    private static let maximumDistance = CGFloat(duration * 2450)

    static func destination(from origin: CGPoint, to target: CGRect) -> CGRect {
        let dx = target.minX - origin.x
        let dy = target.minY - origin.y
        let distance = hypot(dx, dy)
        guard distance > maximumDistance else { return target }
        let scale = maximumDistance / distance
        return CGRect(x: origin.x + dx * scale, y: origin.y + dy * scale,
                      width: target.width, height: target.height)
    }
}

struct NotchGeometry {
    static let preferredPanelScale: CGFloat = 1.25
    static let fullPanelWidth: CGFloat = 400
    static let compactPanelWidth: CGFloat = 336
    static let fullPanelHeight: CGFloat = 200
    static let compactPanelHeight: CGFloat = 100
    static let panelNotchOverlap: CGFloat = 7

    let screen: CGRect
    let cutout: CGRect

    var mascot: CGRect {
        CGRect(x: min(cutout.maxX + 9, screen.maxX - 36), y: cutout.midY - 16, width: 32, height: 32)
    }

    var cover: CGRect {
        CGRect(x: max(cutout.minX - 37, screen.minX + 4), y: cutout.midY - 13, width: 26, height: 26)
    }

    func dropTarget(hasPhysicalNotch: Bool) -> CGRect {
        // The physical cutout has no pixels. Keep a target directly below it.
        let depth: CGFloat = 20
        return CGRect(x: cutout.minX, y: cutout.minY - depth,
                      width: cutout.width, height: depth + (hasPhysicalNotch ? cutout.height : 0))
    }

    var panelScale: CGFloat {
        min(Self.preferredPanelScale, (screen.width - 24) / Self.fullPanelWidth)
    }

    var player: CGRect { panel(width: Self.fullPanelWidth, height: Self.fullPanelHeight * panelScale) }

    func panel(width logicalWidth: CGFloat, height measuredHeight: CGFloat) -> CGRect {
        let width = logicalWidth * panelScale
        let height = ceil(measuredHeight)
        return CGRect(x: cutout.midX - width / 2,
                      y: cutout.minY - height + Self.panelNotchOverlap,
                      width: width, height: height)
    }

    var hover: CGRect {
        cover.union(cutout).union(mascot).insetBy(dx: -6, dy: -5)
    }

    var gazeRadius: CGFloat { screen.width / 4.5 }

    func constrained(_ point: CGPoint, window: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, screen.minX + 5), screen.maxX - window.width - 5),
            y: min(max(point.y, screen.minY + 5), screen.maxY - window.height - 5)
        )
    }
}

struct CalendarMonth {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    let interval: DateInterval
    let days: [Date?]

    init(containing date: Date, calendar: Calendar = Self.calendar) {
        let interval = calendar.dateInterval(of: .month, for: date)!
        self.interval = interval
        let firstDay = interval.start
        let leading = (calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7
        days = (0..<42).map { index in
            guard index >= leading,
                  let day = calendar.date(byAdding: .day, value: index - leading, to: firstDay),
                  day < interval.end else { return nil }
            return day
        }
    }
}

enum MonotonicTime {
    static var seconds: TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}

struct MediaItem: Equatable {
    struct Track: Hashable {
        let source: String
        let parent: String?
        let id: String
    }

    var source: String
    var parentSource: String?
    var id: String
    var title: String
    var artist: String
    var playing: Bool
    var duration: Double?
    var elapsed: Double?
    var timestamp: Date
    var positionAnchor = MonotonicTime.seconds
    var rate: Double
    var artwork: Data?
    var artworkURL: URL?
    var capabilities: Set<String>?

    var track: Track { Track(source: source, parent: parentSource, id: id) }

    var selectionSource: String {
        let bundle = parentSource ?? source
        return bundle.hasPrefix("com.lad.music.") ? "com.lad.music" : bundle
    }

    func position(at now: TimeInterval = MonotonicTime.seconds) -> Double? {
        guard let elapsed, elapsed.isFinite else { return nil }
        let advanced = playing ? max(0, now - positionAnchor) * rate : 0
        let position = max(0, elapsed + advanced)
        return duration.map { min(position, $0) } ?? position
    }

    var sourceName: String {
        let value = (parentSource ?? source).lowercased()
        if value.contains("lad") { return "Лад" }
        if value.contains("ardia") { return "ArDia" }
        if value == "com.apple.music" { return "Музыка" }
        if value == "com.spotify.client" { return "Spotify" }
        if value == "com.apple.safari" { return "Safari" }
        return parentSource ?? source
    }
}

struct NowPlayingDecoder {
    private var fields: [String: Any] = [:]
    private var artworkValue: String?
    private var artwork: Data?
    private var previous: (elapsed: Double?, timestamp: Date?, item: MediaItem)?

    mutating func ingest(_ line: Data, now: Date = .now, observedAt: TimeInterval = MonotonicTime.seconds) throws -> MediaItem? {
        guard let json = try JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed) as? [String: Any] else {
            fields = [:]
            artworkValue = nil
            artwork = nil
            previous = nil
            return nil
        }
        if let payload = json["payload"] as? [String: Any] {
            if json["diff"] as? Bool != true { fields = [:] }
            for (key, value) in payload {
                if value is NSNull { fields.removeValue(forKey: key) }
                else { fields[key] = value }
            }
        } else if json["type"] == nil {
            fields = json
        }
        guard let source = fields["bundleIdentifier"] as? String,
              let title = fields["title"] as? String, !title.isEmpty else {
            previous = nil
            return nil
        }
        let image = fields["artworkData"] as? String
        if image != artworkValue {
            artworkValue = image
            artwork = image.flatMap { $0.count <= 6_000_000 ? Data(base64Encoded: $0) : nil }
        }
        let timestamp = number("timestampEpochMicros").map { Date(timeIntervalSince1970: $0 / 1_000_000) }
        let duration = number("durationMicros").map { $0 / 1_000_000 } ?? number("duration")
        let elapsed = number("elapsedTimeMicros").map { $0 / 1_000_000 } ?? number("elapsedTime")
        var item = MediaItem(
            source: source, parentSource: fields["parentApplicationBundleIdentifier"] as? String,
            id: fields["contentItemIdentifier"] as? String ?? title,
            title: title, artist: fields["artist"] as? String ?? "",
            playing: fields["playing"] as? Bool ?? false,
            duration: duration.flatMap { $0 > 0 ? $0 : nil }, elapsed: elapsed,
            timestamp: timestamp ?? now, positionAnchor: observedAt,
            rate: min(4, max(0, number("playbackRate") ?? 1)),
            artwork: artwork, artworkURL: nil, capabilities: nil
        )
        let sameTimestamp = previous?.item.track == item.track && previous?.timestamp == timestamp
        if let previous, sameTimestamp, previous.elapsed == elapsed {
            if previous.item.playing == item.playing, previous.item.rate == item.rate {
                item.elapsed = previous.item.elapsed
                item.positionAnchor = previous.item.positionAnchor
            } else {
                item.elapsed = previous.item.position(at: observedAt)
            }
        } else if let timestamp, !sameTimestamp {
            item.positionAnchor -= max(0, now.timeIntervalSince(timestamp))
        }
        previous = (elapsed, timestamp, item)
        return item
    }

    private func number(_ key: String) -> Double? {
        guard let value = (fields[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }
}

struct ShelfState: Codable, Equatable {
    static let pinLimit = 4
    private(set) var paths: [String] = []
    private var pins: [String]?
    private var bookmarks: [String: Data]?

    var recordedPaths: Set<String> { Set(bookmarks?.keys.map { $0 } ?? []) }

    func references(for selection: Set<String>) -> [String: Data] {
        bookmarks?.filter { selection.contains($0.key) } ?? [:]
    }

    var pinnedPaths: [String] {
        Array((pins ?? []).filter { paths.contains($0) }.prefix(Self.pinLimit))
    }

    func displayedPaths(matching query: String = "") -> [String] {
        let first = pinnedPaths
        let ordered = first + paths.filter { !first.contains($0) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? ordered : ordered.filter {
            ($0 as NSString).lastPathComponent.localizedStandardContains(query)
        }
    }

    @discardableResult mutating func setPinned(_ selection: Set<String>, pinned: Bool) -> Bool {
        let next = pinnedPaths.filter { pinned || !selection.contains($0) }
        let additions = pinned ? paths.filter { selection.contains($0) && !next.contains($0) } : []
        guard next.count + additions.count <= Self.pinLimit else { return false }
        pins = next + additions
        return true
    }

    @discardableResult mutating func add(_ urls: [URL]) -> Int {
        var overflow = 0
        var unique = Set(paths)
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard unique.insert(path).inserted else { continue }
            if paths.count < 80 { paths.append(path) } else { overflow += 1 }
        }
        return overflow
    }

    mutating func remove(_ selection: Set<String>) {
        paths.removeAll { selection.contains($0) }
        pins?.removeAll { selection.contains($0) }
        for path in selection { bookmarks?.removeValue(forKey: path) }
    }

    @discardableResult mutating func updateReferences(in scanned: Set<String>) -> [String: String] {
        var references = bookmarks ?? [:]
        var renamed: [String: String] = [:]
        for path in paths where scanned.contains(path) {
            let old = URL(fileURLWithPath: path)
            let exists = FileManager.default.fileExists(atPath: path)
            guard let bookmark = references[path] else {
                if exists { references[path] = Self.bookmark(for: old) }
                continue
            }
            var stale = false
            let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
            if exists {
                let sameFile = resolved.map { $0.path == path || Self.isSameFile(old, $0) } ?? false
                let oldPath = old.standardizedFileURL.path
                let caseRename = resolved.map { url in
                    let newPath = url.standardizedFileURL.path
                    return stale && sameFile && oldPath != newPath && oldPath.caseInsensitiveCompare(newPath) == .orderedSame
                } ?? false
                if !caseRename {
                    // An editor can replace the file in place while leaving the old copy elsewhere.
                    if (stale || !sameFile), let updated = Self.bookmark(for: old) { references[path] = updated }
                    continue
                }
            }
            guard let moved = resolved, moved.path != path,
                  !moved.pathComponents.contains(".Trash"), !moved.pathComponents.contains(".Trashes"),
                  FileManager.default.fileExists(atPath: moved.path), let updated = Self.bookmark(for: moved) else { continue }
            renamed[path] = moved.path
            references.removeValue(forKey: path)
            references[moved.path] = updated
        }
        if !renamed.isEmpty {
            var seen = Set<String>()
            paths = paths.map { renamed[$0] ?? $0 }.filter { seen.insert($0).inserted }
            seen.removeAll()
            pins = pins?.map { renamed[$0] ?? $0 }.filter { seen.insert($0).inserted }
        }
        bookmarks = references.isEmpty ? nil : references
        return renamed
    }

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.minimalBookmark, .withoutImplicitSecurityScope])
    }

    private static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        var a = stat()
        var b = stat()
        return stat(first.path, &a) == 0 && stat(second.path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    mutating func restore(_ deletion: [(index: Int, path: String)],
                          removedPins: [(index: Int, path: String)] = [],
                          references: [String: Data] = [:]) -> Bool {
        let existing = Set(paths)
        let missing = deletion.filter { !existing.contains($0.path) }
        guard paths.count + missing.count <= 80 else { return false }
        for item in missing.sorted(by: { $0.index < $1.index }) {
            paths.insert(item.path, at: min(item.index, paths.count))
        }
        var orderedPins = pinnedPaths
        for pin in removedPins.sorted(by: { $0.index < $1.index }) where orderedPins.count < Self.pinLimit {
            if paths.contains(pin.path), !orderedPins.contains(pin.path) {
                orderedPins.insert(pin.path, at: min(pin.index, orderedPins.count))
            }
        }
        if !removedPins.isEmpty { pins = orderedPins }
        for item in missing {
            guard let reference = references[item.path] else { continue }
            if bookmarks == nil { bookmarks = [:] }
            bookmarks?[item.path] = reference
        }
        return true
    }
}

enum CleanLink {
    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        let trackerKeys: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "_ga", "_gl"]
        let signatureKeys: Set<String> = ["x-amz-signature", "x-goog-signature", "signature", "sig", "oauth_signature", "hmac"]
        // Keep the escaping and ordering of untouched query parameters.
        guard let query = url.percentEncodedQuery else { return trimmed }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let names = pairs.map { pair in
            let raw = String(pair.prefix(while: { $0 != "=" }))
            return (raw.removingPercentEncoding ?? raw).lowercased()
        }
        guard signatureKeys.isDisjoint(with: names) else { return trimmed }
        let result = zip(pairs, names).filter { !$0.1.hasPrefix("utm_") && !trackerKeys.contains($0.1) }
        guard result.count != pairs.count else { return trimmed }
        var cleaned = url
        cleaned.percentEncodedQuery = result.isEmpty ? nil : result.map(\.0).joined(separator: "&")
        return cleaned.string
    }
}

struct Countdown: Codable {
    enum Phase: String, Codable {
        case timer, focus, rest

        var title: String {
            switch self {
            case .timer: "Таймер"
            case .focus: "Фокус"
            case .rest: "Перерыв"
            }
        }
    }
    let end: Date
    let phase: Phase
    var pausedSeconds: TimeInterval? = nil

    var isPaused: Bool { pausedSeconds != nil }

    func remaining(at date: Date) -> TimeInterval {
        pausedSeconds ?? max(0, end.timeIntervalSince(date))
    }

    func togglingPause(at date: Date) -> Countdown? {
        let seconds = remaining(at: date)
        guard seconds > 0 else { return nil }
        return Countdown(end: date.addingTimeInterval(seconds), phase: phase,
                         pausedSeconds: isPaused ? nil : seconds)
    }

    func next(after now: Date) -> Countdown? {
        guard phase == .focus, !isPaused, end <= now else { return nil }
        let relaxedUntil = end.addingTimeInterval(300)
        return relaxedUntil > now ? Countdown(end: relaxedUntil, phase: .rest) : nil
    }
}

struct Stopwatch: Codable {
    struct Instant {
        let wallTime: Date
        let continuousSeconds: TimeInterval
        let bootSession: UUID?

        static func now(wallTime: Date = .now) -> Self {
            Self(wallTime: wallTime,
                 continuousSeconds: MonotonicTime.seconds,
                 bootSession: currentBootSession)
        }

        private static let currentBootSession: UUID? = {
            var bytes = [CChar](repeating: 0, count: 64)
            var size = bytes.count
            guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
                  size > 1, size <= bytes.count, bytes[size - 1] == 0 else { return nil }
            return UUID(uuidString: String(cString: bytes))
        }()
    }

    private struct Anchor: Codable {
        let continuousSeconds: TimeInterval
        let bootSession: UUID
    }

    var started: Date?
    var elapsed: TimeInterval = 0
    private var anchor: Anchor?

    var isRunning: Bool { started != nil }
    var isPresent: Bool { isRunning || elapsed > 0 }

    func seconds(at now: Instant = .now()) -> TimeInterval {
        guard let started else { return elapsed }
        if let anchor, anchor.bootSession == now.bootSession {
            return elapsed + max(0, now.continuousSeconds - anchor.continuousSeconds)
        }
        return elapsed + max(0, now.wallTime.timeIntervalSince(started))
    }

    mutating func toggle(at now: Instant = .now()) {
        if isRunning {
            elapsed = seconds(at: now)
            started = nil
            anchor = nil
        } else {
            start(at: now)
        }
    }

    mutating func migrateClock(at now: Instant = .now()) -> Bool {
        guard isRunning, let session = now.bootSession, anchor?.bootSession != session else { return false }
        elapsed = seconds(at: now)
        start(at: now)
        return true
    }

    private mutating func start(at now: Instant) {
        started = now.wallTime
        anchor = now.bootSession.map { Anchor(continuousSeconds: now.continuousSeconds, bootSession: $0) }
    }
}

enum ActivityClock {
    static func compact(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "–" }
        let total = Int(min(999_999_999, max(0, seconds)))
        if total < 6000 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(total / 3600) + "ч " + String(total / 60 % 60) + "м"
    }
}
