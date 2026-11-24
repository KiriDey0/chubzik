import Foundation
import SQLite3

enum CodexProjectFolder {
    static func find(title: String, in home: URL? = nil) -> URL? {
        let home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let files = try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil),
              let database = files.filter({ $0.lastPathComponent.range(of: #"^state_[0-9]+\.sqlite$"#,
                                                                        options: .regularExpression) != nil })
                .max(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        else { return nil }
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(connection, 150)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT title, name, cwd FROM threads WHERE archived = 0"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        func column(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        let requested = CodexHook.normalizedThreadTitle(title)
        var match: URL?
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let name = column(1).flatMap { $0.isEmpty ? nil : $0 } ?? column(0)
            if name.map(CodexHook.normalizedThreadTitle) == requested {
                guard let path = column(2), path.hasPrefix("/") else { return nil }
                let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                if let match {
                    guard match.path == directory.path ||
                            match.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
                    else { return nil }
                } else {
                    match = directory
                }
            }
            status = sqlite3_step(statement)
        }
        var isDirectory: ObjCBool = false
        guard status == SQLITE_DONE, let match,
              FileManager.default.fileExists(atPath: match.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return match
    }
}
