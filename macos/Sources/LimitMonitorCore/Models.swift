import Foundation

public enum Level: Int, Comparable {
    case green = 0
    case yellow = 1
    case orange = 2
    case red = 3

    public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func level(percent: Int, severity: String) -> Level {
        let base: Level
        switch percent {
        case ..<50: base = .green
        case 50..<75: base = .yellow
        case 75..<90: base = .orange
        default: base = .red
        }
        if severity != "normal", base < .orange { return .orange }
        return base
    }

    public var name: String {
        switch self {
        case .green: return "green"
        case .yellow: return "yellow"
        case .orange: return "orange"
        case .red: return "red"
        }
    }
}

public struct LimitEntry: Equatable {
    public var provider: String
    public var kind: String
    public var group: String?
    public var percent: Int
    public var severity: String
    public var resetsAtRaw: String?
    public var resetsAt: Date?
    public var scopeDisplayName: String?
    public var windowMinutes: Int?
    /// Renders as ∞ (green) and is excluded from notification planning —
    /// cursor's `isUnlimited` plan and null/0-limit on-demand.
    public var unlimited: Bool
    public var isActive: Bool

    public init(
        provider: String = Provider.claude,
        kind: String,
        group: String? = nil,
        percent: Int,
        severity: String = "normal",
        resetsAtRaw: String? = nil,
        resetsAt: Date? = nil,
        scopeDisplayName: String? = nil,
        windowMinutes: Int? = nil,
        unlimited: Bool = false,
        isActive: Bool = false
    ) {
        self.provider = provider
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAtRaw = resetsAtRaw
        self.resetsAt = resetsAt
        self.scopeDisplayName = scopeDisplayName
        self.windowMinutes = windowMinutes
        self.unlimited = unlimited
        self.isActive = isActive
    }

    public var level: Level { Level.level(percent: percent, severity: severity) }
    public var isExhausted: Bool { percent >= 100 }
}
