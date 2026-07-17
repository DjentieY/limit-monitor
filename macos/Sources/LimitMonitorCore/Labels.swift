import Foundation

public enum Labels {
    public static func windowLabel(for limit: LimitEntry) -> String {
        if let explicit = limit.windowLabel { return explicit }
        if let minutes = limit.windowMinutes {
            let hours = Int((Double(minutes) / 60).rounded())
            if hours < 48 { return "\(hours)h" }
            return "\(Int((Double(minutes) / 1440).rounded()))d"
        }
        switch limit.kind {
        case "session": return "5h"
        case "weekly_all", "weekly_scoped": return "7d"
        case "cursor_auto": return "Auto"
        case "cursor_api": return "API"
        case "cursor_on_demand": return "OnD"
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

    /// Menu/notification display name of the limit's provider (config providers
    /// carry it from providers.json).
    public static func providerDisplayName(for limit: LimitEntry) -> String {
        limit.providerName ?? Provider.displayName(limit.provider)
    }

    public static func menuLabel(for limit: LimitEntry) -> String {
        if limit.provider == Provider.codex { return codexMenuLabel(for: limit) }
        if limit.provider == Provider.cursor { return cursorMenuLabel(for: limit) }
        if !Provider.isBuiltin(limit.provider) { return configMenuLabel(for: limit) }
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

    public static func resetTitle(for limit: LimitEntry) -> String {
        "Лимиты \(providerDisplayName(for: limit)) обновились"
    }

    public static func exhaustedTitle(for limit: LimitEntry) -> String {
        if limit.provider == Provider.codex { return codexExhaustedTitle(for: limit) }
        if limit.provider == Provider.cursor {
            return "Cursor: лимит \(cursorNotificationName(for: limit)) исчерпан"
        }
        if !Provider.isBuiltin(limit.provider) { return configExhaustedTitle(for: limit) }
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
        if limit.provider == Provider.codex { return codexResetBody(for: limit) }
        if limit.provider == Provider.cursor {
            return "Cursor: лимит \(cursorNotificationName(for: limit)) сброшен."
        }
        if !Provider.isBuiltin(limit.provider) { return configResetBody(for: limit) }
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

    // MARK: - Codex (labels keyed off the window size, not the kind)

    private enum CodexForm {
        case fiveHour
        case weekly
        case generic
    }

    private static func codexForm(for limit: LimitEntry) -> CodexForm {
        if let minutes = limit.windowMinutes {
            if abs(minutes - 300) <= 60 { return .fiveHour }
            if abs(minutes - 10080) <= 1440 { return .weekly }
            return .generic
        }
        switch limit.kind {
        case "session": return .fiveHour
        case "weekly_all", "weekly_scoped": return .weekly
        default: return .generic
        }
    }

    private static func codexBaseLabel(for limit: LimitEntry) -> String {
        switch codexForm(for: limit) {
        case .fiveHour: return "5-часовой"
        case .weekly: return "Недельный"
        case .generic:
            guard let minutes = limit.windowMinutes else { return humanizeKind(limit.kind) }
            let hours = Int((Double(minutes) / 60).rounded())
            if hours < 48 { return "Окно \(hours) ч" }
            return "Окно \(Int((Double(minutes) / 1440).rounded())) дн"
        }
    }

    private static func codexMenuLabel(for limit: LimitEntry) -> String {
        let base = codexBaseLabel(for: limit)
        guard let name = limit.scopeDisplayName else { return base }
        return "\(base) · \(name)"
    }

    private static func codexExhaustedTitle(for limit: LimitEntry) -> String {
        switch (codexForm(for: limit), limit.scopeDisplayName) {
        case (.fiveHour, nil): return "Codex: 5-часовой лимит исчерпан"
        case (.weekly, nil): return "Codex: недельный лимит исчерпан"
        case (.weekly, let name?): return "Codex: недельный лимит \(name) исчерпан"
        default: return "Codex: лимит \(menuLabel(for: limit)) исчерпан"
        }
    }

    private static func codexResetBody(for limit: LimitEntry) -> String {
        switch (codexForm(for: limit), limit.scopeDisplayName) {
        case (.fiveHour, nil): return "Codex: 5-часовое окно сброшено — можно работать."
        case (.weekly, nil): return "Codex: недельный лимит сброшен."
        case (.weekly, let name?): return "Codex: недельный лимит \(name) сброшен."
        default: return "Codex: лимит \(menuLabel(for: limit)) сброшен."
        }
    }

    // MARK: - Cursor (billing-cycle buckets, no windows)

    private static func cursorMenuLabel(for limit: LimitEntry) -> String {
        switch limit.kind {
        case "cursor_auto": return "Auto+Composer"
        case "cursor_api": return "API-модели"
        case "cursor_on_demand": return "On-demand"
        case "cursor_unlimited": return "Cursor"
        default: return humanizeKind(limit.kind)
        }
    }

    // Notification wording differs from the menu labels: "API" (not API-модели),
    // lowercase "on-demand" — per SPEC v0.3.
    private static func cursorNotificationName(for limit: LimitEntry) -> String {
        switch limit.kind {
        case "cursor_auto": return "Auto+Composer"
        case "cursor_api": return "API"
        case "cursor_on_demand": return "on-demand"
        default: return menuLabel(for: limit)
        }
    }

    // MARK: - Config providers (v0.4, providers.json)

    private static func configMenuLabel(for limit: LimitEntry) -> String {
        if limit.kind == "time_limit" { return "Поиск/MCP" }
        if limit.balanceText != nil { return providerDisplayName(for: limit) }
        // Windowed percent entries (zhipu) reuse the codex window forms.
        if limit.windowMinutes != nil { return codexBaseLabel(for: limit) }
        return providerDisplayName(for: limit)
    }

    // SPEC v0.4 pattern `<Name>: лимит <label> исчерпан`; single-entry providers
    // whose label IS the name collapse to `<Name>: лимит исчерпан`.
    private static func configExhaustedTitle(for limit: LimitEntry) -> String {
        let name = providerDisplayName(for: limit)
        if limit.balanceText != nil { return "\(name): баланс исчерпан" }
        let label = configMenuLabel(for: limit)
        if label == name { return "\(name): лимит исчерпан" }
        return "\(name): лимит \(label) исчерпан"
    }

    private static func configResetBody(for limit: LimitEntry) -> String {
        let name = providerDisplayName(for: limit)
        let label = configMenuLabel(for: limit)
        if label == name { return "\(name): лимит сброшен." }
        return "\(name): лимит \(label) сброшен."
    }
}
