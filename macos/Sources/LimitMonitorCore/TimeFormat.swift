import Foundation

public enum TimeFormat {
    private static let ruLocale = Locale(identifier: "ru_RU")
    // EN uses en_US_POSIX so weekday/month abbreviations are stable and
    // locale-independent regardless of the CI machine's region.
    private static let enLocale = Locale(identifier: "en_US_POSIX")

    private static func formatter(_ locale: Locale, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }

    // Both locales use 24-hour HH:mm (locale-independent output); the RU/EN split
    // matters only for weekday/month names below.
    private static let clockRU = formatter(ruLocale, "HH:mm")
    private static let clockEN = formatter(enLocale, "HH:mm")
    private static let weekdayRU = formatter(ruLocale, "EEE")
    private static let weekdayEN = formatter(enLocale, "EEE")
    private static let dayMonthRU = formatter(ruLocale, "d MMM")
    private static let dayMonthEN = formatter(enLocale, "MMM d")

    private static func clockFormatter(_ lang: Language) -> DateFormatter { lang == .ru ? clockRU : clockEN }

    public static func clock(_ date: Date, _ lang: Language) -> String {
        clockFormatter(lang).string(from: date)
    }

    static func isNear(_ date: Date, now: Date) -> Bool {
        if date.timeIntervalSince(now) < 24 * 3600 { return true }
        return Calendar.current.isDate(date, inSameDayAs: now)
    }

    /// Absolute local time. RU: same-day → `в HH:mm`, within a week → lowercase
    /// weekday + `HH:mm`, beyond → `d MMM` (ru_RU trailing month dot stripped) +
    /// `HH:mm`. EN mirrors it: `at HH:mm` / `EEE HH:mm` / `MMM d HH:mm`. The
    /// `lowercased(with:)`, month-dot strip and `в`/`at` preposition are gated
    /// per language.
    public static func absolute(_ date: Date, now: Date = Date(), _ lang: Language) -> String {
        let clock = clockFormatter(lang).string(from: date)
        switch lang {
        case .ru:
            if isNear(date, now: now) { return "в \(clock)" }
            if date.timeIntervalSince(now) < 7 * 24 * 3600 {
                return "\(weekdayRU.string(from: date).lowercased(with: ruLocale)) \(clock)"
            }
            // Beyond a week (cursor billing cycles): "7 авг 08:27" — ru_RU
            // abbreviates months with a trailing dot; drop it.
            let dayMonth = dayMonthRU.string(from: date)
                .lowercased(with: ruLocale)
                .replacingOccurrences(of: ".", with: "")
            return "\(dayMonth) \(clock)"
        case .en:
            if isNear(date, now: now) { return "at \(clock)" }
            if date.timeIntervalSince(now) < 7 * 24 * 3600 {
                return "\(weekdayEN.string(from: date)) \(clock)"
            }
            return "\(dayMonthEN.string(from: date)) \(clock)"
        }
    }

    /// Bare short form for the desktop card's `до …`/`until …` column — `absolute`
    /// without the same-day preposition: "12:30" / "пт 10:59" / "7 авг 08:27".
    public static func compact(_ date: Date, now: Date = Date(), _ lang: Language) -> String {
        let value = absolute(date, now: now, lang)
        switch lang {
        case .ru: return value.hasPrefix("в ") ? String(value.dropFirst(2)) : value
        case .en: return value.hasPrefix("at ") ? String(value.dropFirst(3)) : value
        }
    }

    public static func relative(_ date: Date, now: Date = Date(), _ lang: Language) -> String {
        let total = Int(date.timeIntervalSince(now).rounded())
        guard total > 0 else { return lang == .ru ? "сейчас" : "now" }
        let minutes = max(1, total / 60)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        switch lang {
        case .ru:
            let text: String
            if days > 0 {
                text = hours > 0 ? "\(days) дн. \(hours) ч" : "\(days) дн."
            } else if hours > 0 {
                text = mins > 0 ? "\(hours) ч \(mins) мин" : "\(hours) ч"
            } else {
                text = "\(mins) мин"
            }
            return "через \(text)"
        case .en:
            let text: String
            if days > 0 {
                text = hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
            } else if hours > 0 {
                text = mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
            } else {
                text = "\(mins)m"
            }
            return "in \(text)"
        }
    }
}
