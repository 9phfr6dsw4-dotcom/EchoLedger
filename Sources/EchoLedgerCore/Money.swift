import Foundation

/// Money is always whole cents (minor units) in an `Int64`. Nothing is ever stored or added as
/// a floating-point number.
public typealias Cents = Int64

public enum Money {
    /// Parses a bank amount exactly. Accepts `$1,234.56`, `(45.00)`, `-$3`, `45.00-`, `+12.5`,
    /// `−7.10` (Unicode minus) and `USD 4`. Rejects anything that would need rounding or guessing:
    /// `12.345`, `1,23.4`, `abc`, `1.2.3`. Returns nil for empty or invalid text.
    public static func parseCents(_ raw: String) -> Cents? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        text = text.replacingOccurrences(of: "\u{2212}", with: "-")
        text = text.replacingOccurrences(of: "USD", with: "")
        text = text.replacingOccurrences(of: "$", with: "")
        text = text.replacingOccurrences(of: " ", with: "")
        text = text.replacingOccurrences(of: "\u{00A0}", with: "")
        if text.isEmpty { return nil }

        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("-") {
            negative.toggle()
            text = String(text.dropFirst())
        } else if text.hasPrefix("+") {
            text = String(text.dropFirst())
        } else if text.hasSuffix("-") {
            negative.toggle()
            text = String(text.dropLast())
        }
        // A currency sign after the minus ("-$3") was already removed above.
        guard !text.isEmpty else { return nil }

        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        let wholeText = String(pieces[0])
        let fractionText = pieces.count == 2 ? String(pieces[1]) : ""
        guard fractionText.count <= 2, fractionText.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        if pieces.count == 2, fractionText.isEmpty, wholeText.isEmpty { return nil }

        guard let whole = parseWhole(wholeText) else { return nil }
        var fraction: Int64 = 0
        if fractionText.count == 1, let digit = Int64(fractionText) {
            fraction = digit * 10
        } else if fractionText.count == 2, let digits = Int64(fractionText) {
            fraction = digits
        }
        guard whole <= 900_000_000_000 else { return nil }
        let cents = whole * 100 + fraction
        return negative ? -cents : cents
    }

    /// Whole-dollar part with optional, correctly grouped thousands separators.
    private static func parseWhole(_ text: String) -> Int64? {
        if text.isEmpty { return 0 }
        if text.contains(",") {
            let groups = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let first = groups.first, (1...3).contains(first.count) else { return nil }
            for group in groups.dropFirst() where group.count != 3 {
                return nil
            }
            let joined = groups.joined()
            guard joined.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int64(joined)
        }
        guard text.allSatisfy({ $0 >= "0" && $0 <= "9" }), text.count <= 13 else { return nil }
        return Int64(text)
    }

    /// "$1,234.56" / "−$1,234.56". `plain` uses an ASCII hyphen (for CSV files).
    public static func format(_ cents: Cents, currency: String = "USD", plain: Bool = false, showPlus: Bool = false) -> String {
        let magnitude = cents.magnitude
        let dollars = magnitude / 100
        let remainder = magnitude % 100
        let fraction = remainder < 10 ? "0\(remainder)" : "\(remainder)"
        let body = grouped(dollars) + "." + fraction
        let symbol = currency == "USD" ? "$" : currency + " "
        let sign: String
        if cents < 0 {
            sign = plain ? "-" : "\u{2212}"
        } else if showPlus && cents > 0 {
            sign = "+"
        } else {
            sign = ""
        }
        return sign + symbol + body
    }

    /// Whole dollars, rounded half away from zero: "$1,235".
    public static func formatWhole(_ cents: Cents, currency: String = "USD") -> String {
        let rounded = (cents.magnitude + 50) / 100
        let symbol = currency == "USD" ? "$" : currency + " "
        return (cents < 0 ? "\u{2212}" : "") + symbol + grouped(rounded)
    }

    /// Plain decimal for CSV export: "-1234.56".
    public static func decimalString(_ cents: Cents) -> String {
        let magnitude = cents.magnitude
        let remainder = magnitude % 100
        let fraction = remainder < 10 ? "0\(remainder)" : "\(remainder)"
        return (cents < 0 ? "-" : "") + "\(magnitude / 100).\(fraction)"
    }

    static func grouped(_ value: UInt64) -> String {
        let digits = String(value)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }

    /// A change in percent between two amounts, as tenths of a percent (123 = 12.3%).
    /// nil when the old amount is zero.
    public static func changeTenthsOfPercent(from old: Cents, to new: Cents) -> Int? {
        guard old != 0 else { return nil }
        let numerator = (new - old) * 1000
        let denominator = old.magnitude
        // Round half away from zero using integers only.
        let value = numerator >= 0
            ? (numerator + Int64(denominator / 2)) / Int64(denominator)
            : -((-numerator + Int64(denominator / 2)) / Int64(denominator))
        return Int(value)
    }

    /// "12.3%" / "−4.0%" from tenths of a percent.
    public static func percentText(tenths: Int, showPlus: Bool = false) -> String {
        let magnitude = abs(tenths)
        let sign = tenths < 0 ? "\u{2212}" : (showPlus && tenths > 0 ? "+" : "")
        return "\(sign)\(magnitude / 10).\(magnitude % 10)%"
    }

    /// part / whole as tenths of a percent, rounded half up. nil when whole is not positive.
    public static func shareTenths(_ part: Cents, of whole: Cents) -> Int? {
        guard whole > 0 else { return nil }
        let numerator = part * 1000
        if numerator >= 0 {
            return Int((numerator + whole / 2) / whole)
        }
        return -Int((-numerator + whole / 2) / whole)
    }
}
