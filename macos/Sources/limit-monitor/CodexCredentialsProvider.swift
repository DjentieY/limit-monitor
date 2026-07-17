import Foundation
import LimitMonitorCore

enum CodexCredentialsProvider {
    enum LoadResult {
        case oauth(CodexAuth, path: String)
        case apiKeyOnly(path: String)
        case missing(path: String)
        case unreadable(path: String)
    }

    static var authFileURL: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    static func load() -> LoadResult {
        let url = authFileURL
        let path = displayPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing(path: path) }
        guard let data = try? Data(contentsOf: url) else { return .unreadable(path: path) }
        switch CodexAuthParser.parse(data: data) {
        case .oauth(let auth): return .oauth(auth, path: path)
        case .apiKeyOnly: return .apiKeyOnly(path: path)
        case .invalid: return .unreadable(path: path)
        }
    }

    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
