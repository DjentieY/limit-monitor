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

    public init(provider: String, limits: [LimitEntry], stale: Bool = false) {
        self.provider = provider
        self.limits = limits
        self.stale = stale
    }
}

public enum TitleFormatter {
    /// Joins segments within one provider (U+2502).
    public static let separator = " \u{2502} "
    /// Joins provider groups (U+2016).
    public static let providerSeparator = " \u{2016} "

    public static func segments(for limits: [LimitEntry]) -> [TitleSegment] {
        limits.map { limit in
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

    public static func plainTitle(for limits: [LimitEntry], stale: Bool) -> String {
        let segments = segments(for: limits)
        guard !segments.isEmpty else { return stale ? "⚠…" : "…" }
        return (stale ? "⚠" : "") + segments.map(\.text).joined(separator: separator)
    }

    /// Merged title: one active provider — the plain single-provider format (no prefix);
    /// several — groups joined by the provider separator, each prefixed Cl·/Cx·/Cu·,
    /// with a per-provider ⚠ before the stale group's prefix.
    public static func plainTitle(groups: [ProviderGroup]) -> String {
        guard !groups.isEmpty else { return "…" }
        if groups.count == 1 { return plainTitle(for: groups[0].limits, stale: groups[0].stale) }
        return groups.map { group in
            let body = group.limits.isEmpty
                ? "…"
                : segments(for: group.limits).map(\.text).joined(separator: separator)
            return (group.stale ? "⚠" : "") + Provider.titlePrefix(group.provider) + body
        }.joined(separator: providerSeparator)
    }
}
