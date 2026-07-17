import Foundation

/// Parser for the cursor.com `usage-summary` response (fixtures are the source
/// of truth). Cursor has no session/weekly windows — every bucket resets at
/// `billingCycleEnd`. Buckets: Auto+Composer (plan.totalPercentUsed — NOT
/// autoPercentUsed, whose denominator does not match the Cursor UI), API
/// (plan.apiPercentUsed), On-demand (only when onDemand.enabled).
public enum CursorUsageParser {
    public static func parseLimits(data: Data) -> [LimitEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return [] }
        return parseLimits(root: root)
    }

    public static func parseLimits(root: [String: Any]) -> [LimitEntry] {
        let resetsAtRaw = root["billingCycleEnd"] as? String
        let resetsAt = resetsAtRaw.flatMap(ISODateParser.parse)
        if root["isUnlimited"] as? Bool == true {
            return [LimitEntry(
                provider: Provider.cursor,
                kind: "cursor_unlimited",
                percent: 0,
                resetsAtRaw: resetsAtRaw,
                resetsAt: resetsAt,
                unlimited: true,
                isActive: true
            )]
        }
        let individual = root["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        var entries: [LimitEntry] = []
        if let percent = bucketPercent(
            numeric: plan?["totalPercentUsed"],
            message: root["autoModelSelectedDisplayMessage"] as? String
        ) {
            entries.append(entry(kind: "cursor_auto", percent: percent,
                                 resetsAtRaw: resetsAtRaw, resetsAt: resetsAt))
        }
        if let percent = bucketPercent(
            numeric: plan?["apiPercentUsed"],
            message: root["namedModelSelectedDisplayMessage"] as? String
        ) {
            entries.append(entry(kind: "cursor_api", percent: percent,
                                 resetsAtRaw: resetsAtRaw, resetsAt: resetsAt))
        }
        if let onDemand = individual?["onDemand"] as? [String: Any],
           onDemand["enabled"] as? Bool == true {
            let limit = doubleValue(onDemand["limit"])
            if limit == nil || limit == 0 {
                var unlimited = entry(kind: "cursor_on_demand", percent: 0,
                                      resetsAtRaw: resetsAtRaw, resetsAt: resetsAt)
                unlimited.unlimited = true
                entries.append(unlimited)
            } else if let limit, let used = doubleValue(onDemand["used"]) {
                entries.append(entry(kind: "cursor_on_demand",
                                     percent: Int((100 * used / limit).rounded()),
                                     resetsAtRaw: resetsAtRaw, resetsAt: resetsAt))
            }
        }
        return entries
    }

    private static func entry(kind: String, percent: Int,
                              resetsAtRaw: String?, resetsAt: Date?) -> LimitEntry {
        LimitEntry(
            provider: Provider.cursor,
            kind: kind,
            percent: percent,
            resetsAtRaw: resetsAtRaw,
            resetsAt: resetsAt,
            isActive: true
        )
    }

    // Numeric percent field first; fallback: first integer before "%" in the
    // corresponding display message ("You've used 2% of ..." → 2). Both missing
    // → nil, the bucket is skipped defensively.
    private static func bucketPercent(numeric: Any?, message: String?) -> Int? {
        if let value = doubleValue(numeric) { return Int(value.rounded()) }
        guard let message,
              let range = message.range(of: "[0-9]+%", options: .regularExpression),
              let value = Int(message[range].dropLast()) else { return nil }
        return value
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }
}
