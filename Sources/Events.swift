import Foundation
import Darwin

struct IslandEvent: Codable {
    var type: String
    var source: String?
    var id: String?
    var title: String?
    var artist: String?
    var playing: Bool?
    var duration: Double?
    var elapsed: Double?
    var rate: Double?
    var artwork: String?
    var capabilities: [String]?
    var path: String?
    var action: String?
    var position: Double?
    var chat: String?
    var files: [String]?

    var media: MediaItem? {
        guard type == "media", let source, let title, !title.isEmpty else { return nil }
        let cover = artwork.flatMap { value -> URL? in
            let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value)
            guard let url else { return nil }
            let localHTTP = url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
            guard url.isFileURL || url.scheme == "https" || localHTTP else { return nil }
            return url
        }
        return MediaItem(source: source, parentSource: nil, id: id ?? title, title: title, artist: artist ?? "",
                         playing: playing ?? false, duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                         elapsed: elapsed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                         timestamp: Date(), rate: min(4, max(0, rate ?? 1)), artwork: nil, artworkURL: cover,
                         capabilities: capabilities.map(Set.init))
    }
}

enum IslandEvents {
    static let payloadLimit = 16_384
    static let inbound = Notification.Name("local.kirill.chubzik.event")
    static let outbound = Notification.Name("local.kirill.chubzik.command")

    static func post(_ event: IslandEvent, to name: Notification.Name = inbound) {
        guard let data = try? JSONEncoder().encode(event), data.count <= payloadLimit,
              let payload = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(name, object: payload, userInfo: nil, deliverImmediately: true)
    }

    static func decode(_ notification: Notification) -> IslandEvent? {
        guard let string = notification.object as? String, string.utf8.count <= payloadLimit else { return nil }
        return try? JSONDecoder().decode(IslandEvent.self, from: Data(string.utf8))
    }
}

enum LocalSettings {
    static let directory: URL = {
        if let testDirectory = ProcessInfo.processInfo.environment["CHUBZIK_DATA_DIR"] {
            return URL(fileURLWithPath: testDirectory, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chubzik", isDirectory: true)
    }()

    static func load<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult static func save<Value: Encodable>(_ value: Value, as name: String) -> Bool {
        guard let bytes = try? JSONEncoder().encode(value) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            NSLog("Чубзик: не удалось сохранить %@", name)
            return false
        }
    }
}

enum CodexHook {
    static func event(from bytes: Data) -> IslandEvent? {
        guard bytes.count <= 1_000_000,
              let payload = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let name = payload["hook_event_name"] as? String else { return nil }
        let chat = (payload["session_id"] as? String).flatMap { value in
            value.range(of: "^[A-Za-z0-9-]{16,80}$", options: .regularExpression) == nil ? nil : value
        }
        let type: String
        switch name {
        case "UserPromptSubmit": type = "work"
        case "PermissionRequest": type = "ask"
        case "Stop":
            if payload["stop_hook_active"] as? Bool == true { return nil }
            type = "done"
        case "SessionEnd", "Interrupt": type = "clear"
        default: return nil
        }
        let title = chat.flatMap { type == "ask" || type == "done" ? threadTitle($0) : nil }
        let files = type == "done" ? CodexResultFiles.paths(in: payload["last_assistant_message"] as? String ?? "") : []
        return IslandEvent(type: type, source: "codex-hook", title: title, chat: chat, files: files.isEmpty ? nil : files)
    }

    private struct ThreadName: Decodable {
        let id: String
        let threadName: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }

    private static var sessionIndex: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("session_index.jsonl")
    }

    private static func threadTitle(_ chat: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: sessionIndex) else { return nil }
        defer { try? handle.close() }
        let limit = UInt64(1024 * 1024)
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size > limit ? size - limit : 0)) != nil,
              let bytes = try? handle.read(upToCount: Int(limit)) else { return nil }
        let decoder = JSONDecoder()
        for line in bytes.split(separator: 10).reversed() {
            guard let record = try? decoder.decode(ThreadName.self, from: Data(line)),
                  record.id == chat else { continue }
            let name = normalizedThreadTitle(record.threadName)
            return name.isEmpty ? nil : String(name.prefix(80))
        }
        return nil
    }

    static func normalizedThreadTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func uniqueThreadTitle(_ chat: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: sessionIndex) else { return nil }
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        var names: [String: String] = [:]
        func indexLine(_ line: Data) {
            guard !line.isEmpty, let item = try? decoder.decode(ThreadName.self, from: line) else { return }
            names[item.id] = normalizedThreadTitle(item.threadName)
        }
        var pending = Data()
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard !Task.isCancelled else { return nil }
                pending.append(chunk)
                guard let boundary = pending.lastIndex(of: 10) else { continue }
                for line in pending[..<boundary].split(separator: 10) { indexLine(Data(line)) }
                pending = Data(pending[pending.index(after: boundary)...])
            }
        } catch {
            return nil
        }
        indexLine(pending)
        guard !Task.isCancelled else { return nil }
        guard let name = names[chat], !name.isEmpty,
              !names.contains(where: { $0.key != chat && $0.value == name }) else { return nil }
        return name
    }
}

enum CodexResultFiles {
    struct History: Codable {
        private static let answersLimit = 12
        private static let filesLimit = 12
        private var answers: [[String]] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Older releases saved just the files from the last answer.
            let saved: [[String]]
            if let previous = try? container.decode([String].self) {
                saved = [previous]
            } else {
                saved = try container.decode([[String]].self)
            }
            answers = saved.filter { !$0.isEmpty }.prefix(Self.answersLimit).map { Array($0.prefix(Self.filesLimit)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(answers)
        }

        @discardableResult mutating func record(_ paths: [String]) -> Bool {
            var seen = Set<String>()
            var answer: [String] = []
            for path in paths {
                guard let file = CodexResultFiles.localFile(at: path), seen.insert(file.path).inserted else { continue }
                answer.append(file.path)
                if answer.count == Self.filesLimit { break }
            }
            guard !answer.isEmpty, answer != answers.first else { return false }
            answers.removeAll { $0 == answer }
            answers.insert(answer, at: 0)
            answers = Array(answers.prefix(Self.answersLimit))
            return true
        }

        func latestAvailableFiles() -> [URL] {
            for answer in answers {
                let existing = answer.compactMap(CodexResultFiles.localFile)
                if !existing.isEmpty { return existing }
            }
            return []
        }
    }

    // Codex links may wrap paths containing spaces in angle brackets or percent-encode them.
    private static let links = try! NSRegularExpression(
        pattern: #"\]\(\s*(?:<([^>\r\n]+)>|((?:[^()\r\n]|\([^()\r\n]*\))+))\s*\)"#
    )

    static func paths(in message: String) -> [String] {
        let text = String(message.prefix(64_000))
        let range = NSRange(text.startIndex..., in: text)
        var result: [String] = []
        var seen = Set<String>()
        var remaining = 7_500
        for match in links.matches(in: text, range: range) {
            let group = match.range(at: 1).location == NSNotFound ? 2 : 1
            guard let range = Range(match.range(at: group), in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: .whitespaces)
            let local = value.hasPrefix("sandbox:/") ? String(value.dropFirst("sandbox:".count)) : value
            let candidate: URL?
            if local.hasPrefix("/") {
                guard !local.hasPrefix("//"),
                      local.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) == nil else { continue }
                // The desktop renderer also emits literal filesystem paths, including '%' and '#'.
                candidate = localFile(at: local) ?? local.removingPercentEncoding.flatMap {
                    $0 != local ? localFile(at: $0) : nil
                }
            } else if let file = URL(string: local), file.isFileURL, file.fragment == nil, file.query == nil,
                      file.host == nil || file.host == "" || file.host == "localhost" {
                candidate = localFile(at: file.path)
            } else {
                continue
            }
            guard let path = candidate?.path else { continue }
            let cost = path.utf8.count + 16
            guard cost <= remaining, !seen.contains(path) else { continue }
            seen.insert(path)
            remaining -= cost
            result.append(path)
            if result.count == 12 { break }
        }
        return result
    }

    static func localFile(at path: String) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = file.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true else { return nil }
        return file
    }
}
