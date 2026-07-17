import Foundation
import LimitMonitorCore

// Loads ~/.config/limit-monitor/providers.json (or $LIMIT_MONITOR_PROVIDERS)
// once at launch / per --check run. The file may contain literal keys: its
// contents are never logged or printed anywhere.
enum ProvidersConfigLoader {
    enum LoadResult {
        case missing(path: String)
        case malformed(path: String)
        case unsupportedVersion(path: String)
        /// permissive: the file is group/other-readable (chmod 600 warning).
        case loaded(config: ProvidersConfig, path: String, permissive: Bool)
    }

    static func load() -> LoadResult {
        let path = ProvidersConfigFile.path()
        let manager = FileManager.default
        guard manager.fileExists(atPath: path), let data = manager.contents(atPath: path) else {
            return .missing(path: path)
        }
        let permissions = (try? manager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        let permissive = permissions.map {
            ProvidersConfigFile.isPermissive(posixPermissions: $0.intValue)
        } ?? false
        switch ProvidersConfigParser.parse(data: data) {
        case .malformed:
            return .malformed(path: path)
        case .unsupportedVersion:
            return .unsupportedVersion(path: path)
        case .parsed(let config):
            return .loaded(config: config, path: path, permissive: permissive)
        }
    }

    /// True when the missing path is the default location (no env override) —
    /// --check then prints the canonical `custom: no ~/.config/...` line (EN).
    static func isDefaultPath(_ path: String) -> Bool {
        path == ProvidersConfigFile.path(environment: [:])
    }
}
