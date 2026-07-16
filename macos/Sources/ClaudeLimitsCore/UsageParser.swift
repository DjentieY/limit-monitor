import Foundation

public enum UsageParser {
    public static func parseLimits(data: Data) -> [LimitEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return [] }
        return parseLimits(root: root)
    }

    public static func parseLimits(root: [String: Any]) -> [LimitEntry] {
        if let array = root["limits"] as? [Any] {
            let parsed = array.compactMap(parseEntry)
            if !parsed.isEmpty { return parsed }
        }
        return legacyEntries(root: root)
    }

    private static func parseEntry(_ any: Any) -> LimitEntry? {
        guard let dict = any as? [String: Any],
              let kind = dict["kind"] as? String,
              let percent = intValue(dict["percent"]) else { return nil }
        let raw = dict["resets_at"] as? String
        var scopeName: String?
        if let scope = dict["scope"] as? [String: Any] {
            if let model = scope["model"] as? [String: Any] {
                scopeName = model["display_name"] as? String
            }
            if scopeName == nil { scopeName = scope["display_name"] as? String }
        }
        return LimitEntry(
            kind: kind,
            group: dict["group"] as? String,
            percent: percent,
            severity: dict["severity"] as? String ?? "normal",
            resetsAtRaw: raw,
            resetsAt: raw.flatMap(ISODateParser.parse),
            scopeDisplayName: scopeName,
            isActive: dict["is_active"] as? Bool ?? false
        )
    }

    private static func legacyEntries(root: [String: Any]) -> [LimitEntry] {
        var entries: [LimitEntry] = []
        if let e = legacyEntry(root["five_hour"], kind: "session", group: "session") { entries.append(e) }
        if let e = legacyEntry(root["seven_day"], kind: "weekly_all", group: "weekly") { entries.append(e) }
        return entries
    }

    private static func legacyEntry(_ any: Any?, kind: String, group: String) -> LimitEntry? {
        guard let dict = any as? [String: Any],
              let percent = intValue(dict["utilization"]) else { return nil }
        let raw = dict["resets_at"] as? String
        return LimitEntry(
            kind: kind,
            group: group,
            percent: percent,
            severity: "normal",
            resetsAtRaw: raw,
            resetsAt: raw.flatMap(ISODateParser.parse),
            scopeDisplayName: nil,
            isActive: true
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let int as Int: return int
        case let double as Double: return Int(double.rounded())
        case let number as NSNumber: return number.intValue
        default: return nil
        }
    }
}
