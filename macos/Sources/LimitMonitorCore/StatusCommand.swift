import Foundation

/// `--status [--json]` (SPEC v0.5): renders the widget snapshot. Pure over the
/// file bytes so `checks` can drive it fixture-style; the shell only reads the
/// snapshot file, writes stdout and exits. No network, no AppKit.
public enum StatusCommand {
    public static let missingHint =
        "снапшот недоступен — запусти Limit Monitor или limit-monitor --check"

    public struct Output: Equatable {
        public let stdout: Data
        public let exitCode: Int32

        public init(stdout: Data, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// Missing/unreadable/unparseable snapshot → RU hint + exit 2 (both modes).
    /// `json` → the file bytes VERBATIM (byte-identity contract), exit 0.
    /// Otherwise the human RU table, exit 0.
    public static func output(fileData: Data?, json: Bool, now: Date) -> Output {
        guard let fileData, let snapshot = WidgetSnapshot.parse(data: fileData) else {
            return Output(stdout: Data((missingHint + "\n").utf8), exitCode: 2)
        }
        if json { return Output(stdout: fileData, exitCode: 0) }
        return Output(stdout: Data((render(snapshot: snapshot, now: now) + "\n").utf8), exitCode: 0)
    }

    /// RU level words for the human table; unknown level strings pass through.
    public static func levelWord(_ level: String) -> String {
        switch level {
        case "green": return "зелёный"
        case "yellow": return "жёлтый"
        case "orange": return "оранжевый"
        case "red": return "красный"
        default: return level
        }
    }

    /// Human RU table: header `Обновлено: HH:mm` (+ ` (устарело)` when
    /// generatedAt is older than 15 min), then per provider a title line
    /// (⚠-prefixed when that provider's data is stale) and one row per limit:
    /// label, value, level word, reset time.
    public static func render(snapshot: WidgetSnapshot, now: Date) -> String {
        var lines: [String] = []
        let clock = snapshot.generatedAtDate.map(TimeFormat.clock) ?? snapshot.generatedAt
        lines.append("Обновлено: \(clock)\(snapshot.isStale(now: now) ? " (устарело)" : "")")
        if snapshot.providers.isEmpty {
            lines.append("нет данных ни по одному провайдеру")
            return lines.joined(separator: "\n")
        }
        let rows = snapshot.providers.flatMap(\.limits)
        let labelWidth = rows.map(\.label.count).max() ?? 0
        let textWidth = rows.map(\.text.count).max() ?? 0
        for provider in snapshot.providers {
            lines.append("")
            lines.append("\(provider.stale ? "⚠ " : "")\(provider.name) [\(provider.label)]")
            for row in provider.limits {
                let line = "  ● "
                    + pad(row.label, labelWidth + 2)
                    + pad(row.text, textWidth + 2)
                    + pad(levelWord(row.level), 11)
                    + resetColumn(for: row, now: now)
                lines.append(trimTrailing(line))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func resetColumn(for row: WidgetSnapshot.LimitRow, now: Date) -> String {
        let reset = row.resetsAt.flatMap(ISODateParser.parse)
        if row.exhausted {
            guard let reset else { return "исчерпан" }
            return "исчерпан · возобновится \(TimeFormat.absolute(reset, now: now))"
        }
        guard let reset else { return "" }
        return "сброс \(TimeFormat.absolute(reset, now: now))"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func trimTrailing(_ line: String) -> String {
        var result = line
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}
