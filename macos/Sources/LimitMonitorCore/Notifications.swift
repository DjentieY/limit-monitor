import Foundation

public struct PlannedReset: Equatable {
    public let identifier: String
    public let fireDate: Date
    public let title: String
    public let body: String
}

public struct PlannedExhaustion: Equatable {
    public let identifier: String
    public let title: String
    public let body: String
}

public struct NotificationPlan {
    public let scheduled: [PlannedReset]
    public let immediate: [PlannedExhaustion]
    public let prunedNotified: [String: Bool]
}

public enum NotificationPlanner {
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+00:00'"
        return f
    }()

    // The API recomputes resets_at per request with sub-second jitter that straddles
    // minute boundaries; identifiers must stay stable across polls, so round to the
    // nearest minute and re-serialize a canonical UTC stamp (raw value kept for display).
    public static func normalizedResetStamp(_ date: Date?) -> String {
        guard let date else { return "" }
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
        return stampFormatter.string(from: rounded)
    }

    public static func resetIdentifier(for limit: LimitEntry) -> String {
        "reset|\(limit.provider)|\(limit.kind)|\(limit.scopeDisplayName ?? "")|\(normalizedResetStamp(limit.resetsAt))"
    }

    public static func exhaustedIdentifier(for limit: LimitEntry) -> String {
        "exhausted|\(limit.provider)|\(limit.kind)|\(limit.scopeDisplayName ?? "")|\(normalizedResetStamp(limit.resetsAt))"
    }

    /// Provider segment of a reset|/exhausted| identifier; legacy v0.1 4-part
    /// identifiers (no provider segment) belong to claude.
    public static func identifierProvider(_ identifier: String) -> String {
        let parts = identifier.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count >= 5 ? String(parts[1]) : Provider.claude
    }

    /// Parsed stamp (last segment) of an identifier; nil when empty or unparseable.
    public static func identifierStampDate(_ identifier: String) -> Date? {
        let parts = identifier.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 4, let stamp = parts.last else { return nil }
        return ISODateParser.parse(String(stamp))
    }

    public static func plan(
        limits: [LimitEntry],
        now: Date,
        alreadyNotified: [String: Bool]
    ) -> NotificationPlan {
        var scheduled: [PlannedReset] = []
        var immediate: [PlannedExhaustion] = []
        for limit in limits {
            if limit.unlimited { continue }
            if let date = limit.resetsAt, date > now, limit.percent >= 1 {
                scheduled.append(PlannedReset(
                    identifier: resetIdentifier(for: limit),
                    fireDate: date.addingTimeInterval(5),
                    title: Labels.resetTitle(for: limit),
                    body: Labels.resetBody(for: limit)
                ))
            }
            if limit.isExhausted {
                let identifier = exhaustedIdentifier(for: limit)
                if alreadyNotified[identifier] != true {
                    let body: String
                    if let balanceText = limit.balanceText {
                        // Balance exhaustion (v0.4): `Осталось $0.00.`
                        body = "Осталось \(balanceText)."
                    } else if let date = limit.resetsAt {
                        body = "Возобновится \(TimeFormat.relative(date, now: now)) (\(TimeFormat.absolute(date, now: now)))."
                    } else {
                        body = "Время возобновления неизвестно."
                    }
                    immediate.append(PlannedExhaustion(
                        identifier: identifier,
                        title: Labels.exhaustedTitle(for: limit),
                        body: body
                    ))
                }
            }
        }
        // Prune persisted identifiers. The stamp is always the LAST segment, which also
        // keeps legacy v0.1 4-part keys (no provider segment) from crashing or sticking:
        // parseable stamps prune once passed, anything else is dropped as soon as no
        // currently-exhausted limit produces the same identifier.
        var pruned = alreadyNotified
        let stillExhausted = Set(limits.filter(\.isExhausted).map { exhaustedIdentifier(for: $0) })
        for key in alreadyNotified.keys {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 4, let stamp = parts.last, let date = ISODateParser.parse(stamp) {
                if date <= now { pruned.removeValue(forKey: key) }
            } else if !stillExhausted.contains(key) {
                pruned.removeValue(forKey: key)
            }
        }
        return NotificationPlan(scheduled: scheduled, immediate: immediate, prunedNotified: pruned)
    }
}
