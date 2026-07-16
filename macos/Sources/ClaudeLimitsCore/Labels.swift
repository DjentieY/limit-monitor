import Foundation

public enum Labels {
    public static func windowLabel(for limit: LimitEntry) -> String {
        switch limit.kind {
        case "session": return "5h"
        case "weekly_all", "weekly_scoped": return "7d"
        default:
            switch limit.group {
            case "session": return "5h"
            case "weekly": return "7d"
            default: return limit.kind
            }
        }
    }

    public static func humanizeKind(_ kind: String) -> String {
        let words = kind.split(separator: "_").map(String.init)
        guard let first = words.first else { return kind }
        let capitalized = first.prefix(1).uppercased() + first.dropFirst()
        return ([capitalized] + words.dropFirst()).joined(separator: " ")
    }

    public static func menuLabel(for limit: LimitEntry) -> String {
        switch limit.kind {
        case "session": return "5-часовой"
        case "weekly_all": return "Недельный (все модели)"
        case "weekly_scoped":
            guard let name = limit.scopeDisplayName else { return humanizeKind(limit.kind) }
            return "Недельный · \(name)"
        default:
            guard let name = limit.scopeDisplayName else { return humanizeKind(limit.kind) }
            return "\(humanizeKind(limit.kind)) · \(name)"
        }
    }

    public static func exhaustedTitle(for limit: LimitEntry) -> String {
        switch limit.kind {
        case "session": return "Claude: 5-часовой лимит исчерпан"
        case "weekly_all": return "Claude: недельный лимит исчерпан"
        case "weekly_scoped":
            guard let name = limit.scopeDisplayName else {
                return "Claude: лимит \(menuLabel(for: limit)) исчерпан"
            }
            return "Claude: недельный лимит \(name) исчерпан"
        default:
            return "Claude: лимит \(menuLabel(for: limit)) исчерпан"
        }
    }

    public static func resetBody(for limit: LimitEntry) -> String {
        switch limit.kind {
        case "session": return "5-часовое окно сброшено — можно работать."
        case "weekly_all": return "Недельный лимит сброшен."
        case "weekly_scoped":
            guard let name = limit.scopeDisplayName else {
                return "Лимит \(menuLabel(for: limit)) сброшен."
            }
            return "Недельный лимит \(name) сброшен."
        default:
            return "Лимит \(menuLabel(for: limit)) сброшен."
        }
    }
}
