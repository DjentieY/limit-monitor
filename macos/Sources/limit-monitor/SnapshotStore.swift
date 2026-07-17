import Foundation
import LimitMonitorCore

/// Atomic snapshot writer (SPEC v0.5): temp file + rename into
/// ~/Library/Application Support/limit-monitor/widget-snapshot.json.
/// Written after every poll cycle and by `--check` on success; read by
/// `--status [--json]`.
enum SnapshotStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/limit-monitor", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("widget-snapshot.json")
    }

    @discardableResult
    static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let data = snapshot.encode() else { return false }
        let fm = FileManager.default
        let temp = directory.appendingPathComponent(".widget-snapshot-\(getpid()).tmp")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp)
        } catch {
            return false
        }
        // rename(2) atomically replaces the destination on the same volume, so
        // a concurrent --status never sees a partially written snapshot.
        guard rename(temp.path, fileURL.path) == 0 else {
            try? fm.removeItem(at: temp)
            return false
        }
        return true
    }

    static func read() -> Data? {
        try? Data(contentsOf: fileURL)
    }
}
