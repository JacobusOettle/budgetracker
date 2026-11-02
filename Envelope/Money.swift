import Foundation

/// Money helpers. Amounts are stored as integer cents; Decimal is used for
/// any arithmetic on fractional values. Double is never used for money.
enum Money {
    /// Converts a rand Decimal to cents, rounding half away from zero
    /// (R0.005 -> 1c, -R0.005 -> -1c).
    static func cents(from value: Decimal) -> Int {
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// Formats cents as rand, e.g. 123456 -> "R1 234.56", -5 -> "-R0.05".
    static func format(cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let magnitude = cents.magnitude
        let rands = String(magnitude / 100)
        let remainder = magnitude % 100

        var groups: [String] = []
        var digits = Substring(rands)
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits = digits.dropLast(3)
        }
        groups.insert(String(digits), at: 0)

        let centsText = remainder < 10 ? "0\(remainder)" : "\(remainder)"
        return "\(sign)R\(groups.joined(separator: " ")).\(centsText)"
    }
}
