import Foundation
import CoreGraphics

@main struct QuickChatTests {
    private static func write(_ message: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: message)
        FileHandle.standardOutput.write(bytes + Data([10]))
    }

    private static func mockServer() {
        let accountFile = ProcessInfo.processInfo.environment["CHUBZIK_TEST_ACCOUNT"]!
        let login = try! String(contentsOfFile: accountFile, encoding: .utf8)
        var previousTurnRequest: Int?
        let isTransfer = CommandLine.arguments.dropFirst().first == "--disable"
        let transferID = "01234567-89ab-cdef-0123-456789abcdef"
        var didInject = false
        func notification(_ method: String, _ params: [String: Any]) {
            write(["method": method, "params": params])
        }
        while let line = readLine(), let bytes = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            guard let id = message["id"] as? Int else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            var result: [String: Any] = [:]
            switch message["method"] as? String {
            case "initialize" where isTransfer:
                precondition((params["capabilities"] as? [String: Bool])?["experimentalApi"] == true)
            case "account/read":
                let account: Any = login.isEmpty ? NSNull() : ["type": "chatgpt", "email": login]
                result["account"] = account
            case "thread/start":
                precondition(!isTransfer && params["ephemeral"] as? Bool == true)
                result["thread"] = ["id": "test-thread"]
            case "thread/fork":
                precondition(isTransfer && params["ephemeral"] as? Bool == false)
                precondition(params["baseInstructions"] == nil && params["sandbox"] == nil && params["approvalPolicy"] == nil)
                precondition(params["cwd"] as? String == FileManager.default.temporaryDirectory.path)
                let file = URL(fileURLWithPath: params["path"] as! String)
                let text = try! String(contentsOf: file, encoding: .utf8)
                let events = text.split(separator: "\n").compactMap { line -> [String: Any]? in
                    let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    guard row?["type"] as? String == "event_msg" else { return nil }
                    return row?["payload"] as? [String: Any]
                }
                precondition(events.compactMap { $0["type"] as? String } == ["task_started", "user_message", "agent_message", "task_complete"])
                precondition(events[1]["message"] as? String == "Ранее")
                precondition((events[1]["images"] as? [String])?.first?.hasPrefix("data:image/jpeg;base64,") == true)
                result["thread"] = ["id": transferID]
            case "thread/turns/list":
                precondition(isTransfer && params["threadId"] as? String == transferID)
                result["data"] = [["status": "completed", "items": [["type": "userMessage"], ["type": "agentMessage"]]]]
            case "thread/inject_items":
                precondition(isTransfer && params["threadId"] as? String == transferID)
                let items = params["items"] as! [[String: Any]]
                precondition(items.compactMap { $0["role"] as? String } == ["user"])
                let content = items.last?["content"] as! [[String: Any]]
                precondition(content.contains { ($0["text"] as? String)?.contains("Текст с экрана") == true })
                precondition(!content.contains { ($0["text"] as? String)?.contains("Уточнение") == true },
                             "An editable unsent draft must stay out of the stored model history")
                didInject = true
            case "thread/name/set":
                precondition(isTransfer && didInject && params["name"] as? String == "Уточнение & C++?")
            case "turn/start":
                precondition(!isTransfer, "Transfer must not send a model request")
                precondition(params["model"] as? String == "gpt-6-luna" && params["effort"] as? String == "high")
                let input = params["input"] as! [[String: Any]]
                let text = input[0]["text"] as! String
                if text == "Сервер запросил ввод" {
                    write(["id": 5, "method": "item/tool/requestUserInput", "params": [:]])
                } else if text == "Поздний ответ предыдущего запроса", let previousTurnRequest {
                    write(["id": previousTurnRequest, "error": ["message": "previous turn failed"]])
                }
                previousTurnRequest = id
                let hasImage = input.contains { ($0["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true }
                let answer = "\(getpid())|\(login)|\(hasImage)|\(text.contains("Previous conversation for context:"))"
                write(["id": id, "result": [:]])
                notification("item/agentMessage/delta", ["threadId": "test-thread", "delta": String(answer.prefix(3))])
                notification("item/agentMessage/delta", ["threadId": "test-thread", "delta": String(answer.dropFirst(3))])
                notification("turn/completed", ["threadId": "test-thread", "turn": ["status": "completed"]])
                continue
            default: break
            }
            write(["id": id, "result": result])
        }
    }

    private static func ask(_ client: QuickChatCodex, previous: [QuickChatExchange] = [], image: Data? = nil,
                            expected: CodexChatAccount? = nil, text: String = "Тестовый вопрос")
        -> (String, CodexChatFailure?, CodexChatAccount?) {
        var result: (String, CodexChatFailure?)?
        var account: CodexChatAccount?
        var delta = ""
        client.ask(QuickChatQuestion(text: text, image: image), previous: previous, expectedAccount: expected) {
            switch $0 {
            case let .account(identity): account = identity
            case let .text(value): delta = value
            case let .finished(text):
                precondition(text == delta)
                result = (text, nil)
            case let .failed(error): result = ("", error)
            case .sent: break
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
        guard let result else { fatalError("Timeout in mock Codex protocol") }
        return (result.0, result.1, account)
    }

    private static func input() {
        let point = CGPoint(x: 100, y: 120)
        let screen = CGRect(x: -480, y: -120, width: 960, height: 720)
        let finish = CGPoint(x: 165, y: 198)
        precondition(QuickChatRegion.selection(from: point, to: point, on: screen) == nil)
        precondition(QuickChatRegion.selection(from: point, to: CGPoint(x: 109, y: 127), on: screen) == nil)
        precondition(QuickChatRegion.selection(from: point, to: CGPoint(x: 240, y: 121), on: screen) == nil)
        let area = CGRect(x: 100, y: 120, width: 65, height: 78)
        precondition(QuickChatRegion.selection(from: point, to: finish, on: screen) == area)
        precondition(QuickChatRegion.selection(from: finish, to: point, on: screen) == area)
        precondition(QuickChatRegion.captureRect(area, on: screen) == CGRect(x: 580, y: 402, width: 65, height: 78))
        let corner = CGPoint(x: screen.minX + 2, y: screen.maxY - 2)
        let beyondDisplay = CGPoint(x: screen.maxX + 20, y: screen.minY - 12)
        precondition(QuickChatRegion.selection(from: corner, to: beyondDisplay, on: screen) == screen)
        precondition(QuickChatRegion.captureRect(screen, on: screen).origin == .zero)
        let panel = CGRect(x: 143, y: 92, width: 304, height: 52)
        precondition(!QuickChatAnchor.follows(CGPoint(x: 125, y: 121), from: point, panel: panel))
        precondition(!QuickChatAnchor.follows(CGPoint(x: 151, y: 120), from: point, panel: panel))
        precondition(QuickChatAnchor.follows(CGPoint(x: 100, y: 165), from: point, panel: panel))
        print("PASS region selection, short drag rejection, full display, coordinate mapping and chat anchor")
    }

    static func main() throws {
        if ["-c", "--disable"].contains(CommandLine.arguments.dropFirst().first ?? "") { return mockServer() }
        input()
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let imageFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: imageFile) }
        try QuickChatImage.jpeg(context.makeImage()!)!.write(to: imageFile)
        precondition(QuickChatImage.read(imageFile)?.prefix(2) == Data([0xff, 0xd8]))
        try Data("invalid image".utf8).write(to: imageFile)
        precondition(QuickChatImage.read(imageFile) == nil)
        print("PASS shelf import reads image bytes and rejects invalid files")
        let fakeLogin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fakeLogin) }
        setenv("CHUBZIK_TEST_ACCOUNT", fakeLogin.path, 1)
        func login(_ value: String) throws { try Data(value.utf8).write(to: fakeLogin, options: .atomic) }
        try login("a@example.test")
        let binary = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL
        let client = QuickChatCodex(executable: binary, authStamp: {
            [((try? Data(contentsOf: fakeLogin)) ?? Data()).base64EncodedString()]
        })
        let first = ask(client)
        precondition(first.1 == nil && first.0.contains("a@example.test|false|false"))
        let transcript = [QuickChatExchange(question: QuickChatQuestion(text: "Ранее", image: Data([1])), answer: first.0)]
        let second = ask(client, previous: transcript)
        precondition(second.0.hasSuffix("a@example.test|false|true"))
        let withImage = ask(client, previous: transcript, image: Data([2]))
        precondition(withImage.0.hasSuffix("a@example.test|true|true"))
        precondition(first.0.split(separator: "|")[0] == second.0.split(separator: "|")[0])
        print("PASS CLI process and text context are reused, only the visible attachment is sent")
        precondition(ask(client, text: "Поздний ответ предыдущего запроса").1 == nil,
                     "A stale reply must not fail the next turn")
        precondition(ask(client, text: "Сервер запросил ввод").1 == .requestFailed,
                     "A server request must be recognized even if its ID matches a client request")
        precondition(ask(client).1 == nil)
        print("PASS late replies are ignored, server requests disconnect, and the next question recovers")

        try login("b@example.test")
        let changed = ask(client, expected: first.2)
        precondition(changed.1 == .accountChanged && changed.2?.email == "b@example.test")
        let confirmed = ask(client, previous: transcript)
        precondition(confirmed.0.hasSuffix("b@example.test|false|true"))
        precondition(first.0.split(separator: "|")[0] != confirmed.0.split(separator: "|")[0])
        print("PASS account switch reconnects, automatic replay is guarded, explicitly reopened history works")

        try login("")
        precondition(ask(client).1 == .signIn)
        try login("a@example.test")
        let signedIn = ask(client)
        precondition(signedIn.0.hasSuffix("a@example.test|false|false"))
        client.close()
        print("PASS sign-out and sign-in recover without resetting the client")

        let transfer = QuickChatTransfer(exchanges: transcript, unfinished: nil, partial: "", draft: "Уточнение & C++?",
                                         selectedText: "Текст с экрана", attachment: nil)
        var transferResult: Result<String, CodexChatFailure>?
        client.transfer(transfer, to: FileManager.default.temporaryDirectory) { transferResult = $0 }
        let deadline = Date().addingTimeInterval(5)
        while transferResult == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
        guard let transferResult else { fatalError("Timeout waiting for context transfer") }
        let link = try transferResult.map { transfer.link(to: $0)! }.get()
        let components = URLComponents(url: link, resolvingAgainstBaseURL: false)
        precondition(components?.host == "threads" && components?.queryItems?.first?.value == "Уточнение & C++?")
        precondition(components?.percentEncodedQuery?.contains("%2B%2B") == true)
        let newDraft = QuickChatTransfer(exchanges: [], unfinished: nil, partial: "", draft: "Найди .pen",
                                         selectedText: nil, attachment: nil)
        let folder = URL(fileURLWithPath: "/tmp/Проект + файлы", isDirectory: true)
        let newLink = URLComponents(url: newDraft.link(folder: folder)!, resolvingAgainstBaseURL: false)
        precondition(newDraft.items.isEmpty && newLink?.path == "/new")
        precondition(newLink?.queryItems == [URLQueryItem(name: "prompt", value: "Найди .pen"),
                                             URLQueryItem(name: "path", value: folder.path)])
        print("PASS transfer imports visible turns, preserves the image, and creates an unsent draft")
    }
}
