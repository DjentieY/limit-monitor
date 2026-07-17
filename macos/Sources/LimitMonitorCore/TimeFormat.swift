import Foundation

public enum TimeFormat {
    private static let ruLocale = Locale(identifier: "ru_RU")

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = ruLocale
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = ruLocale
        f.dateFormat = "EEE"
        return f
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = ruLocale
        f.dateFormat = "d MMM"
        return f
    }()

    public static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    static func isNear(_ date: Date, now: Date) -> Bool {
        if date.timeIntervalSince(now) < 24 * 3600 { return true }
        return Calendar.current.isDate(date, inSameDayAs: now)
    }

    public static func absolute(_ date: Date, now: Date = Date()) -> String {
        if isNear(date, now: now) { return "в \(clockFormatter.string(from: date))" }
        if date.timeIntervalSince(now) < 7 * 24 * 3600 {
            let weekday = weekdayFormatter.string(from: date).lowercased(with: ruLocale)
            return "\(weekday) \(clockFormatter.string(from: date))"
        }
        // Beyond a week (cursor billing cycles) a weekday alone is ambiguous:
        // "7 авг 08:27" (ru_RU abbreviates months with a trailing dot — drop it).
        let dayMonth = dayMonthFormatter.string(from: date)
            .lowercased(with: ruLocale)
            .replacingOccurrences(of: ".", with: "")
        return "\(dayMonth) \(clockFormatter.string(from: date))"
    }

    /// Bare short form for the desktop card's `до …` column — `absolute`
    /// without the same-day `в` preposition: "12:30" / "пт 10:59" / "7 авг 08:27".
    public static func compact(_ date: Date, now: Date = Date()) -> String {
        let absolute = absolute(date, now: now)
        return absolute.hasPrefix("в ") ? String(absolute.dropFirst(2)) : absolute
    }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let total = Int(date.timeIntervalSince(now).rounded())
        guard total > 0 else { return "сейчас" }
        let minutes = max(1, total / 60)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        let text: String
        if days > 0 {
            text = hours > 0 ? "\(days) дн. \(hours) ч" : "\(days) дн."
        } else if hours > 0 {
            text = mins > 0 ? "\(hours) ч \(mins) мин" : "\(hours) ч"
        } else {
            text = "\(mins) мин"
        }
        return "через \(text)"
    }
}
