import Foundation

public struct TitleSegment: Equatable {
    public var pre: String
    public var post: String
    public var level: Level

    public var text: String { pre + "●" + post }

    public init(pre: String, post: String, level: Level) {
        self.pre = pre
        self.post = post
        self.level = level
    }
}

public enum TitleFormatter {
    public static let separator = " || "

    public static func segments(for limits: [LimitEntry]) -> [TitleSegment] {
        limits.map { limit in
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
}
