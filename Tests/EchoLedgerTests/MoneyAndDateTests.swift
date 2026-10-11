import XCTest
@testable import EchoLedgerCore

final class MoneyAndDateTests: XCTestCase {
    func testParsesBankAmountsExactly() {
        let cases: [(String, Cents?)] = [
            ("$1,234.56", 123_456), ("(45.00)", -4_500), ("-$3", -300), ("45.00-", -4_500), ("+12.5", 1_250),
            ("\u{2212}7.10", -710), ("USD 4", 400), ("0.5", 50), (".5", 50), ("1,234,567.89", 123_456_789),
            ("$ 1,000", 100_000), ("(-5)", 500)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(Money.parseCents(text), expected, text)
        }
    }

    func testRejectsAmountsThatWouldNeedGuessing() {
        for text in ["12.345", "1,23.4", "abc", "1.2.3", "", "12,", "--5"] {
            XCTAssertNil(Money.parseCents(text), text)
        }
    }

    func testFormatsMoney() {
        XCTAssertEqual(Money.format(123_456), "$1,234.56")
        XCTAssertEqual(Money.format(-500), "\u{2212}$5.00")
        XCTAssertEqual(Money.format(5), "$0.05")
        XCTAssertEqual(Money.format(-500, plain: true), "-$5.00")
        XCTAssertEqual(Money.format(250, showPlus: true), "+$2.50")
        XCTAssertEqual(Money.decimalString(-123_456), "-1234.56")
        XCTAssertEqual(Money.decimalString(5), "0.05")
        XCTAssertEqual(Money.formatWhole(123_456), "$1,235")
    }

    func testPercentagesUseIntegerArithmetic() {
        XCTAssertEqual(Money.changeTenthsOfPercent(from: 10_000, to: 11_234), 123)
        XCTAssertEqual(Money.changeTenthsOfPercent(from: 10_000, to: 9_000), -100)
        XCTAssertNil(Money.changeTenthsOfPercent(from: 0, to: 5))
        XCTAssertEqual(Money.percentText(tenths: 123), "12.3%")
        XCTAssertEqual(Money.percentText(tenths: -40), "\u{2212}4.0%")
        XCTAssertEqual(Money.percentText(tenths: 5, showPlus: true), "+0.5%")
        XCTAssertEqual(Money.shareTenths(363_442, of: 420_125), 865)
        XCTAssertNil(Money.shareTenths(5, of: 0))
    }

    func testDateArithmetic() {
        XCTAssertEqual(day("1970-01-01").dayNumber, 0)
        XCTAssertEqual(day("2026-10-11").dayNumber, 20_737)
        XCTAssertEqual(LocalDate(dayNumber: 20_737), day("2026-10-11"))
        for number in stride(from: -1_000, through: 30_000, by: 37) {
            XCTAssertEqual(LocalDate(dayNumber: number).dayNumber, number)
        }
        XCTAssertEqual(day("2026-01-31").adding(months: 1), day("2026-02-28"))
        XCTAssertEqual(day("2024-01-31").adding(months: 1), day("2024-02-29"))
        XCTAssertEqual(day("2026-03-01").adding(days: -1), day("2026-02-28"))
        XCTAssertNil(LocalDate(year: 2026, month: 2, day: 29))
        XCTAssertEqual(day("2026-09-01").days(until: day("2026-09-30")), 29)
    }

    func testPreviousPeriodMatchesLength() {
        let september = DateSpan(start: day("2026-09-01"), end: day("2026-09-30"))
        XCTAssertEqual(september.previous, DateSpan(start: day("2026-08-01"), end: day("2026-08-31")))
        let tenDays = DateSpan(start: day("2026-09-10"), end: day("2026-09-19"))
        XCTAssertEqual(tenDays.previous, DateSpan(start: day("2026-08-31"), end: day("2026-09-09")))
        let quarter = DateSpan(start: day("2026-07-01"), end: day("2026-09-30"))
        XCTAssertEqual(quarter.previous, DateSpan(start: day("2026-04-01"), end: day("2026-06-30")))
        XCTAssertEqual(DateSpan(start: day("2026-08-15"), end: day("2026-10-02")).monthKeys, ["2026-08", "2026-09", "2026-10"])
    }

    func testPeriodLabels() {
        XCTAssertEqual(DateSpan(start: day("2026-09-01"), end: day("2026-09-30")).label, "September 2026")
        XCTAssertEqual(DateSpan(start: day("2026-01-01"), end: day("2026-12-31")).label, "2026")
        XCTAssertEqual(DateSpan(start: day("2026-07-01"), end: day("2026-09-30")).label, "Jul 2026 – Sep 2026")
        XCTAssertEqual(DateSpan(start: day("2026-09-03"), end: day("2026-09-09")).label, "Sep 3, 2026 – Sep 9, 2026")
    }

    func testDateLayouts() {
        XCTAssertEqual(DateLayout.monthDayYear.parse("1/5/26"), day("2026-01-05"))
        XCTAssertEqual(DateLayout.yearMonthDay.parse("2026-09-01T10:00:00"), day("2026-09-01"))
        XCTAssertEqual(DateLayout.dayMonthYear.parse("31/01/2026"), day("2026-01-31"))
        XCTAssertNil(DateLayout.monthDayYear.parse("13/01/2026"))
        XCTAssertEqual(DateLayout.detect(samples: ["13/01/2026", "25/12/2026"]), .dayMonthYear)
        XCTAssertEqual(DateLayout.detect(samples: ["01/02/2026"]), .monthDayYear)
        XCTAssertEqual(DateLayout.detect(samples: ["2026-01-02"]), .yearMonthDay)
        XCTAssertNil(DateLayout.detect(samples: ["x"]))
        // One bad row doesn't hide the format.
        XCTAssertEqual(DateLayout.detect(samples: ["09/01/2026", "13/45/2026"]), .monthDayYear)
    }
}
