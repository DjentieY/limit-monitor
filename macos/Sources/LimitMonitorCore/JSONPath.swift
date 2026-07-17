import Foundation

/// Dot-path extraction over JSONSerialization trees. A path is segments split on
/// ".", where an integer segment indexes an array (`balance_infos.0.total_balance`,
/// `total.val`, `credits`). Numeric values may be JSON numbers OR decimal strings
/// (thousands commas stripped) — everything is parsed via `Decimal`.
public enum JSONPath {
    private static let posix = Locale(identifier: "en_US_POSIX")

    public static func value(at path: String, in root: Any) -> Any? {
        guard !path.isEmpty else { return nil }
        var current: Any = root
        for segment in path.split(separator: ".") {
            let key = String(segment)
            if let dict = current as? [String: Any] {
                guard let next = dict[key] else { return nil }
                current = next
            } else if let array = current as? [Any] {
                guard let index = Int(key), index >= 0, index < array.count else { return nil }
                current = array[index]
            } else {
                return nil
            }
        }
        if current is NSNull { return nil }
        return current
    }

    /// JSON number or decimal string ("1,234.56" → 1234.56). Booleans are NOT numbers.
    public static func decimal(_ any: Any?) -> Decimal? {
        if let string = any as? String {
            let cleaned = string
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return Decimal(string: cleaned, locale: posix)
        }
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Decimal(string: number.stringValue, locale: posix)
        }
        return nil
    }

    public static func decimal(at path: String, in root: Any) -> Decimal? {
        decimal(value(at: path, in: root))
    }

    /// Strict JSON booleans only (a numeric 0/1 is not a flag).
    public static func bool(_ any: Any?) -> Bool? {
        guard let number = any as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    public static func bool(at path: String, in root: Any) -> Bool? {
        bool(value(at: path, in: root))
    }

    public static func int(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    /// Half-up integer rounding for percent math (25.5 → 26, 37.4 → 37, 6.6 → 7).
    public static func roundedInt(_ value: Decimal) -> Int {
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0,
            raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: value).rounding(accordingToBehavior: handler).intValue
    }
}
