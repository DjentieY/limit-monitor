import Foundation

public enum ISODateParser {
    private static let formats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
    ]

    private static let formatters: [DateFormatter] = formats.map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain = ISO8601DateFormatter()

    private static let utcWriter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+00:00'"
        return f
    }()

    /// Canonical UTC serialization (seconds precision, `+00:00` suffix) —
    /// notification stamps and snapshot dates share this exact form.
    public static func utcString(from date: Date) -> String {
        utcWriter.string(from: date)
    }

    public static func parse(_ string: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: string) { return date }
        }
        if let date = iso8601Fractional.date(from: string) { return date }
        return iso8601Plain.date(from: string)
    }
}
