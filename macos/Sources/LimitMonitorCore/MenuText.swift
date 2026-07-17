import Foundation

public enum MenuText {
    public static func infoRow(for limit: LimitEntry, now: Date = Date(), _ lang: Language) -> String {
        let label = Labels.menuLabel(for: limit, lang)
        if limit.unlimited { return MenuStr.unlimited(label: label).text(lang) }
        if let balanceText = limit.balanceText {
            if limit.isExhausted { return MenuStr.balanceExhausted(label: label).text(lang) }
            return MenuStr.balanceRemaining(label: label, balance: balanceText).text(lang)
        }
        if limit.isExhausted {
            guard let date = limit.resetsAt else { return MenuStr.exhaustedBare(label: label).text(lang) }
            return MenuStr.exhaustedWithReset(label: label, reset: when(date, now: now, lang)).text(lang)
        }
        guard let date = limit.resetsAt else {
            return MenuStr.percentBare(label: label, percent: limit.percent).text(lang)
        }
        return MenuStr.percentWithReset(label: label, percent: limit.percent, reset: when(date, now: now, lang)).text(lang)
    }

    // Near a reset → absolute + relative ("в 01:59 (через 2 ч 14 мин)"); far →
    // absolute only. The joining punctuation is neutral; the language lives in
    // TimeFormat.absolute/relative.
    private static func when(_ date: Date, now: Date, _ lang: Language) -> String {
        if TimeFormat.isNear(date, now: now) {
            return "\(TimeFormat.absolute(date, now: now, lang)) (\(TimeFormat.relative(date, now: now, lang)))"
        }
        return TimeFormat.absolute(date, now: now, lang)
    }

    /// Menu/`--check` line for a config provider that has no data rows. The `.ok`
    /// case is just the provider name; every other `ProviderState` maps to a
    /// `StateStr` row. Inner messages arrive already localized from the adapters.
    public static func stateRow(name: String, state: ProviderState, _ lang: Language) -> String {
        switch state {
        case .ok:
            return name
        case .configError(let reason):
            return StateStr.configError(name: name, reason: reason).text(lang)
        case .keyError(let message), .badKey(let message), .info(let message), .fetchError(let message):
            return StateStr.message(name: name, message: message).text(lang)
        case .noPlan:
            return StateStr.noPlan(name: name).text(lang)
        case .blocked:
            return StateStr.blocked(name: name).text(lang)
        case .parseError(let message):
            return StateStr.parseError(name: name, message: message).text(lang)
        }
    }
}
