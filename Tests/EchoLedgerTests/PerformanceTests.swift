import XCTest
@testable import EchoLedgerCore

/// A year of busy synthetic card activity, to measure import and report speed. The time limits
/// are generous because CI runs unoptimized test builds; the printed times are what matter.
final class PerformanceTests: XCTestCase {
    func testYearOfTransactionsImportsAndReportsQuickly() throws {
        let merchants = ["STARBUCKS STORE 05794", "SAFEWAY #1234 AUSTIN TX", "AMAZON MKTPL*AB12C3", "SHELL OIL 57444 AUSTIN TX",
                         "CHIPOTLE 1234 DENVER CO", "TARGET 00012345 DENVER CO", "NETFLIX.COM", "SQ *JOES COFFEE",
                         "TRADER JOE'S #123 DENVER CO", "UBER *TRIP HELP.UBER.COM CA", "LOCAL HARDWARE 55", "CITY BAKERY 9",
                         "PANERA BREAD #1234", "COSTCO WHSE #0123", "WALGREENS #1234", "HOME DEPOT #0627"]
        var lines = ["Transaction Date,Post Date,Description,Category,Type,Amount,Memo"]
        var start = day("2025-10-01")
        var count = 0
        while count < 6_000 {
            let merchant = merchants[count % merchants.count]
            let amount = Cents(300 + (count * 7_919) % 15_000)
            let dateText = LocalDate.pad(start.month, 2) + "/" + LocalDate.pad(start.day, 2) + "/" + String(start.year)
            lines.append("\(dateText),\(dateText),\(merchant),Shopping,Sale,-\(Money.decimalString(amount)),")
            count += 1
            if count % 16 == 0 { start = start.adding(days: 1) }
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        var ledger = Ledger.starter()
        let card = Account(name: "Card", personID: nil, type: .creditCard, profileID: "chase-card")
        _ = ledger.upsertAccount(card)

        let clock = ContinuousClock()
        var analysis: FileAnalysis?
        let analyzeTime = clock.measure {
            analysis = ImportAnalyzer.analyze(fileName: "big.csv", data: data, profiles: ledger.allProfiles)
        }
        let parsed = try XCTUnwrap(analysis)
        XCTAssertEqual(parsed.rows.count, 6_000)
        var plan: ImportPlan?
        let planTime = clock.measure { plan = ImportPlanner.plan(parsed, accountID: card.id, ledger: ledger) }
        let commitTime = clock.measure {
            _ = ledger.commitImport([ImportCommitItem(analysis: parsed, plan: try! XCTUnwrap(plan))])
        }
        XCTAssertEqual(ledger.transactions.count, 6_000)
        let span = DateSpan(start: day("2025-10-01"), end: day("2026-09-30"))
        var report: Report?
        let reportTime = clock.measure {
            report = ReportEngine.build(ledger, filter: ReportFilter(span: span), today: day("2026-10-11"))
        }
        let recurringTime = clock.measure {
            _ = Insights.recurring(ledger, filter: ReportFilter(span: span), asOf: day("2026-10-11"))
        }
        let result = try XCTUnwrap(report)
        XCTAssertEqual(result.categories.reduce(Cents(0)) { $0 + $1.amount } + result.unknownOut * -1,
                       ledger.transactions.values.reduce(Cents(0)) { $0 - $1.amount })
        print("EchoLedger timing for 6,000 rows: analyze \(analyzeTime), plan \(planTime), import+match \(commitTime), report \(reportTime), recurring \(recurringTime)")
        XCTAssertLessThan(analyzeTime, .seconds(30))
        XCTAssertLessThan(commitTime, .seconds(60))
        XCTAssertLessThan(reportTime, .seconds(20))
    }
}
