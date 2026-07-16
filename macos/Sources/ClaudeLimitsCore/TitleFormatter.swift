import Foundation

public struct TitleSegment: Equatable {
    public var text: String
    public var level: Level

    public init(text: String, level: Level) {
        self.text = text
        self.level = level
    }
}

public enum TitleFormatter {
    public static func segments(for limits: [LimitEntry]) -> [TitleSegment] {
        limits.map {
            TitleSegment(text: "●\($0.percent)% \(Labels.shortLabel(for: $0))", level: $0.level)
        }
    }

    public static func plainTitle(for limits: [LimitEntry], stale: Bool) -> String {
        let segments = segments(for: limits)
        guard !segments.isEmpty else { return stale ? "⚠…" : "…" }
        return (stale ? "⚠" : "") + segments.map(\.text).joined(separator: "·")
    }
}
