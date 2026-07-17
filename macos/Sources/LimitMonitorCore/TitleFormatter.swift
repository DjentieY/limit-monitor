import Foundation

public struct TitleSegment: Equatable {
    public var pre: String
    public var post: String
    public var level: Level
    /// Dotless segments render `post` alone, colored by `level` (cursor's ∞).
    public var dotless: Bool

    public var text: String { dotless ? post : pre + "●" + post }

    public init(pre: String, post: String, level: Level, dotless: Bool = false) {
        self.pre = pre
        self.post = post
        self.level = level
        self.dotless = dotless
    }
}

public struct ProviderGroup: Equatable {
    public var provider: String
    public var limits: [LimitEntry]
    public var stale: Bool
    /// Config providers (v0.4): bar prefix from providers.json `label` ("OR·");
    /// nil → the builtin Cl·/Cx·/Cu· mapping.
    public var titlePrefix: String?

    public init(provider: String, limits: [LimitEntry], stale: Bool = false, titlePrefix: String? = nil) {
        self.provider = provider
        self.limits = limits
        self.stale = stale
        self.titlePrefix = titlePrefix
    }
}

public enum TitleFormatter {
    /// Default joiner between segments within one provider — U+2502 light
    /// vertical (SPEC v0.7: overridable via `barSegmentSeparator`).
    public static let defaultSegmentSeparator = " \u{2502} "
    /// Default joiner between provider groups — U+2503 heavy vertical (SPEC v0.7,
    /// was U+2016; overridable via `barProviderSeparator`). Thin inside a
    /// provider, heavy between providers.
    public static let defaultProviderSeparator = " \u{2503} "

    /// Normalizes a user-supplied separator (the shell reads it from the
    /// persisted defaults store; Core stays pure): trim trailing newlines, an
    /// empty/whitespace-only value falls back to `default`, cap at 8 characters.
    /// The stored value is the FULL joiner INCLUDING surrounding spacing, so
    /// interior/edge spaces are preserved — only trailing newlines are stripped.
    public static func normalizedSeparator(_ raw: String?, default fallback: String) -> String {
        guard var value = raw else { return fallback }
        while let last = value.last, last == "\n" || last == "\r" { value.removeLast() }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return fallback }
        if value.count > 8 { value = String(value.prefix(8)) }
        return value
    }

    public static func segments(for limits: [LimitEntry]) -> [TitleSegment] {
        limits.filter { !$0.menuOnly }.map { limit in
            if let balanceText = limit.balanceText {
                // Config balance segments have no window label: ●$23.45.
                return TitleSegment(pre: limit.windowLabel ?? "", post: balanceText, level: limit.level)
            }
            if limit.unlimited {
                if limit.kind == "cursor_unlimited" {
                    return TitleSegment(pre: "", post: "∞", level: limit.level, dotless: true)
                }
                return TitleSegment(pre: Labels.windowLabel(for: limit), post: "∞", level: limit.level)
            }
            let name = limit.scopeDisplayName.map { " \($0)" } ?? ""
            return TitleSegment(
                pre: Labels.windowLabel(for: limit),
                post: "\(limit.percent)%\(name)",
                level: limit.level
            )
        }
    }

    public static func plainTitle(
        for limits: [LimitEntry],
        stale: Bool,
        segmentSeparator: String = defaultSegmentSeparator
    ) -> String {
        let segments = segments(for: limits)
        guard !segments.isEmpty else { return stale ? "⚠…" : "…" }
        return (stale ? "⚠" : "") + segments.map(\.text).joined(separator: segmentSeparator)
    }

    /// Merged title: one active provider — the plain single-provider format (no prefix);
    /// several — groups joined by the provider separator, each prefixed Cl·/Cx·/Cu·,
    /// with a per-provider ⚠ before the stale group's prefix. Separators default to
    /// the constants above; the shell passes the user's overrides (SPEC v0.7).
    public static func plainTitle(
        groups: [ProviderGroup],
        segmentSeparator: String = defaultSegmentSeparator,
        providerSeparator: String = defaultProviderSeparator
    ) -> String {
        guard !groups.isEmpty else { return "…" }
        if groups.count == 1 {
            return plainTitle(for: groups[0].limits, stale: groups[0].stale, segmentSeparator: segmentSeparator)
        }
        return groups.map { group in
            let groupSegments = segments(for: group.limits)
            let body = groupSegments.isEmpty
                ? "…"
                : groupSegments.map(\.text).joined(separator: segmentSeparator)
            let prefix = group.titlePrefix ?? Provider.titlePrefix(group.provider)
            return (group.stale ? "⚠" : "") + prefix + body
        }.joined(separator: providerSeparator)
    }
}
