import Foundation

/// Neutral inputs for the menu-label decision tree (SPEC v0.6). One `menuLabel`
/// switch, two feeders: the live path builds this from a `LimitEntry`, the
/// `--status` reader path builds it from a snapshot `LimitRow` — no drift.
/// Carries `windowMinutes` (not just the rounded `windowLabel`) so codex/config
/// windowed labels can be classified at ±60/±1440 tolerance at render time.
public struct LabelDescriptor: Equatable {
    public var providerId: String
    public var kind: String
    public var scopeName: String?
    public var windowLabel: String?
    public var windowMinutes: Int?
    public var isBalance: Bool
    public var name: String

    public init(
        providerId: String,
        kind: String,
        scopeName: String? = nil,
        windowLabel: String? = nil,
        windowMinutes: Int? = nil,
        isBalance: Bool = false,
        name: String
    ) {
        self.providerId = providerId
        self.kind = kind
        self.scopeName = scopeName
        self.windowLabel = windowLabel
        self.windowMinutes = windowMinutes
        self.isBalance = isBalance
        self.name = name
    }
}

public enum Labels {
    // Window labels are neutral bar tokens (5h/7d/Auto/…) — never localized.
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

    // Neutral: capitalizes the first word of an unknown kind slug ("Mega promo").
    public static func humanizeKind(_ kind: String) -> String {
        let words = kind.split(separator: "_").map(String.init)
        guard let first = words.first else { return kind }
        let capitalized = first.prefix(1).uppercased() + first.dropFirst()
        return ([capitalized] + words.dropFirst()).joined(separator: " ")
    }

    /// Menu/notification display name of the limit's provider (config providers
    /// carry it from providers.json). Brand — neutral.
    public static func providerDisplayName(for limit: LimitEntry) -> String {
        limit.providerName ?? Provider.displayName(limit.provider)
    }

    /// Neutral descriptor for the live `LimitEntry` path (feeds `menuLabel`).
    public static func descriptor(for limit: LimitEntry) -> LabelDescriptor {
        LabelDescriptor(
            providerId: limit.provider,
            kind: limit.kind,
            scopeName: limit.scopeDisplayName,
            windowLabel: limit.windowLabel,
            windowMinutes: limit.windowMinutes,
            isBalance: limit.balanceText != nil,
            name: providerDisplayName(for: limit)
        )
    }

    public static func menuLabel(for limit: LimitEntry, _ lang: Language) -> String {
        menuLabel(descriptor: descriptor(for: limit), lang)
    }

    /// The single label decision tree, expressed over the neutral descriptor.
    /// Both the live `LimitEntry` feeder and the `--status` `LimitRow` feeder
    /// reach it → live menu labels and `--status` labels never drift.
    public static func menuLabel(descriptor d: LabelDescriptor, _ lang: Language) -> String {
        if d.providerId == Provider.codex { return codexMenuLabel(d, lang) }
        if d.providerId == Provider.cursor { return cursorMenuLabel(d, lang) }
        if !Provider.isBuiltin(d.providerId) { return configMenuLabel(d, lang) }
        switch (lang, d.kind) {
        case (.en, "session"):    return "5-hour"
        case (.ru, "session"):    return "5-часовой"
        case (.en, "weekly_all"): return "Weekly (all models)"
        case (.ru, "weekly_all"): return "Недельный (все модели)"
        case (_, "weekly_scoped"):
            guard let name = d.scopeName else { return humanizeKind(d.kind) }
            return lang == .ru ? "Недельный · \(name)" : "Weekly · \(name)"
        default:
            guard let name = d.scopeName else { return humanizeKind(d.kind) }
            return "\(humanizeKind(d.kind)) · \(name)"
        }
    }

    public static func resetTitle(for limit: LimitEntry, _ lang: Language) -> String {
        let name = providerDisplayName(for: limit)
        return lang == .ru ? "Лимиты \(name) обновились" : "\(name) limits reset"
    }

    public static func exhaustedTitle(for limit: LimitEntry, _ lang: Language) -> String {
        if limit.provider == Provider.codex { return codexExhaustedTitle(for: limit, lang) }
        if limit.provider == Provider.cursor {
            let n = cursorNotificationName(for: limit, lang)
            return lang == .ru ? "Cursor: лимит \(n) исчерпан" : "Cursor: \(n) limit exhausted"
        }
        if !Provider.isBuiltin(limit.provider) { return configExhaustedTitle(for: limit, lang) }
        switch (lang, limit.kind) {
        case (.en, "session"):    return "Claude: 5-hour limit exhausted"
        case (.ru, "session"):    return "Claude: 5-часовой лимит исчерпан"
        case (.en, "weekly_all"): return "Claude: weekly limit exhausted"
        case (.ru, "weekly_all"): return "Claude: недельный лимит исчерпан"
        case (_, "weekly_scoped"):
            guard let name = limit.scopeDisplayName else {
                let l = menuLabel(for: limit, lang)
                return lang == .ru ? "Claude: лимит \(l) исчерпан" : "Claude: \(l) limit exhausted"
            }
            return lang == .ru
                ? "Claude: недельный лимит \(name) исчерпан"
                : "Claude: weekly \(name) limit exhausted"
        default:
            let l = menuLabel(for: limit, lang)
            return lang == .ru ? "Claude: лимит \(l) исчерпан" : "Claude: \(l) limit exhausted"
        }
    }

    public static func resetBody(for limit: LimitEntry, _ lang: Language) -> String {
        if limit.provider == Provider.codex { return codexResetBody(for: limit, lang) }
        if limit.provider == Provider.cursor {
            let n = cursorNotificationName(for: limit, lang)
            return lang == .ru ? "Cursor: лимит \(n) сброшен." : "Cursor: \(n) limit reset."
        }
        if !Provider.isBuiltin(limit.provider) { return configResetBody(for: limit, lang) }
        switch (lang, limit.kind) {
        case (.en, "session"):    return "5-hour window reset — you can work."
        case (.ru, "session"):    return "5-часовое окно сброшено — можно работать."
        case (.en, "weekly_all"): return "Weekly limit reset."
        case (.ru, "weekly_all"): return "Недельный лимит сброшен."
        case (_, "weekly_scoped"):
            guard let name = limit.scopeDisplayName else {
                let l = menuLabel(for: limit, lang)
                return lang == .ru ? "Лимит \(l) сброшен." : "\(l) limit reset."
            }
            return lang == .ru
                ? "Недельный лимит \(name) сброшен."
                : "Weekly \(name) limit reset."
        default:
            let l = menuLabel(for: limit, lang)
            return lang == .ru ? "Лимит \(l) сброшен." : "\(l) limit reset."
        }
    }

    // MARK: - Codex (labels keyed off the window size, not the kind)

    private enum CodexForm {
        case fiveHour
        case weekly
        case generic
    }

    // Classification is neutral (window arithmetic), independent of language.
    private static func codexForm(_ d: LabelDescriptor) -> CodexForm {
        if let minutes = d.windowMinutes {
            if abs(minutes - 300) <= 60 { return .fiveHour }
            if abs(minutes - 10080) <= 1440 { return .weekly }
            return .generic
        }
        switch d.kind {
        case "session": return .fiveHour
        case "weekly_all", "weekly_scoped": return .weekly
        default: return .generic
        }
    }

    private static func codexForm(for limit: LimitEntry) -> CodexForm { codexForm(descriptor(for: limit)) }

    private static func codexBaseLabel(_ d: LabelDescriptor, _ lang: Language) -> String {
        switch codexForm(d) {
        case .fiveHour: return lang == .ru ? "5-часовой" : "5-hour"
        case .weekly: return lang == .ru ? "Недельный" : "Weekly"
        case .generic:
            guard let minutes = d.windowMinutes else { return humanizeKind(d.kind) }
            let hours = Int((Double(minutes) / 60).rounded())
            if hours < 48 {
                return lang == .ru ? "Окно \(hours) ч" : "\(hours)-hour window"
            }
            let days = Int((Double(minutes) / 1440).rounded())
            return lang == .ru ? "Окно \(days) дн" : "\(days)-day window"
        }
    }

    private static func codexMenuLabel(_ d: LabelDescriptor, _ lang: Language) -> String {
        let base = codexBaseLabel(d, lang)
        guard let name = d.scopeName else { return base }
        return "\(base) · \(name)"
    }

    private static func codexExhaustedTitle(for limit: LimitEntry, _ lang: Language) -> String {
        switch (codexForm(for: limit), limit.scopeDisplayName) {
        case (.fiveHour, nil):
            return lang == .ru ? "Codex: 5-часовой лимит исчерпан" : "Codex: 5-hour limit exhausted"
        case (.weekly, nil):
            return lang == .ru ? "Codex: недельный лимит исчерпан" : "Codex: weekly limit exhausted"
        case (.weekly, let name?):
            return lang == .ru
                ? "Codex: недельный лимит \(name) исчерпан"
                : "Codex: weekly \(name) limit exhausted"
        default:
            let l = menuLabel(for: limit, lang)
            return lang == .ru ? "Codex: лимит \(l) исчерпан" : "Codex: \(l) limit exhausted"
        }
    }

    private static func codexResetBody(for limit: LimitEntry, _ lang: Language) -> String {
        switch (codexForm(for: limit), limit.scopeDisplayName) {
        case (.fiveHour, nil):
            return lang == .ru
                ? "Codex: 5-часовое окно сброшено — можно работать."
                : "Codex: 5-hour window reset — you can work."
        case (.weekly, nil):
            return lang == .ru ? "Codex: недельный лимит сброшен." : "Codex: weekly limit reset."
        case (.weekly, let name?):
            return lang == .ru
                ? "Codex: недельный лимит \(name) сброшен."
                : "Codex: weekly \(name) limit reset."
        default:
            let l = menuLabel(for: limit, lang)
            return lang == .ru ? "Codex: лимит \(l) сброшен." : "Codex: \(l) limit reset."
        }
    }

    // MARK: - Cursor (billing-cycle buckets, no windows)

    private static func cursorMenuLabel(_ d: LabelDescriptor, _ lang: Language) -> String {
        switch d.kind {
        case "cursor_auto": return "Auto+Composer"
        case "cursor_api": return lang == .ru ? "API-модели" : "API models"
        case "cursor_on_demand": return "On-demand"
        case "cursor_unlimited": return "Cursor"
        default: return humanizeKind(d.kind)
        }
    }

    // Notification wording differs from the menu labels: "API" (not API-модели),
    // lowercase "on-demand" — per SPEC v0.3. Auto+Composer/on-demand are neutral.
    private static func cursorNotificationName(for limit: LimitEntry, _ lang: Language) -> String {
        switch limit.kind {
        case "cursor_auto": return "Auto+Composer"
        case "cursor_api": return "API"
        case "cursor_on_demand": return "on-demand"
        default: return menuLabel(for: limit, lang)
        }
    }

    // MARK: - Config providers (v0.4, providers.json)

    private static func configMenuLabel(_ d: LabelDescriptor, _ lang: Language) -> String {
        if d.kind == "time_limit" { return lang == .ru ? "Поиск/MCP" : "Search/MCP" }
        if d.isBalance { return d.name }
        // Windowed percent entries (zhipu) reuse the codex window forms.
        if d.windowMinutes != nil { return codexBaseLabel(d, lang) }
        return d.name
    }

    private static func configMenuLabel(for limit: LimitEntry, _ lang: Language) -> String {
        configMenuLabel(descriptor(for: limit), lang)
    }

    // SPEC v0.4 pattern `<Name>: лимит <label> исчерпан`; single-entry providers
    // whose label IS the name collapse to `<Name>: лимит исчерпан`.
    private static func configExhaustedTitle(for limit: LimitEntry, _ lang: Language) -> String {
        let name = providerDisplayName(for: limit)
        if limit.balanceText != nil {
            return lang == .ru ? "\(name): баланс исчерпан" : "\(name): balance exhausted"
        }
        let label = configMenuLabel(for: limit, lang)
        if label == name {
            return lang == .ru ? "\(name): лимит исчерпан" : "\(name): limit exhausted"
        }
        return lang == .ru ? "\(name): лимит \(label) исчерпан" : "\(name): \(label) limit exhausted"
    }

    private static func configResetBody(for limit: LimitEntry, _ lang: Language) -> String {
        let name = providerDisplayName(for: limit)
        let label = configMenuLabel(for: limit, lang)
        if label == name {
            return lang == .ru ? "\(name): лимит сброшен." : "\(name): limit reset."
        }
        return lang == .ru ? "\(name): лимит \(label) сброшен." : "\(name): \(label) limit reset."
    }
}
