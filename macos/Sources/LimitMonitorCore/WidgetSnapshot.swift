import Foundation

/// Widget-ready snapshot (SPEC v0.6, schema v2 — fully NEUTRAL). Written
/// atomically by the shell to ~/Library/Application Support/limit-monitor/
/// widget-snapshot.json after every poll cycle and by `--check` on success;
/// consumed by `--status [--json]` and external integrations
/// (SwiftBar/Raycast/agents). Carries numbers, neutral structural fields and
/// ISO-8601 UTC times ONLY — never credentials, never a localized string. Two
/// writers (GUI in system locale, `--check` pinned to EN) must produce
/// byte-identical files, so labels are reconstructed at each reader's render
/// from the neutral fields (`kind`/`scopeName`/`windowMinutes`/…).
public struct WidgetSnapshot: Codable, Equatable {
    public struct ProviderEntry: Codable, Equatable {
        public var id: String
        public var name: String
        /// Bar group label without the trailing `·` ("Cl", "DS").
        public var label: String
        public var stale: Bool
        public var limits: [LimitRow]

        public init(id: String, name: String, label: String, stale: Bool, limits: [LimitRow]) {
            self.id = id
            self.name = name
            self.label = label
            self.stale = stale
            self.limits = limits
        }
    }

    public struct LimitRow: Codable, Equatable {
        public var kind: String
        /// Neutral scope/model brand name ("Fable", "Spark") for scoped rows;
        /// nil when not scoped. Replaces the dropped localized `label` (v0.6).
        public var scopeName: String?
        /// Bar window label ("5h"); absent for balance/∞ rows without one.
        public var windowLabel: String?
        /// Raw window size in minutes — REQUIRED so codex/config windowed labels
        /// are classified at ±60/±1440 tolerance at render (which the rounded
        /// `windowLabel` loses); nil when unknown (e.g. claude's kind-derived
        /// windows).
        public var windowMinutes: Int?
        /// Present for percent entries only (balance/∞ rows carry just `text`).
        public var percent: Int?
        /// Display value: "9%" / "$23.45" / "∞".
        public var text: String
        /// Level name: green/yellow/orange/red.
        public var level: String
        /// ISO-8601 UTC, seconds precision; absent when no reset instant is known.
        public var resetsAt: String?
        public var exhausted: Bool

        public init(
            kind: String,
            scopeName: String? = nil,
            windowLabel: String? = nil,
            windowMinutes: Int? = nil,
            percent: Int? = nil,
            text: String,
            level: String,
            resetsAt: String? = nil,
            exhausted: Bool
        ) {
            self.kind = kind
            self.scopeName = scopeName
            self.windowLabel = windowLabel
            self.windowMinutes = windowMinutes
            self.percent = percent
            self.text = text
            self.level = level
            self.resetsAt = resetsAt
            self.exhausted = exhausted
        }
    }

    public static let currentVersion = 2
    /// `generatedAt` older than this against a passed `now` → snapshot is stale.
    public static let staleAfter: TimeInterval = 15 * 60

    public var version: Int
    public var generatedAt: String
    public var providers: [ProviderEntry]

    public init(version: Int, generatedAt: String, providers: [ProviderEntry]) {
        self.version = version
        self.generatedAt = generatedAt
        self.providers = providers
    }

    public var generatedAtDate: Date? { ISODateParser.parse(generatedAt) }

    public func isStale(now: Date) -> Bool {
        guard let generated = generatedAtDate else { return true }
        return now.timeIntervalSince(generated) > Self.staleAfter
    }

    // MARK: - Builder (from the merged provider model)

    /// Only providers with data are included; disabled providers are excluded.
    public static func build(
        groups: [ProviderGroup],
        now: Date,
        disabled: Set<String> = []
    ) -> WidgetSnapshot {
        let included = ProviderFilter.groups(groups, disabled: disabled).filter { !$0.limits.isEmpty }
        return WidgetSnapshot(
            version: currentVersion,
            generatedAt: ISODateParser.utcString(from: now),
            providers: included.map { group in
                ProviderEntry(
                    id: group.provider,
                    name: group.limits.first?.providerName ?? Provider.displayName(group.provider),
                    label: barLabel(for: group),
                    stale: group.stale,
                    limits: group.limits.map(row(for:))
                )
            }
        )
    }

    private static func barLabel(for group: ProviderGroup) -> String {
        let prefix = group.titlePrefix ?? Provider.titlePrefix(group.provider)
        return prefix.hasSuffix("·") ? String(prefix.dropLast()) : prefix
    }

    private static func row(for limit: LimitEntry) -> LimitRow {
        let isPercent = limit.balanceText == nil && !limit.unlimited
        return LimitRow(
            kind: limit.kind,
            scopeName: limit.scopeDisplayName,
            windowLabel: windowLabel(for: limit),
            windowMinutes: limit.windowMinutes,
            percent: isPercent ? limit.percent : nil,
            text: limit.balanceText ?? (limit.unlimited ? "∞" : "\(limit.percent)%"),
            level: limit.level.name,
            resetsAt: limit.resetsAt.map { ISODateParser.utcString(from: $0) },
            exhausted: limit.isExhausted
        )
    }

    private static func windowLabel(for limit: LimitEntry) -> String? {
        // Mirror the bar segment: balance rows only keep an explicit label
        // (openrouter "1m"), the cursor ∞ plan is dotless/label-free.
        if limit.balanceText != nil {
            let explicit = limit.windowLabel ?? ""
            return explicit.isEmpty ? nil : explicit
        }
        if limit.unlimited, limit.kind == "cursor_unlimited" { return nil }
        let derived = Labels.windowLabel(for: limit)
        return derived.isEmpty ? nil : derived
    }

    // MARK: - Serialization (round-trips via parse)

    public func encode() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    public static func parse(data: Data) -> WidgetSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }
}
