import AppKit
import Foundation

final class ArDiaVideoPlayback {
    static let bundleID = "com.kiridey.ardia.personal"
    private static let port = 9222
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.40
        config.timeoutIntervalForResource = 0.80
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: LocalOnly(), delegateQueue: nil)
    }()

    private final class LocalOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    struct Target {
        fileprivate let client: Client
        fileprivate let object: String
        fileprivate let inline: Bool
        let point: CGPoint
        var isPictureInPicture: Bool { !inline }
    }

    private struct Page: Decodable {
        let type: String
        let url: URL?
        let webSocketDebuggerUrl: URL?

        var socket: URL? {
            guard type == "page", let url, ["http", "https"].contains(url.scheme ?? ""),
                  let socket = webSocketDebuggerUrl, socket.scheme == "ws",
                  socket.host == "127.0.0.1", socket.port == ArDiaVideoPlayback.port,
                  socket.path.hasPrefix("/devtools/page/"), socket.user == nil, socket.query == nil
            else { return nil }
            return socket
        }
    }

    private struct Candidate {
        let client: Client
        let object: String
        let mode: String
        let focused: Bool
        let pipStopped: Bool
        let quartzPoint: CGPoint
    }

    fileprivate final class Client {
        private let socket: URLSessionWebSocketTask

        init(session: URLSession, url: URL) {
            socket = session.webSocketTask(with: url)
            socket.resume()
        }

        deinit { socket.cancel(with: .goingAway, reason: nil) }

        func send(_ method: String, params: [String: Any], id: Int) async throws -> [String: Any] {
            let request: [String: Any] = ["id": id, "method": method, "params": params]
            let data = try JSONSerialization.data(withJSONObject: request)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            while true {
                let incoming = try await socket.receive()
                guard case .string(let raw) = incoming,
                      let reply = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      reply["id"] as? Int == id else { continue }
                return reply["result"] as? [String: Any] ?? [:]
            }
        }

        func cancel() { socket.cancel(with: .goingAway, reason: nil) }
    }

    static var isAvailable: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID }

    func find(on screen: CGRect, completion: @escaping (VideoProbe<Target>) -> Void) {
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .filter { !$0.isTerminated }
        guard processes.count == 1, let top = NSScreen.screens.first?.frame.maxY else {
            completion(processes.isEmpty ? .inactive : .unavailable)
            return
        }
        let inline = isFrontmost
        guard inline || Self.pictureInPicturePoint(top: top) != nil else {
            completion(.inactive)
            return
        }
        Task {
            let candidates = await findCandidates(inline: inline)
            await MainActor.run {
                completion(self.select(candidates, screen: screen, top: top))
            }
        }
    }

    private func findCandidates(inline: Bool) async -> [Candidate] {
        guard let endpoint = URL(string: "http://127.0.0.1:\(Self.port)/json/list"),
              let (data, response) = try? await session.data(from: endpoint),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000,
              let pages = try? JSONDecoder().decode([Page].self, from: data)
        else { return [] }
        let urls = pages.compactMap(\.socket)
        guard urls.count <= 80 else { return [] }
        return await withTaskGroup(of: Candidate?.self) { group in
            for url in urls { group.addTask { await self.probe(url, inline: inline) } }
            var candidates: [Candidate] = []
            for await result in group {
                if let result { candidates.append(result) }
            }
            return candidates
        }
    }

    private func probe(_ url: URL, inline: Bool) async -> Candidate? {
        let client = Client(session: session, url: url)
        let timeout = DispatchWorkItem { [weak client] in client?.cancel() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.38, execute: timeout)
        defer { timeout.cancel() }

        let expression = ArDiaVideoScript.probe(inline: inline)
        guard let reply = try? await client.send("Runtime.evaluate", params: [
            "expression": expression, "silent": true, "returnByValue": false
        ], id: 1), let object = (reply["result"] as? [String: Any])?["objectId"] as? String,
              let details = try? await client.send("Runtime.callFunctionOn", params: [
                "objectId": object,
                "functionDeclaration": "function(){ return {mode:this.mode, focused:this.focused, pipStopped:this.pipStopped, x:this.x, y:this.y} }",
                "returnByValue": true, "silent": true
              ], id: 2),
              let values = (details["result"] as? [String: Any])?["value"] as? [String: Any],
              let mode = values["mode"] as? String
        else { return nil }
        let point = CGPoint(x: values["x"] as? Double ?? 0, y: values["y"] as? Double ?? 0)
        return Candidate(client: client, object: object, mode: mode, focused: values["focused"] as? Bool == true,
                         pipStopped: mode == "pipStopped" || values["pipStopped"] as? Bool == true, quartzPoint: point)
    }

    private func select(_ candidates: [Candidate], screen: CGRect, top: CGFloat) -> VideoProbe<Target> {
        let inline = candidates.filter { $0.mode == "inline" }
        let focused = inline.filter(\.focused)
        let pip = candidates.filter { $0.mode == "pip" }
        let pipPoint = Self.pictureInPicturePoint(top: top)
        let pipIsStopped = candidates.filter(\.pipStopped).count == 1
        if candidates.contains(where: { $0.mode == "uncertain" && ($0.focused || focused.isEmpty) }) { return .uncertain }
        if focused.count > 1 { return .uncertain }
        if let candidate = focused.first, isFrontmost {
            guard pip.isEmpty, pipPoint == nil || pipIsStopped else { return .uncertain }
            let point = CGPoint(x: candidate.quartzPoint.x, y: top - candidate.quartzPoint.y)
            if screen.contains(point) {
                return .playing(Target(client: candidate.client, object: candidate.object, inline: true, point: point))
            }
            return .uncertain
        }
        if !pip.isEmpty {
            guard pip.count == 1, let candidate = pip.first, let point = pipPoint,
                  screen.contains(point) else { return .uncertain }
            return .playing(Target(client: candidate.client, object: candidate.object, inline: false, point: point))
        }
        if pipPoint != nil && !pipIsStopped { return .unavailable }
        if isFrontmost {
            guard inline.isEmpty, candidates.contains(where: { $0.focused && ["inactive", "pipStopped"].contains($0.mode) })
            else { return .unavailable }
        }
        return candidates.isEmpty ? .unavailable : .inactive
    }

    func pause(_ target: Target, retainForResume: Bool = false, shouldPress: @escaping () -> Bool,
               completion: @escaping (VideoPause) -> Void) {
        guard !target.inline || isFrontmost else {
            completion(.unconfirmed)
            return
        }
        if !target.inline {
            guard let top = NSScreen.screens.first?.frame.maxY, let point = Self.pictureInPicturePoint(top: top),
                  hypot(point.x - target.point.x, point.y - target.point.y) < 12 else {
                completion(.unconfirmed)
                return
            }
        }
        guard shouldPress() else {
            completion(.unconfirmed)
            return
        }
        let script = ArDiaVideoScript.pause(retainForResume: retainForResume)
        Task {
            let timeout = DispatchWorkItem { target.client.cancel() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.35, execute: timeout)
            let reply = try? await target.client.send("Runtime.callFunctionOn", params: [
                "objectId": target.object, "functionDeclaration": script, "returnByValue": true, "silent": true
            ], id: 3)
            timeout.cancel()
            let raw = (reply?["result"] as? [String: Any])?["value"] as? String
            let result = raw.flatMap(VideoPause.init(rawValue:)) ?? .attempted
            if result != .paused || !retainForResume { target.client.cancel() }
            await MainActor.run { completion(result) }
        }
    }

    func resume(_ target: Target, shouldResume: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        if target.isPictureInPicture {
            guard let top = NSScreen.screens.first?.frame.maxY, Self.pictureInPicturePoint(top: top) != nil else {
                completion(false)
                return
            }
        }
        guard shouldResume() else { completion(false); return }
        Task {
            let timeout = DispatchWorkItem { target.client.cancel() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.1, execute: timeout)
            defer { timeout.cancel(); target.client.cancel() }
            let reply = try? await target.client.send("Runtime.callFunctionOn", params: [
                "objectId": target.object, "functionDeclaration": ArDiaVideoScript.resume,
                "returnByValue": true, "awaitPromise": true, "silent": true
            ], id: 4)
            let started = (reply?["result"] as? [String: Any])?["value"] as? Bool == true
            if started, target.inline, await MainActor.run(resultType: Bool.self, body: { shouldResume() }) {
                let front = try? await target.client.send("Page.bringToFront", params: [:], id: 5)
                if front != nil {
                    await MainActor.run {
                        if shouldResume() {
                            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
                                .first { !$0.isTerminated }?.activate()
                        }
                    }
                }
            }
            await MainActor.run { completion(started) }
        }
    }

    static func pictureInPicturePoint(top: CGFloat, owner: pid_t? = nil) -> CGPoint? {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let frames = windows.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid), owner == nil || pid == owner,
                  let layer = info[kCGWindowLayer as String] as? Int, layer > 0,
                  let title = info[kCGWindowName as String] as? String,
                  ["picture in picture", "картинка в картинке"].contains(
                    title.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")),
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return rect
        }
        guard frames.count == 1, let frame = frames.first else { return nil }
        return CGPoint(x: frame.midX, y: top - frame.midY)
    }
}

enum ArDiaVideoScript {
    static func probe(inline: Bool, inspectPiP: Bool = true) -> String {
        return """
        (() => {
            const playing = video => video?.localName === 'video' && !video.paused && !video.ended;
            let remainingPiPFrames = 32;
            function findPiP(doc, frames) {
                const video = doc.pictureInPictureElement;
                if (video?.localName === 'video') return { video, frames };
                if (!\(inspectPiP)) return null;
                for (const frame of doc.querySelectorAll('iframe')) {
                    if (--remainingPiPFrames < 0) return null;
                    const child = frame.contentDocument;
                    if (!child?.defaultView) continue;
                    const result = findPiP(child, [...frames, { frame, child, url: child.URL }]);
                    if (result) return result;
                }
                return null;
            }
            const pip = findPiP(document, []);
            const playingPiP = playing(pip?.video) ? { ...pip, mode: 'pip', source: pip.video.currentSrc,
                stream: pip.video.srcObject, location: location.href } : null;
            if (!\(inline) || document.visibilityState !== 'visible') {
                return playingPiP ?? (pip ? { mode: 'pipStopped' } : null);
            }
            const bounds = element => {
                const view = element.ownerDocument.defaultView;
                if (!view) return null;
                const r = element.getBoundingClientRect(), css = view.getComputedStyle(element);
                if (r.width < 100 || r.height < 80 || css.visibility !== 'visible') return null;
                return r;
            };
            const intersect = (a, b) => {
                const left = Math.max(a.left, b.left), top = Math.max(a.top, b.top);
                const right = Math.min(a.right, b.right), bottom = Math.min(a.bottom, b.bottom);
                return right > left && bottom > top ? { left, top, right, bottom } : null;
            };
            const candidates = [];
            let inspectedFrames = 0;
            let unresolved = false;
            function inspect(doc, frames, clip, screenRect) {
                for (const video of doc.querySelectorAll('video')) {
                    if (video === pip?.video || !playing(video)) continue;
                    const r = bounds(video), shown = r && intersect(r, clip);
                    if (shown) candidates.push({ video, frames, shown: screenRect(shown) });
                    if (candidates.length > 1) return;
                }
                for (const frame of doc.querySelectorAll('iframe')) {
                    const r = bounds(frame);
                    if (!r || !intersect(r, clip)) continue;
                    if (++inspectedFrames > 32) { unresolved = true; return; }
                    const child = frame.contentDocument;
                    if (!child?.defaultView || !frame.offsetWidth || !frame.offsetHeight) { unresolved = true; continue; }
                    const sx = r.width / frame.offsetWidth, sy = r.height / frame.offsetHeight;
                    const x = r.left + frame.clientLeft * sx, y = r.top + frame.clientTop * sy;
                    const view = child.defaultView;
                    const childClip = intersect({ left: 0, top: 0, right: view.innerWidth, bottom: view.innerHeight }, {
                        left: (clip.left - x) / sx, top: (clip.top - y) / sy,
                        right: (clip.right - x) / sx, bottom: (clip.bottom - y) / sy
                    });
                    if (childClip) inspect(child, [...frames, { frame, child, url: child.URL }], childClip, box => screenRect({
                        left: x + box.left * sx, top: y + box.top * sy, right: x + box.right * sx, bottom: y + box.bottom * sy
                    }));
                    if (candidates.length > 1) return;
                }
            }
            inspect(document, [], { left: 0, top: 0, right: innerWidth, bottom: innerHeight }, box => box);
            const focused = document.hasFocus();
            if (candidates.length > 1 || (playingPiP && candidates.length !== 0)) return { mode: 'uncertain', focused };
            if (playingPiP) return playingPiP;
            if (candidates.length === 0) {
                return { mode: unresolved ? 'uncertain' : pip ? 'pipStopped' : 'inactive', focused };
            }
            const { video, frames, shown } = candidates[0];
            return { video, frames, focused, mode: 'inline', pipStopped: Boolean(pip), source: video.currentSrc, stream: video.srcObject,
                location: location.href,
                x: screenX + Math.max(0, outerWidth - innerWidth) + (shown.left + shown.right) / 2,
                y: screenY + Math.max(0, outerHeight - innerHeight) + (shown.top + shown.bottom) / 2 };
        })()
        """
    }

    static func pause(retainForResume: Bool) -> String { """
        function() {
            const video = this.video;
            if (!video?.isConnected || video.currentSrc !== this.source || video.srcObject !== this.stream ||
                location.href !== this.location) return 'unconfirmed';
            if (this.mode === 'pip' ? video.ownerDocument.pictureInPictureElement !== video :
                document.visibilityState !== 'visible' || (this.focused && !document.hasFocus())) return 'unconfirmed';
            if (this.frames?.some(({ frame, child, url }) => !frame.isConnected || frame.contentDocument !== child || child.URL !== url)) {
                return 'unconfirmed';
            }
            if (video.paused || video.ended) return 'alreadyStopped';
            video.pause();
            if (video.paused && \(retainForResume)) {
                this.pausedAt = video.currentTime;
                this.until = Date.now() + 480000;
                const controller = new AbortController();
                const invalidate = () => { this.pausedAt = null; this.stopWatching(); };
                const timer = setTimeout(invalidate, 480000);
                this.stopWatching = () => {
                    controller.abort();
                    clearTimeout(timer);
                    this.stopWatching = null;
                };
                for (const name of ['play', 'seeking', 'emptied', 'loadstart', 'leavepictureinpicture']) {
                    video.addEventListener(name, invalidate, { once: true, signal: controller.signal });
                }
            }
            return video.paused ? 'paused' : 'attempted';
        }
        """ }

    static let resume = """
        async function() {
            const video = this.video, time = this.pausedAt;
            this.pausedAt = null;
            this.stopWatching?.();
            if (!Number.isFinite(time) || Date.now() > this.until || !video?.isConnected || !video.paused ||
                video.ended || video.error || video.currentSrc !== this.source || video.srcObject !== this.stream ||
                location.href !== this.location ||
                Math.abs(video.currentTime - time) > 0.45 ||
                (this.mode === 'pip' && video.ownerDocument.pictureInPictureElement !== video) ||
                this.frames?.some(({ frame, child, url }) => !frame.isConnected ||
                    frame.contentDocument !== child || child.URL !== url)) return false;
            try { await video.play(); return !video.paused; } catch { return false; }
        }
        """
}
