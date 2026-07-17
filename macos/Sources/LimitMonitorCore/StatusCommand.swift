import Foundation

/// `--status [--json]` (SPEC v0.5/v0.6): renders the widget snapshot. Pure over
/// the file bytes so `checks` can drive it fixture-style; the shell only reads
/// the snapshot file, writes stdout and exits. No network, no AppKit. The
/// snapshot is fully NEUTRAL — labels are reconstructed at render time in the
/// reader's own locale, so a file written by an EN process reads correctly for a
/// RU reader and vice-versa.
public enum StatusCommand {
    /// Backwards-compatible RU alias (kept for any external reference); the live
    /// path localizes via `StatusStr.missingSnapshot`.
    public static let missingHint = StatusStr.missingSnapshot.text(.ru)

    public struct Output: Equatable {
        public let stdout: Data
        public let exitCode: Int32

        public init(stdout: Data, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// Missing/unreadable/unparseable snapshot → localized hint + exit 2 (both
    /// modes). `json` → the file bytes VERBATIM (byte-identity contract), exit 0.
    /// Otherwise the human table in `lang`, exit 0.
    public static func output(fileData: Data?, json: Bool, now: Date, _ lang: Language) -> Output {
        guard let fileData, let snapshot = WidgetSnapshot.parse(data: fileData) else {
            return Output(stdout: Data((StatusStr.missingSnapshot.text(lang) + "\n").utf8), exitCode: 2)
        }
        if json { return Output(stdout: fileData, exitCode: 0) }
        return Output(stdout: Data((render(snapshot: snapshot, now: now, lang) + "\n").utf8), exitCode: 0)
    }

    /// Level words for the human table; unknown level strings pass through.
    public static func levelWord(_ level: String, _ lang: Language) -> String {
        switch (lang, level) {
        case (.ru, "green"):  return "зелёный"
        case (.ru, "yellow"): return "жёлтый"
        case (.ru, "orange"): return "оранжевый"
        case (.ru, "red"):    return "красный"
        case (.en, "green"):  return "green"
        case (.en, "yellow"): return "yellow"
        case (.en, "orange"): return "orange"
        case (.en, "red"):    return "red"
        default:              return level
        }
    }

    /// Human table: header `Обновлено: HH:mm`/`Updated: HH:mm` (+ ` (устарело)`/
    /// ` (stale)` when generatedAt is older than 15 min), then per provider a
    /// title line (⚠-prefixed when that provider's data is stale) and one row per
    /// limit: label, value, level word, reset time — all in `lang`.
    public static func render(snapshot: WidgetSnapshot, now: Date, _ lang: Language) -> String {
        var lines: [String] = []
        let clock = snapshot.generatedAtDate.map { TimeFormat.clock($0, lang) } ?? snapshot.generatedAt
        let stale = snapshot.isStale(now: now) ? " \(StatusStr.staleSuffix.text(lang))" : ""
        lines.append("\(StatusStr.updatedPrefix.text(lang)) \(clock)\(stale)")
        if snapshot.providers.isEmpty {
            lines.append(StatusStr.noData.text(lang))
            return lines.joined(separator: "\n")
        }
        let pairs = snapshot.providers.flatMap { provider in provider.limits.map { (provider, $0) } }
        let labelWidth = pairs.map { label(for: $0.1, provider: $0.0, lang).count }.max() ?? 0
        let textWidth = pairs.map { $0.1.text.count }.max() ?? 0
        for provider in snapshot.providers {
            lines.append("")
            lines.append("\(provider.stale ? "⚠ " : "")\(provider.name) [\(provider.label)]")
            for row in provider.limits {
                let line = "  ● "
                    + pad(label(for: row, provider: provider, lang), labelWidth + 2)
                    + pad(row.text, textWidth + 2)
                    + pad(levelWord(row.level, lang), 11)
                    + resetColumn(for: row, now: now, lang)
                lines.append(trimTrailing(line))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Reconstruct a row's label from the snapshot's NEUTRAL fields (v0.6: the
    /// localized `label` is gone) via the shared `Labels.menuLabel` decision
    /// tree — the snapshot-reader feeder. Balance rows are told apart from ∞/
    /// percent rows by `percent`/`text`.
    private static func label(
        for row: WidgetSnapshot.LimitRow,
        provider: WidgetSnapshot.ProviderEntry,
        _ lang: Language
    ) -> String {
        Labels.menuLabel(descriptor: LabelDescriptor(
            providerId: provider.id,
            kind: row.kind,
            scopeName: row.scopeName,
            windowLabel: row.windowLabel,
            windowMinutes: row.windowMinutes,
            isBalance: row.percent == nil && row.text != "∞",
            name: provider.name
        ), lang)
    }

    private static func resetColumn(for row: WidgetSnapshot.LimitRow, now: Date, _ lang: Language) -> String {
        let reset = row.resetsAt.flatMap(ISODateParser.parse)
        if row.exhausted {
            guard let reset else { return StatusStr.exhaustedBare.text(lang) }
            return StatusStr.exhaustedResumes(reset: TimeFormat.absolute(reset, now: now, lang)).text(lang)
        }
        guard let reset else { return "" }
        return StatusStr.resets(reset: TimeFormat.absolute(reset, now: now, lang)).text(lang)
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
