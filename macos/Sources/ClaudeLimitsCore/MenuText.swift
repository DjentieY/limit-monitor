import Foundation

public enum MenuText {
    public static func infoRow(for limit: LimitEntry, now: Date = Date()) -> String {
        let label = Labels.menuLabel(for: limit)
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
}
