import Foundation

/// Balance amounts for bar segments and menu rows: `$23.45`, `¥0.00`, `€12.50`,
/// `23.45 XXX` for unknown codes, `$1.2k` at >= 1000, negatives as `-$2.31`.
public enum BalanceFormat {
    private static func makeFormatter(fractionDigits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        f.roundingMode = .halfUp
        return f
    }

    private static let twoDecimals = makeFormatter(fractionDigits: 2)
    private static let oneDecimal = makeFormatter(fractionDigits: 1)
    private static let symbols = ["USD": "$", "CNY": "¥", "EUR": "€"]

    public static func text(_ amount: Decimal, currency: String) -> String {
        let negative = amount < 0
        let magnitude = negative ? -amount : amount
        let number: String
        if magnitude >= 1000 {
            let thousands = NSDecimalNumber(decimal: magnitude / 1000)
            number = (oneDecimal.string(from: thousands) ?? "?") + "k"
        } else {
            number = twoDecimals.string(from: NSDecimalNumber(decimal: magnitude)) ?? "?"
        }
        let sign = negative ? "-" : ""
        if let symbol = symbols[currency.uppercased()] {
            return sign + symbol + number
        }
        return sign + number + " " + currency
    }
}
