import Foundation

public enum MenuText {
    public static func infoRow(for limit: LimitEntry, now: Date = Date()) -> String {
        let label = Labels.menuLabel(for: limit)
        if limit.unlimited { return "\(label): безлимит" }
        if let balanceText = limit.balanceText {
            if limit.isExhausted { return "\(label): баланс исчерпан" }
            return "\(label): осталось \(balanceText)"
        }
        if limit.isExhausted {
            guard let date = limit.resetsAt else { return "\(label): исчерпан" }
            return "\(label): исчерпан · возобновится \(when(date, now: now))"
        }
        guard let date = limit.resetsAt else { return "\(label): \(limit.percent)%" }
        return "\(label): \(limit.percent)% · сброс \(when(date, now: now))"
    }

    private static func when(_ date: Date, now: Date) -> String {
        if TimeFormat.isNear(date, now: now) {
            return "\(TimeFormat.absolute(date, now: now)) (\(TimeFormat.relative(date, now: now)))"
        }
        return TimeFormat.absolute(date, now: now)
    }

    /// Menu/`--check` line for a config provider that has no data rows —
    /// RU strings per SPEC v0.4.
    public static func stateRow(name: String, state: ProviderState) -> String {
        switch state {
        case .ok:
            return name
        case .configError(let reason):
            return "\(name): ошибка конфига — \(reason)"
        case .keyError(let message):
            return "\(name): \(message)"
        case .badKey(let detail):
            return "\(name): \(detail)"
        case .noPlan:
            return "\(name): нет Coding Plan (PAYG-ключ)"
        case .blocked:
            return "\(name) недоступен (гео-блокировка)"
        case .info(let message):
            return "\(name): \(message)"
        case .fetchError(let message):
            return "\(name): \(message)"
        case .parseError(let message):
            return "\(name): ошибка разбора — \(message)"
        }
    }
}
