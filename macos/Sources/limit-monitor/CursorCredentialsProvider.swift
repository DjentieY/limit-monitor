import Foundation
import LimitMonitorCore

enum CursorCredentialsProvider {
    enum LoadResult {
        /// Cookie value is secret material — never printed; jwtSegments is the
        /// only shape diagnostic --check may show.
        case ok(cookie: String, dbPath: String, jwtSegments: Int)
        case missing(path: String)
        case emptyToken(path: String)
        case badToken(path: String, jwtSegments: Int)
        /// DB exists but sqlite3 failed (busy/locked/watchdog-killed) — a
        /// transient condition, NOT "Cursor is not installed".
        case queryFailed(path: String)
    }

    static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private enum QueryResult {
        case value(String)
        case empty
        case failed
    }

    static func load() -> LoadResult {
        let url = dbURL
        let path = displayPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing(path: path) }
        let raw: String
        switch queryToken(dbPath: url.path) {
        case .failed: return .queryFailed(path: path)
        case .empty: return .emptyToken(path: path)
        case .value(let value): raw = value
        }
        let token = CursorAuth.unquote(raw)
        guard !token.isEmpty else { return .emptyToken(path: path) }
        guard let cookie = CursorAuth.cookieValue(fromDBValue: raw) else {
            return .badToken(path: path, jwtSegments: CursorAuth.jwtSegmentCount(token))
        }
        return .ok(cookie: cookie, dbPath: path, jwtSegments: CursorAuth.jwtSegmentCount(token))
    }

    // The DB is huge (5.6 GB here) and live-written by Cursor: NEVER copy it,
    // never open read-write. The sqlite3 CLI with -readonly does an indexed
    // point lookup on ItemTable, fast even at that size; 2 s busy timeout
    // inside a 5 s watchdog. A process failure (busy/locked/killed) is
    // reported as .failed — it must not read as "no token in the DB".
    private static func queryToken(dbPath: String) -> QueryResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", "-cmd", ".timeout 2000", dbPath,
            "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return .failed }
        guard let text = String(data: data, encoding: .utf8) else { return .empty }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .value(trimmed)
    }

    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
