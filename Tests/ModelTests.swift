import Foundation
import EventKit
import SQLite3

@main enum ModelTests {
    private static func testProjectFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        var database: OpaquePointer?
        precondition(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let seed = """
        CREATE TABLE threads (title TEXT, name TEXT, cwd TEXT, archived INTEGER);
        INSERT INTO threads VALUES
            ('Old title', 'Current  chat', '/tmp', 0),
            ('Current chat', NULL, '/private/tmp', 0),
            ('Other chat', NULL, '/tmp', 0),
            ('Other chat', NULL, '/Users', 0),
            ('Archived chat', NULL, '/tmp', 1);
        """
        precondition(sqlite3_exec(database, seed, nil, nil, nil) == SQLITE_OK)
        let expected = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().path
        precondition(CodexProjectFolder.find(title: "Current chat", in: home)?.resolvingSymlinksInPath().path == expected,
                     "The active title can resolve through multiple chats in the same directory")
        precondition(CodexProjectFolder.find(title: "Other chat", in: home) == nil,
                     "Chats in different directories must remain ambiguous")
        precondition(CodexProjectFolder.find(title: "Archived chat", in: home) == nil)
        print("PASS project folder lookup handles one directory behind multiple matching chat titles")
    }

    private static func testCompletionNudge() {
        let display = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let home = CGPoint(x: 700, y: 880)
        for origin in [CGPoint(x: -1279, y: 380), CGPoint(x: -1, y: 350)] {
            var cursor = origin
            var nudge = CompletionNudge(at: home, now: 0)
            var tugs: [Double] = []
            var firstGrip: Double?
            var lastGrip: Double?
            var displacement: CGFloat = 0
            var finished = false
            for index in 1...300 {
                let time = Double(index) / 60
                let frame = nudge.step(cursor: cursor, home: home, display: display, now: time,
                                       mouseDown: false, reduceMotion: false)
                if let target = frame.cursor {
                    precondition(display.contains(target))
                    let tip = frame.paw!.tip
                    precondition(hypot(frame.mascot.x + tip.x - target.x, frame.mascot.y + tip.y - target.y) < 0.0001)
                    cursor = target
                    displacement = max(displacement, hypot(cursor.x - origin.x, cursor.y - origin.y))
                }
                if frame.tug { tugs.append(time) }
                if (frame.paw?.amount ?? 0) >= 0.92 {
                    firstGrip = firstGrip ?? time
                    lastGrip = time
                }
                if frame.finished {
                    finished = frame.mascot == home
                    break
                }
            }
            precondition(finished && tugs.count == 2 && (0.8...0.95).contains(tugs[1] - tugs[0]))
            precondition((1.8...1.9).contains(lastGrip! - firstGrip!))
            precondition((12...16).contains(displacement) && cursor != origin)
        }
        let cursor = CGPoint(x: -550, y: 300)
        var jittered = CompletionNudge(at: cursor, now: 0)
        var observed = cursor
        var jitteredTugs = 0
        for tick in 1...180 {
            let frame = jittered.step(cursor: observed, home: home, display: display, now: Double(tick) / 60,
                                      mouseDown: false, reduceMotion: false)
            if let next = frame.cursor {
                precondition(hypot(next.x - cursor.x, next.y - cursor.y) <= 16)
                observed = CGPoint(x: next.x + 1, y: next.y)
            }
            if frame.tug { jitteredTugs += 1 }
        }
        precondition(jitteredTugs == 2)
        var nudge = CompletionNudge(at: home, now: 0)
        for index in 1...150 {
            let frame = nudge.step(cursor: cursor, home: home, display: display, now: Double(index) / 60,
                                   mouseDown: true, reduceMotion: true)
            precondition(frame.cursor == nil && !frame.tug)
        }
        let video = CGPoint(x: -300, y: 330), composer = CGPoint(x: -670, y: 140)
        var retargeted = CompletionNudge(at: home, now: 0, display: display, video: video, guidesToAnswer: true)
        _ = retargeted.step(cursor: cursor, home: home, display: display, now: 0.01, mouseDown: false, reduceMotion: true)
        retargeted.redirectToCursor()
        var retargetedCursor = cursor
        var retargetedTugs = 0
        for tick in 2...180 {
            let frame = retargeted.step(cursor: retargetedCursor, home: home, display: display, now: Double(tick) / 60,
                                        mouseDown: false, reduceMotion: true)
            precondition(frame.action == nil, "A second completion must cancel the pending video pause")
            if let next = frame.cursor { retargetedCursor = next }
            if frame.tug { retargetedTugs += 1 }
        }
        precondition(retargetedTugs == 2)
        for (autoOpen, hasVideo) in [(false, true), (true, true), (true, false)] {
            let origin = CGPoint(x: -550, y: 300)
            var cursor = origin
            var motion = CompletionNudge(at: home, now: 0, display: display, video: hasVideo ? video : nil,
                                         guidesToAnswer: autoOpen)
            var actions: [CompletionNudge.Action] = []
            var tugs = 0
            for index in 1...420 {
                let frame = motion.step(cursor: cursor, home: home, display: display, now: Double(index) / 60,
                                        mouseDown: false, reduceMotion: false)
                precondition(!frame.cancelled)
                if let target = frame.cursor { cursor = target }
                if let action = frame.action {
                    let point = action == .pause ? video : cursor
                    let tip = frame.paw!.tip
                    precondition(hypot(frame.mascot.x + tip.x - point.x, frame.mascot.y + tip.y - point.y) < 0.0001)
                    if action == .openAnswer {
                        precondition(cursor != origin && motion.awaitsComposer)
                        motion.guide(to: composer, from: cursor, now: Double(index) / 60, reduceMotion: false)
                    } else {
                        precondition(frame.cursor == nil)
                    }
                    actions.append(action)
                }
                if frame.tug { tugs += 1 }
                if frame.finished { break }
            }
            precondition(actions == ((hasVideo ? [.pause] : []) + (autoOpen ? [.openAnswer] : [])))
            precondition(tugs == (autoOpen ? 0 : 2))
            if autoOpen { precondition(cursor == composer) }
        }
        var interrupted = CompletionNudge(at: cursor, now: 0, display: display)
        _ = interrupted.step(cursor: cursor, home: home, display: display, now: 0.05, mouseDown: false, reduceMotion: true)
        let aborted = interrupted.step(cursor: CGPoint(x: cursor.x - 46, y: cursor.y), home: home, display: display,
                                       now: 0.10, mouseDown: false, reduceMotion: true)
        precondition(aborted.cancelled && aborted.cursor == nil && aborted.action == nil)
        let center = CGPoint(x: -640, y: 820)
        for (x, side, overhead) in [(-900.0, -1.0, false), (-400.0, 1.0, false), (-900.0, -1.0, true)] {
            let start = CGPoint(x: x, y: 380)
            var cursor = start
            var motion = CompletionNudge(at: center, now: 0, display: display, overhead: overhead)
            var firstTug: CompletionNudge.Frame?
            for tick in 1...300 {
                let frame = motion.step(cursor: cursor, home: center, display: display, now: Double(tick) / 60,
                                        mouseDown: false, reduceMotion: false)
                if frame.tug, firstTug == nil { firstTug = frame }
                if let moved = frame.cursor { cursor = moved }
                if frame.finished { break }
            }
            precondition(firstTug?.paw?.side == CGFloat(side))
            if overhead {
                precondition(firstTug!.mascot.y > start.y + 15 && cursor.y > start.y + 13)
            } else {
                precondition((cursor.x - start.x) * side < -8)
            }
        }
        print("Completion cue makes two short tugs, returns home, and leaves an active click alone")
    }

    private static func testCursorChase() {
        let bounds = CGRect(x: 18, y: 18, width: 800, height: 600)
        let start = CGPoint(x: 194, y: 290)
        let target = CGPoint(x: 380, y: 290)

        func play(_ round: CursorChase.Round, at target: CGPoint? = nil, dodge: Bool = false, reduceMotion: Bool = false)
            -> (launch: CGPoint, cues: [CursorChase.Cue], duration: Double, samples: [CGPoint]) {
            let target = target ?? CGPoint(x: 380, y: 290)
            var chase = CursorChase(at: start, now: 0, round: round)
            var cursor = target
            var cues: [CursorChase.Cue] = []
            var positions: [CGPoint] = []
            var launch = CGPoint.zero
            var catchTime = 0.0
            for tick in 0...500 {
                let time = Double(tick) / 120
                let frame = chase.step(cursor: cursor, now: time, bounds: bounds, mouseDown: false, reduceMotion: reduceMotion)
                if let cue = frame.cue { cues.append(cue) }
                if let pull = frame.cursor {
                    precondition(bounds.insetBy(dx: -0.001, dy: -0.001).contains(pull))
                    positions.append(pull)
                    cursor = pull
                }
                switch frame.cue {
                case .jump:
                    launch = frame.mascot
                    if dodge { cursor = CGPoint(x: 740, y: 375) }
                case .catchCursor:
                    catchTime = time
                case .miss:
                    return (launch, cues, 0, positions)
                case .land:
                    return (launch, cues, time - catchTime, positions)
                default: break
                }
            }
            preconditionFailure("The chase did not finish")
        }

        let quick = CursorChase.Round(attack: .quick, pullPath: .straight, pullDuration: 0.7)
        let long = CursorChase.Round(attack: .pounce, pullPath: .arc, pullDuration: 2.5)
        let fake = CursorChase.Round(attack: .feint, pullPath: .weave, pullDuration: 1.5)
        let straight = play(quick)
        let arc = play(long)
        let weave = play(fake)
        precondition(abs(straight.duration - 0.7) < 0.01 && abs(arc.duration - 2.5) < 0.01)
        precondition(straight.launch.x - arc.launch.x > 42 && arc.launch.x - weave.launch.x > 38)
        precondition(weave.cues.contains(.feint(1)) && weave.cues.contains(.catchCursor))
        let miss = play(fake, dodge: true)
        precondition(miss.samples.isEmpty && miss.cues.last == .miss)

        func deviation(_ samples: [CGPoint]) -> CGFloat {
            let final = samples.last!
            return samples.map { abs($0.y - target.y - ($0.x - target.x) * (final.y - target.y) / (final.x - target.x)) }.max()!
        }
        precondition(deviation(straight.samples) < 0.1)
        precondition(deviation(arc.samples) > 45 && deviation(weave.samples) > 40)
        precondition(deviation(play(long, reduceMotion: true).samples) < 0.1)
        for bearing in [CursorChase.Bearing.north, .south, .northeast, .southwest] {
            var round = quick
            round.bearing = bearing
            let jump = play(round)
            let offset = bearing.offset
            precondition(abs(jump.launch.x - target.x - offset.x * quick.attack.distance) < 13)
            precondition(abs(jump.launch.y - target.y - offset.y * quick.attack.distance) < 13)
            precondition(abs(jump.launch.y - target.y) > 20 && jump.cues.contains(.catchCursor))
        }
        var fromAbove = fake
        fromAbove.bearing = .north
        let edge = play(fromAbove, at: CGPoint(x: 380, y: bounds.maxY - 4))
        precondition(bounds.contains(edge.launch) && edge.launch.y < bounds.maxY - 80)
        precondition(edge.cues.contains(.catchCursor))
        for _ in 0..<24 {
            let next = CursorChase.Round.random(after: quick, launchedFrom: .west)
            precondition(next.attack != quick.attack && next.pullPath != quick.pullPath)
            precondition(next.bearing != .west && next.bearing != .east)
            precondition((0.7...2.5).contains(next.pullDuration))
        }

        var ready = CursorChase(at: CGPoint(x: 332, y: 290), now: 0, round: quick)
        _ = ready.step(cursor: target, now: 0, bounds: bounds, mouseDown: false, reduceMotion: true)
        _ = ready.step(cursor: target, now: 0.21, bounds: bounds, mouseDown: false, reduceMotion: true)
        let caught = ready.step(cursor: target, now: 0.54, bounds: bounds, mouseDown: false, reduceMotion: true)
        precondition(caught.cue == .catchCursor)
        var resisting = ready
        let normal = ready.step(cursor: target, now: 0.81, bounds: bounds, mouseDown: false, reduceMotion: true)
        let pushed = resisting.step(cursor: CGPoint(x: 500, y: 290), now: 0.81, bounds: bounds,
                                    mouseDown: false, reduceMotion: true)
        precondition((10...13.001).contains(pushed.cursor!.x - normal.cursor!.x))
        let release = ready.step(cursor: normal.cursor!, now: 0.83, bounds: bounds, mouseDown: true, reduceMotion: true)
        precondition(release.cue == .land && release.cursor == nil)
        let otherDisplay = CGRect(x: -980, y: 35, width: 940, height: 700)
        let moved = resisting.step(cursor: CGPoint(x: -970, y: 36), now: 0.83, bounds: otherDisplay,
                                   mouseDown: false, reduceMotion: true)
        precondition(otherDisplay.contains(moved.mascot) && moved.cursor == nil)
    }

    static func main() throws {
        let resultFixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: resultFixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resultFixture) }
        let report = resultFixture.appendingPathComponent("Отчёт (финал).pdf")
        let archive = resultFixture.appendingPathComponent("bundle.zip")
        let literal = resultFixture.appendingPathComponent("Готово на 100%20 #1.pdf")
        let encoded = resultFixture.appendingPathComponent("Снимок с пробелом.png")
        try Data("fixture".utf8).write(to: report)
        try Data("fixture".utf8).write(to: archive)
        try Data("fixture".utf8).write(to: literal)
        try Data("fixture".utf8).write(to: encoded)
        let hook = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop",
            "session_id": "00000000-0000-0000-0000-000000000001",
            "last_assistant_message": """
                [pdf](<\(report.path)>), [zip](\(archive.absoluteString)), [повтор](<\(report.path)>)
                [буквально](<\(literal.path)>), [URL](\(encoded.absoluteString))
                [строка](<\(report.path):12>), [папка](\(resultFixture.path)), [сайт](https://example.com/file.zip)
                [фрагмент](\(archive.absoluteString)#section), [параметр](\(archive.absoluteString)?view)
                """
        ])
        precondition(CodexHook.event(from: hook)?.files == [report.path, archive.path, literal.path, encoded.path])
        precondition(CodexResultFiles.paths(in: "[пропал](\(resultFixture.path)/missing.pdf)").isEmpty)
        let legacyHistory = try JSONEncoder().encode([report.path])
        var results = try JSONDecoder().decode(CodexResultFiles.History.self, from: legacyHistory)
        precondition(results.latestAvailableFiles().map(\.path) == [report.path])
        precondition(results.record([archive.path, literal.path, archive.path]))
        precondition(!results.record([]))
        precondition(!results.record([archive.path, literal.path]))
        let reloadedResults = try JSONDecoder().decode(CodexResultFiles.History.self, from: JSONEncoder().encode(results))
        precondition(reloadedResults.latestAvailableFiles().map(\.path) == [archive.path, literal.path])
        try FileManager.default.removeItem(at: archive)
        precondition(reloadedResults.latestAvailableFiles().map(\.path) == [literal.path])
        try FileManager.default.removeItem(at: literal)
        precondition(reloadedResults.latestAvailableFiles().map(\.path) == [report.path])
        print("PASS saved Codex file history falls back to the latest answer with available files")
        print("PASS Codex delivered files include local links with spaces, deduplicated and without source lines")
        testCursorChase()
        try testProjectFolder()
        testCompletionNudge()
        try testInboxAndMeeting()
        var pending: [CodexPendingRequest] = []
        let a = CodexPendingRequest(chat: "codex-thread-test-a", title: nil)
        let b = CodexPendingRequest(chat: "codex-thread-test-b", title: "Второй чат")
        CodexPendingRequest.register(a, in: &pending)
        CodexPendingRequest.register(b, in: &pending)
        CodexPendingRequest.register(b, in: &pending)
        CodexPendingRequest.resolve(nil, in: &pending)
        precondition(pending == [b, a])
        CodexPendingRequest.resolve(b.id, in: &pending)
        precondition(pending == [a])
        let screen = CGRect(x: -1470, y: 100, width: 1470, height: 956)
        let cutout = CGRect(x: -822, y: 1024, width: 174, height: 32)
        let geometry = NotchGeometry(screen: screen, cutout: cutout)
        precondition(geometry.mascot.minX == cutout.maxX + 9)
        precondition(geometry.cover.maxX < cutout.minX)
        precondition(abs(geometry.gazeRadius * 1.5 - 490) < 0.001)
        let physicalDrop = geometry.dropTarget(hasPhysicalNotch: true)
        precondition(physicalDrop.contains(cutout) && physicalDrop.minY == cutout.minY - 20)
        precondition(geometry.dropTarget(hasPhysicalNotch: false).maxY == cutout.minY)
        precondition(screen.contains(geometry.player))
        precondition(geometry.player.width == 500 && geometry.player.maxY == cutout.minY + 7)
        precondition(geometry.panel(width: NotchGeometry.compactPanelWidth, height: 125).size == CGSize(width: 420, height: 125))
        precondition(geometry.constrained(.zero, window: geometry.mascot.size).x == -37)
        let panel = geometry.player
        let near = PanelExitGrace.delay(at: CGPoint(x: panel.maxX + 2, y: panel.midY), panel: panel, notch: geometry.hover)
        let middle = PanelExitGrace.delay(at: CGPoint(x: panel.maxX + 100, y: panel.midY), panel: panel, notch: geometry.hover)
        let far = PanelExitGrace.delay(at: CGPoint(x: panel.maxX + 300, y: panel.midY), panel: panel, notch: geometry.hover)
        precondition(near > 0.9 && middle < near && middle > far && far == 0.04)
        let collapsed = CGRect(x: 0, y: 0, width: 182, height: 7)
        precondition(NotchSurface.path(in: collapsed, notchWidth: 174, scale: 1.25).boundingBoxOfPath == collapsed)
        precondition(PanelSwipe.commits(distance: -60, velocity: 0, sampleAge: 0.2))
        precondition(PanelSwipe.commits(distance: -30, velocity: -550, sampleAge: 0.03))
        precondition(!PanelSwipe.commits(distance: -30, velocity: 550, sampleAge: 0.03))
        precondition(!PanelSwipe.commits(distance: -30, velocity: -550, sampleAge: 0.15))
        precondition(PanelSwipe.progress(distance: 200, width: 400, hasNeighbor: false) < 0.05)
        precondition(PanelSwipe.progress(distance: -200, width: 400, hasNeighbor: true) == 0.5)

        let calendar = CalendarMonth.calendar
        let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        let month = CalendarMonth(containing: november)
        precondition(month.days.count == 42 && month.days.compactMap { $0 }.count == 30)
        precondition(month.days[5] == nil && month.days[6] == month.interval.start)
        precondition(month.days[25] == november)
        let movement = (0...100).map { MascotTravel.progress(at: Double($0) / 100) }
        precondition(movement.first == 0 && movement.last == 1 && movement[50] == 0.5)
        precondition(zip(movement, movement.dropFirst()).allSatisfy { $0 < $1 })
        precondition(movement[1] < 0.001 && movement[99] > 0.999)
        precondition(abs((movement[48] - movement[47]) - (movement[65] - movement[64])) < 0.00001)
        precondition((10...15).contains(Int((1 / QuickChatHop.duration).rounded())))
        let nearCursor = CGRect(x: 24, y: 12, width: 32, height: 32)
        precondition(QuickChatHop.destination(from: .zero, to: nearCursor) == nearCursor)
        let farCursor = CGRect(x: 600, y: 400, width: 32, height: 32)
        let firstHop = QuickChatHop.destination(from: .zero, to: farCursor)
        precondition(firstHop.minX < farCursor.minX && firstHop.minY < farCursor.minY)
        let reversedHop = QuickChatHop.destination(from: firstHop.origin, to: nearCursor)
        precondition(reversedHop.minX < firstHop.minX && reversedHop.minY < firstHop.minY)

        var decoder = NowPlayingDecoder()
        let initial = Data(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.lad.music","title":"Первый","durationMicros":120000000,"elapsedTimeMicros":60000000,"timestampEpochMicros":10000000,"playing":true,"artworkData":"YQ=="}}"#.utf8)
        let item = try decoder.ingest(initial, now: Date(timeIntervalSince1970: 12), observedAt: 100)
        precondition(item?.artwork == Data("a".utf8))
        precondition(item?.position(at: 105) == 67)
        let art = Data(#"{"type":"data","diff":true,"payload":{"artworkData":"Yg=="}}"#.utf8)
        let forward = try decoder.ingest(art, now: Date(timeIntervalSince1970: 3600), observedAt: 106)
        precondition(forward?.artwork == Data("b".utf8) && forward?.position(at: 106) == 68)
        let backward = try decoder.ingest(art, now: Date(timeIntervalSince1970: -3600), observedAt: 107)
        precondition(backward?.position(at: 107) == 69)
        let update = Data(#"{"type":"data","diff":true,"payload":{"playing":false,"artworkData":null}}"#.utf8)
        let paused = try decoder.ingest(update, observedAt: 108)
        precondition(paused?.title == "Первый" && paused?.playing == false && paused?.artwork == nil)
        precondition(paused?.position(at: 200) == 70)
        let resume = Data(#"{"type":"data","diff":true,"payload":{"playing":true}}"#.utf8)
        let playing = try decoder.ingest(resume, observedAt: 210)
        precondition(playing?.position(at: 213) == 73)
        let seek = Data(#"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":20000000}}"#.utf8)
        let sought = try decoder.ingest(seek, now: Date(timeIntervalSince1970: 3600), observedAt: 214)
        precondition(sought?.position(at: 216) == 22)
        let fullSeek = Data(#"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":30000000,"timestampEpochMicros":3599000000,"playbackRate":2}}"#.utf8)
        let soughtAtDoubleRate = try decoder.ingest(fullSeek, now: Date(timeIntervalSince1970: 3600), observedAt: 218)
        precondition(soughtAtDoubleRate?.position(at: 221) == 38)
        let rate = Data(#"{"type":"data","diff":true,"payload":{"playbackRate":1}}"#.utf8)
        let slowed = try decoder.ingest(rate, observedAt: 222)
        precondition(slowed?.position(at: 224) == 42)
        let cleared = try decoder.ingest(Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8))
        precondition(cleared == nil)

        var shelf = ShelfState()
        shelf.add([URL(fileURLWithPath: "/tmp/test"), URL(fileURLWithPath: "/tmp/test"), URL(string: "https://example.org")!])
        precondition(shelf.paths == ["/tmp/test"])
        shelf.remove(["/tmp/test"])
        precondition(shelf.paths.isEmpty)
        let batch = (0..<82).map { URL(fileURLWithPath: "/tmp/file-" + String($0)) }
        precondition(shelf.add(batch + batch) == 2 && shelf.paths == batch.prefix(80).map(\.path))
        precondition(shelf.add([batch[0], batch[0]]) == 0)
        let legacy = try JSONDecoder().decode(ShelfState.self, from: Data("""
            {"paths":["/tmp/alpha.txt","/tmp/Отчёт.pdf","/tmp/other.txt"]}
            """.utf8))
        var pinned = legacy
        precondition(legacy.pinnedPaths.isEmpty)
        precondition(pinned.setPinned(["/tmp/Отчёт.pdf"], pinned: true))
        precondition(pinned.displayedPaths().first == "/tmp/Отчёт.pdf")
        precondition(pinned.displayedPaths(matching: "отчёт") == ["/tmp/Отчёт.pdf"])
        let reloaded = try JSONDecoder().decode(ShelfState.self, from: JSONEncoder().encode(pinned))
        precondition(reloaded.pinnedPaths == pinned.pinnedPaths)
        pinned.remove(["/tmp/Отчёт.pdf"])
        precondition(pinned.pinnedPaths.isEmpty)
        precondition(!shelf.setPinned(Set(batch.prefix(5).map(\.path)), pinned: true))
        precondition(shelf.pinnedPaths.isEmpty)
        var orderedShelf = legacy
        let firstPin = "/tmp/Отчёт.pdf"
        let secondPin = "/tmp/alpha.txt"
        let newPin = "/tmp/other.txt"
        precondition(orderedShelf.setPinned([firstPin], pinned: true))
        precondition(orderedShelf.setPinned([secondPin], pinned: true))
        orderedShelf.remove([firstPin])
        precondition(orderedShelf.setPinned([newPin], pinned: true))
        precondition(orderedShelf.restore([(1, firstPin)], removedPins: [(0, firstPin)]))
        precondition(orderedShelf.pinnedPaths == [firstPin, secondPin, newPin])
        precondition(ActivityClock.compact(5999) == "99:59" && ActivityClock.compact(7200) == "2ч 0м")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("art")
        let alias = folder.appendingPathComponent("alias")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        precondition(ArtworkReader.local(alias) == Data([1, 2, 3]))
        var tracked = ShelfState()
        tracked.add([file])
        tracked.setPinned([file.path], pinned: true)
        tracked.updateReferences(in: [file.path])
        precondition(tracked.recordedPaths == [file.path])
        let references = tracked.references(for: [file.path])
        tracked.remove([file.path])
        precondition(tracked.recordedPaths.isEmpty)
        precondition(tracked.restore([(0, file.path)], removedPins: [(0, file.path)], references: references))
        let renamed = folder.appendingPathComponent("renamed-art")
        try FileManager.default.moveItem(at: file, to: renamed)
        tracked.updateReferences(in: [file.path])
        let movedPath = tracked.paths.first!
        precondition(URL(fileURLWithPath: movedPath).resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
        precondition(tracked.pinnedPaths == [movedPath] && tracked.recordedPaths == [movedPath])
        let upper = folder.appendingPathComponent("Case.txt")
        let lower = folder.appendingPathComponent("case.txt")
        try Data([42]).write(to: upper)
        var caseRename = ShelfState()
        caseRename.add([upper])
        caseRename.setPinned([upper.path], pinned: true)
        caseRename.updateReferences(in: [upper.path])
        try FileManager.default.moveItem(at: upper, to: lower)
        caseRename.updateReferences(in: [upper.path])
        precondition(caseRename.paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["case.txt"])
        precondition(caseRename.paths == caseRename.pinnedPaths, "Case-only rename keeps the pin")
        let trash = folder.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let trashed = trash.appendingPathComponent("renamed-art")
        try FileManager.default.moveItem(at: renamed, to: trashed)
        tracked.updateReferences(in: [movedPath])
        precondition(tracked.paths == [movedPath], "A shelf reference must not follow a file into Trash")
        try FileManager.default.moveItem(at: trashed, to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ArtworkReader.limit + 1))
        try handle.close()
        precondition(ArtworkReader.local(alias) == nil && ArtworkReader.local(folder) == nil)
        precondition(CleanLink.clean("https://example.org/?utm_source=foo&id=a%2Fb#clip") == "https://example.org/?id=a%2Fb#clip")
        precondition(CleanLink.clean("https://example.org/?sig=abc&utm_source=foo") == "https://example.org/?sig=abc&utm_source=foo")
        precondition(CleanLink.clean("file:///etc/passwd") == nil)
        let end = Date(timeIntervalSince1970: 1000)
        let focus = Countdown(end: end, phase: .focus)
        precondition(focus.next(after: end.addingTimeInterval(-50)) == nil)
        precondition(focus.next(after: end.addingTimeInterval(50))?.end == end.addingTimeInterval(300))
        precondition(focus.next(after: end.addingTimeInterval(350)) == nil)
        let boot = UUID()
        func stopwatchTime(_ wallOffset: TimeInterval, _ continuous: TimeInterval, bootSession: UUID = boot) -> Stopwatch.Instant {
            .init(wallTime: end.addingTimeInterval(wallOffset), continuousSeconds: continuous, bootSession: bootSession)
        }
        var stopwatch = Stopwatch()
        stopwatch.toggle(at: stopwatchTime(0, 120))
        precondition(stopwatch.seconds(at: stopwatchTime(-3600, 125)) == 5)
        precondition(stopwatch.seconds(at: stopwatchTime(3600, 130)) == 10)
        stopwatch.toggle(at: stopwatchTime(3600, 131))
        precondition(!stopwatch.isRunning && stopwatch.elapsed == 11)
        stopwatch.toggle(at: stopwatchTime(30, 150))
        let stopwatchBytes = try JSONEncoder().encode(stopwatch)
        var restarted = try JSONDecoder().decode(Stopwatch.self, from: stopwatchBytes)
        precondition(!restarted.migrateClock(at: stopwatchTime(-3600, 153)))
        precondition(restarted.seconds(at: stopwatchTime(-3600, 153)) == 14)
        let nextBoot = UUID()
        precondition(restarted.migrateClock(at: stopwatchTime(50, 3, bootSession: nextBoot)))
        precondition(restarted.seconds(at: stopwatchTime(-3600, 8, bootSession: nextBoot)) == 36)
        var legacyStopwatch = try JSONDecoder().decode(Stopwatch.self, from: Data("""
            {"started":\(end.timeIntervalSinceReferenceDate),"elapsed":2}
            """.utf8))
        precondition(legacyStopwatch.migrateClock(at: stopwatchTime(10, 200)))
        precondition(legacyStopwatch.seconds(at: stopwatchTime(3600, 201)) == 13)
        let timer = Countdown(end: end.addingTimeInterval(60), phase: .timer)
        let pausedTimer = timer.togglingPause(at: end.addingTimeInterval(15))!
        precondition(pausedTimer.isPaused && pausedTimer.remaining(at: end.addingTimeInterval(200)) == 45)
        let resumed = pausedTimer.togglingPause(at: end.addingTimeInterval(200))!
        precondition(!resumed.isPaused && resumed.end == end.addingTimeInterval(245))
        let oldTimer = try JSONDecoder().decode(Countdown.self, from: Data(#"{"end":0,"phase":"timer"}"#.utf8))
        precondition(!oldTimer.isPaused)
        precondition(PanelOpening.page(last: .shelf, preferred: .quick, dismissedAt: 10, now: 34) == .shelf)
        precondition(PanelOpening.page(last: .shelf, preferred: .quick, dismissedAt: 10, now: 35) == .quick)
        precondition(PanelOpening.page(last: .shelf, preferred: .calendar, dismissedAt: nil, now: 35) == .calendar)
        var restoredShelf = ShelfState()
        restoredShelf.add(batch.prefix(3).map { $0 })
        restoredShelf.remove([batch[0].path, batch[2].path])
        restoredShelf.add([batch[3]])
        precondition(restoredShelf.restore([(0, batch[0].path), (2, batch[2].path)]))
        precondition(restoredShelf.paths == batch.prefix(4).map(\.path))
        precondition(!shelf.restore([(0, "/tmp/capacity-test")]))
        let suite = "local.kirill.chubzik.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "gazeEnabled")
        defaults.set(false, forKey: "systemMedia")
        let preferences = ChubzikPreferences(defaults: defaults)
        precondition(preferences.completionMode == .soft)
        preferences.completionMode = .high
        precondition(preferences.opensOnHover && preferences.followsCodexRequests)
        precondition(!preferences.followsPointer && !preferences.readsSystemMedia)
        var systemMediaChange: Bool?
        preferences.onSystemMediaChange = { systemMediaChange = $0 }
        preferences.startPage = .calendar
        preferences.opensOnHover = false
        preferences.followsCodexRequests = false
        preferences.followsPointer = true
        preferences.readsSystemMedia = true
        let reopened = ChubzikPreferences(defaults: defaults)
        precondition(reopened.completionMode == .high)
        precondition(reopened.startPage == .calendar)
        precondition(!reopened.opensOnHover && !reopened.followsCodexRequests)
        precondition(reopened.followsPointer && reopened.readsSystemMedia && systemMediaChange == true)
        print("Geometry, media deltas, shelf, URL cleaning, Pomodoro and stopwatch passed")
    }

    private static func testInboxAndMeeting() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let meeting = CalendarEntry(id: "meeting", title: "Test", start: start, end: start.addingTimeInterval(1800),
                                    allDay: false, link: URL(string: "https://example.com/meeting"))
        let early = MeetingAlert.plan(for: [meeting], at: start.addingTimeInterval(-301), excluding: [])
        precondition(early.current.isEmpty && early.nextChange == start.addingTimeInterval(-300))
        let active = MeetingAlert.plan(for: [meeting], at: start.addingTimeInterval(-300), excluding: [])
        precondition(active.current.map(\.entry.id) == [meeting.id] && active.nextChange == start.addingTimeInterval(300))
        let joinedFirst = MeetingAlert(meeting)!.joinKey
        precondition(MeetingAlert.plan(for: [meeting], at: start, excluding: [joinedFirst]).current.isEmpty)
        var corrected = meeting
        let zoom = URL(string: "https://zoom.us/j/1234")!
        corrected.link = zoom
        precondition(MeetingAlert.plan(for: [corrected], at: start, excluding: [joinedFirst]).current.first?.link == zoom)
        let moved = CalendarEntry(id: meeting.id, title: meeting.title, start: start.addingTimeInterval(120),
                                  end: meeting.end, allDay: false, link: meeting.link)
        precondition(MeetingAlert.plan(for: [moved], at: start, excluding: [joinedFirst]).current.first?.entry.start == moved.start)
        precondition(MeetingAlert.plan(for: [meeting], at: start.addingTimeInterval(300), excluding: []).current.isEmpty)
        let later = CalendarEntry(id: "later", title: "Later", start: start.addingTimeInterval(120),
                                  end: start.addingTimeInterval(180), allDay: false, link: meeting.link)
        let beforeOverlap = MeetingAlert.plan(for: [later, meeting], at: start.addingTimeInterval(-200), excluding: [])
        precondition(beforeOverlap.current.map(\.entry.id) == [meeting.id])
        precondition(beforeOverlap.nextChange == start.addingTimeInterval(-180))
        let overlap = MeetingAlert.plan(for: [later, meeting], at: start, excluding: [])
        precondition(overlap.current.map(\.entry.id) == [meeting.id, later.id])
        precondition(overlap.nextChange == later.end)
        let afterJoining = MeetingAlert.plan(for: [later, meeting], at: start, excluding: [MeetingAlert(later)!.joinKey])
        precondition(afterJoining.current.map(\.entry.id) == [meeting.id])
        let allDay = CalendarEntry(id: "holiday", title: "Test", start: start, end: start.addingTimeInterval(1800),
                                   allDay: true, link: meeting.link)
        precondition(MeetingAlert(allDay) == nil)
        let store = EKEventStore()
        let calendarEvent = EKEvent(eventStore: store)
        let detailsPage = URL(string: "https://calendar.google.com/calendar/event")!
        calendarEvent.url = detailsPage
        calendarEvent.notes = "Join: " + zoom.absoluteString
        precondition(CalendarFeed.meetingLink(for: calendarEvent) == zoom)
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        calendarEvent.location = meet.absoluteString
        precondition(CalendarFeed.meetingLink(for: calendarEvent) == meet)
        calendarEvent.location = nil
        calendarEvent.notes = "Documentation: https://zoom.us.example.org/about"
        precondition(CalendarFeed.meetingLink(for: calendarEvent) == detailsPage)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let previous = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", home.path, 1)
        defer {
            if let previous { setenv("CODEX_HOME", previous, 1) }
            else { unsetenv("CODEX_HOME") }
        }
        let chat = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let event = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "session_id": chat])
        precondition(CodexHook.event(from: event)?.title == nil)
        let lines = """
        {"id":"\(chat)","thread_name":"Старое имя"}
        {"id":"\(chat)","thread_name":"Новое имя"}
        """
        try lines.write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        precondition(CodexHook.event(from: event)?.title == "Новое имя")
        precondition(CodexHook.uniqueThreadTitle(chat) == "Новое имя")
        let duplicate = lines + "\n{\"id\":\"other\",\"thread_name\":\"Новое  имя\"}"
        try duplicate.write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        precondition(CodexHook.uniqueThreadTitle(chat) == nil, "Duplicate titles cannot confirm a chat")
        let olderLine = "{\"id\":\"earlier\",\"thread_name\":\"Unrelated dialogue\"}\n"
        let history = String(repeating: olderLine, count: (4 * 1024 * 1024) / olderLine.utf8.count + 1)
        let index = home.appendingPathComponent("session_index.jsonl")
        try (history + lines).write(to: index, atomically: true, encoding: .utf8)
        precondition(CodexHook.uniqueThreadTitle(chat) == "Новое имя", "A large index must still confirm a unique title")
        let olderDuplicate = "{\"id\":\"different\",\"thread_name\":\"Новое имя\"}\n"
        try (olderDuplicate + history + lines).write(to: index, atomically: true, encoding: .utf8)
        precondition(CodexHook.uniqueThreadTitle(chat) == nil, "A duplicate at the beginning must still block confirmation")
        print("PASS inbox thread titles and five-minute meeting boundaries")
    }
}
