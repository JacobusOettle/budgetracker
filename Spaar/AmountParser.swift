import Foundation

struct ParsedAmount: Equatable {
    let cents: Int
    /// ISO code if one could be detected ("R" is treated as ZAR).
    let currencyCode: String?
}

/// Parses an amount that arrived as text from Shortcuts. We don't know the
/// exact format the Transaction trigger produces (it may depend on region
/// settings), so this accepts the common variants:
/// "R45.00", "R 1 234,56", "R1,234.56", "ZAR 99.99", "45,5", "-R20.00".
enum AmountParser {
    static func parse(_ input: String) -> ParsedAmount? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let negative = text.contains("-") || text.contains("\u{2212}")
            || (text.hasPrefix("(") && text.hasSuffix(")"))

        // Keep only ASCII digits and the two candidate separators. Spaces
        // (including non-breaking and narrow no-break) are thousands groups.
        let numeric = String(text.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") })
        guard numeric.contains(where: { $0.isNumber }) else { return nil }

        let decimalSeparator = detectDecimalSeparator(in: numeric)
        var normalized = ""
        for ch in numeric {
            if ch.isNumber {
                normalized.append(ch)
            } else if ch == decimalSeparator {
                normalized.append(".")
            }
            // other separators are grouping: drop them
        }

        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        let cents = Money.cents(from: value)
        return ParsedAmount(cents: negative ? -cents : cents, currencyCode: detectCurrency(in: text))
    }

    private static func detectDecimalSeparator(in numeric: String) -> Character? {
        let lastDot = numeric.lastIndex(of: ".")
        let lastComma = numeric.lastIndex(of: ",")
        switch (lastDot, lastComma) {
        case let (dot?, comma?):
            return dot > comma ? "." : ","
        case let (dot?, nil):
            return looksDecimal(numeric, separator: ".", at: dot) ? "." : nil
        case let (nil, comma?):
            return looksDecimal(numeric, separator: ",", at: comma) ? "," : nil
        default:
            return nil
        }
    }

    /// A lone separator is decimal if it appears once and is followed by 1-2
    /// digits ("45.5", "45,50"), or if the whole part is zero ("0.125").
    /// "1,234" or "1.234" is treated as thousands grouping.
    private static func looksDecimal(_ numeric: String, separator: Character, at index: String.Index) -> Bool {
        guard numeric.filter({ $0 == separator }).count == 1 else { return false }
        let after = numeric[numeric.index(after: index)...]
        let before = numeric[..<index]
        if (1...2).contains(after.count) { return true }
        return before.isEmpty || before.allSatisfy { $0 == "0" }
    }

    private static func detectCurrency(in text: String) -> String? {
        let upper = text.uppercased()
        if let range = upper.range(of: "\\b[A-Z]{3}\\b", options: .regularExpression) {
            return String(upper[range])
        }
        if text.range(of: "(^|[^A-Za-z])R(?![A-Za-z])", options: .regularExpression) != nil {
            return "ZAR"
        }
        if text.contains("$") { return "USD" }
        if text.contains("€") { return "EUR" }
        if text.contains("£") { return "GBP" }
        return nil
    }
}
