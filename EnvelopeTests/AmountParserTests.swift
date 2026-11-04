import XCTest
@testable import Envelope

final class AmountParserTests: XCTestCase {
    private func assertParses(_ input: String, cents: Int, currency: String?, file: StaticString = #filePath, line: UInt = #line) {
        let parsed = AmountParser.parse(input)
        XCTAssertEqual(parsed, ParsedAmount(cents: cents, currencyCode: currency), "input: \(input)", file: file, line: line)
    }

    /// Exactly what the Wallet automation sent for an FNB card on iOS 26.
    func testRealFNBWalletAmount() { assertParses("R 100.70", cents: 10070, currency: "ZAR") }
    func testRealFormatWithNonBreakingSpace() { assertParses("R\u{00A0}100.70", cents: 10070, currency: "ZAR") }
    func testRandWithDotDecimal() { assertParses("R45.00", cents: 4500, currency: "ZAR") }
    func testRandWithSpaceGroupingAndCommaDecimal() { assertParses("R 1 234,56", cents: 123456, currency: "ZAR") }
    func testRandWithNonBreakingSpace() { assertParses("R\u{00A0}12,30", cents: 1230, currency: "ZAR") }
    func testRandWithNarrowNoBreakSpaceGrouping() { assertParses("R1\u{202F}000,00", cents: 100000, currency: "ZAR") }
    func testCommaGroupingDotDecimal() { assertParses("R1,234.56", cents: 123456, currency: "ZAR") }
    func testDotGroupingCommaDecimal() { assertParses("1.234,56", cents: 123456, currency: nil) }
    func testISOCode() { assertParses("ZAR 99.99", cents: 9999, currency: "ZAR") }
    func testTrailingISOCode() { assertParses("99.99 ZAR", cents: 9999, currency: "ZAR") }
    func testSingleDecimalDigit() { assertParses("45,5", cents: 4550, currency: nil) }
    func testWholeNumber() { assertParses("1234", cents: 123400, currency: nil) }
    func testLoneSeparatorWithThreeDigitsIsGrouping() { assertParses("1,234", cents: 123400, currency: nil) }
    func testNegative() { assertParses("-R20.00", cents: -2000, currency: "ZAR") }
    func testFractionOfCentRoundsHalfUp() { assertParses("0.125", cents: 13, currency: nil) }
    func testDollar() { assertParses("$5.00", cents: 500, currency: "USD") }
    func testPlainDecimalDescription() { assertParses("42.5", cents: 4250, currency: nil) }

    func testRejectsEmptyAndNonNumeric() {
        XCTAssertNil(AmountParser.parse(""))
        XCTAssertNil(AmountParser.parse("   "))
        XCTAssertNil(AmountParser.parse("Transaction"))
    }
}
