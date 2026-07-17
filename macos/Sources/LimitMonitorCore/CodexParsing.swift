import Foundation

/// Alias-tolerant parser for the ChatGPT/Codex usage response. The schema is
/// community-documented and drifts across versions, so every level accepts the
/// known field aliases; `now` anchors relative reset offsets.
public enum CodexUsageParser {
    public static func parseLimits(data: Data, now: Date) -> [LimitEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return [] }
        return parseLimits(root: root, now: now)
    }

    public static func parseLimits(root: [String: Any], now: Date) -> [LimitEntry] {
        var entries: [LimitEntry] = []
        if let window = window(named: ["primary_window", "primary"], in: root),
           let entry = entry(from: window, role: .primary, now: now) {
            entries.append(entry)
        }
        if let window = window(named: ["secondary_window", "secondary"], in: root),
           let entry = entry(from: window, role: .secondary, now: now) {
            entries.append(entry)
        }
        for window in additionalWindows(in: root) {
            if let entry = entry(from: window, role: .additional, now: now) {
                entries.append(entry)
            }
        }
        return entries
    }

    private enum Role {
        case primary
        case secondary
        case additional
    }

    // Windows may sit under "rate_limit"/"rate_limits" or at the top level.
    private static func containers(in root: [String: Any]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let dict = root["rate_limit"] as? [String: Any] { result.append(dict) }
        if let dict = root["rate_limits"] as? [String: Any] { result.append(dict) }
        result.append(root)
        return result
    }

    private static func window(named names: [String], in root: [String: Any]) -> [String: Any]? {
        for container in containers(in: root) {
            for name in names {
                if let dict = container[name] as? [String: Any] { return dict }
            }
        }
        return nil
    }

    private static func additionalWindows(in root: [String: Any]) -> [[String: Any]] {
        for container in containers(in: root) {
            if let array = container["additional_rate_limits"] as? [Any] {
                return array.compactMap { $0 as? [String: Any] }
            }
        }
        return []
    }

    private static func entry(from dict: [String: Any], role: Role, now: Date) -> LimitEntry? {
        guard let percent = percent(from: dict) else { return nil }
        let minutes = windowMinutes(from: dict)
        let (resetsAt, resetsAtRaw) = resetDate(from: dict, now: now)
        var scopeName: String?
        if role == .additional {
            scopeName = (dict["name"] ?? dict["label"] ?? dict["display_name"]) as? String
        }
        return LimitEntry(
            provider: Provider.codex,
            kind: kind(role: role, windowMinutes: minutes),
            group: role == .primary ? "session" : "weekly",
            percent: percent,
            severity: "normal",
            resetsAtRaw: resetsAtRaw,
            resetsAt: resetsAt,
            scopeDisplayName: scopeName,
            windowMinutes: minutes,
            isActive: true
        )
    }

    private static func kind(role: Role, windowMinutes: Int?) -> String {
        switch role {
        case .primary:
            guard let minutes = windowMinutes, minutes > 360 else { return "session" }
            return "window_\(minutes)m"
        case .secondary:
            guard let minutes = windowMinutes, abs(minutes - 10080) > 1440 else { return "weekly_all" }
            return "window_\(minutes)m"
        case .additional:
            guard let minutes = windowMinutes, abs(minutes - 10080) > 1440 else { return "weekly_scoped" }
            return "window_\(minutes)m"
        }
    }

    // used_percent | percent_used | 100 - percent_left | 100 - percent_remaining
    private static func percent(from dict: [String: Any]) -> Int? {
        if let used = doubleValue(dict["used_percent"]) ?? doubleValue(dict["percent_used"]) {
            return Int(used.rounded())
        }
        if let left = doubleValue(dict["percent_left"]) ?? doubleValue(dict["percent_remaining"]) {
            return Int((100 - left).rounded())
        }
        return nil
    }

    // resets_at (ISO8601 | epoch s) | reset_at | reset_time_ms | now + resets_in_seconds
    // | now + reset_after_seconds
    private static func resetDate(from dict: [String: Any], now: Date) -> (Date?, String?) {
        for key in ["resets_at", "reset_at"] {
            guard let value = dict[key] else { continue }
            if let string = value as? String {
                if let date = ISODateParser.parse(string) { return (date, string) }
                if let epoch = Double(string) { return (Date(timeIntervalSince1970: epoch), nil) }
                return (nil, string)
            }
            if let epoch = doubleValue(value) {
                return (Date(timeIntervalSince1970: epoch), nil)
            }
        }
        if let ms = doubleValue(dict["reset_time_ms"]) {
            return (Date(timeIntervalSince1970: ms / 1000), nil)
        }
        for key in ["resets_in_seconds", "reset_after_seconds"] {
            if let seconds = doubleValue(dict[key]) {
                return (now.addingTimeInterval(seconds), nil)
            }
        }
        return (nil, nil)
    }

    // window_minutes | limit_window_seconds / 60
    private static func windowMinutes(from dict: [String: Any]) -> Int? {
        if let minutes = doubleValue(dict["window_minutes"]) { return Int(minutes.rounded()) }
        if let seconds = doubleValue(dict["limit_window_seconds"]) { return Int((seconds / 60).rounded()) }
        return nil
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
