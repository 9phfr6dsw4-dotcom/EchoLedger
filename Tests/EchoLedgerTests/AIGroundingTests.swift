import XCTest
@testable import EchoLedgerCore

/// The checks that stand between Apple Intelligence and your data. These run without the model.
final class AIGroundingTests: XCTestCase {
    func testFindsMoneyAndPercentages() {
        XCTAssertEqual(Grounding.numbers(in: "Spending was $1,234.56, up 12.3% from $1,100"),
                       [.money(123_456, hadCents: true), .percent(123, hadDecimal: true), .money(110_000, hadCents: false)])
        XCTAssertEqual(Grounding.numbers(in: "\u{2212}$5.00 and 3 items and 2026 and 7.5%"),
                       [.money(500, hadCents: true), .percent(75, hadDecimal: true)])
    }

    func testNumbersMustComeFromSources() {
        XCTAssertTrue(Grounding.isGrounded("You spent $1,235 on dining", sources: ["Dining was $1,234.56"]))
        XCTAssertFalse(Grounding.isGrounded("You spent $1,300", sources: ["Dining was $1,234.56"]))
        XCTAssertTrue(Grounding.isGrounded("up 12%", sources: ["rose 12.3%"]))
        XCTAssertFalse(Grounding.isGrounded("up 15%", sources: ["rose 12.3%"]))
        XCTAssertTrue(Grounding.isGrounded("No numbers here", sources: []))
    }

    func testBulletsMustCiteRealFactsWithMatchingNumbers() {
        let facts = [ReportFact(id: "F1", text: "Spending was $566.83", transactionIDs: []),
                     ReportFact(id: "F2", text: "Shopping $268.08", transactionIDs: [])]
        let bullets: [(text: String, factIDs: [String])] = [
            ("Spending was $566.83.", ["F1"]),
            ("Shopping was $999.00.", ["F2"]),
            ("Dining doubled.", []),
            ("Spending came to $566.83.", ["f1 "]),
            ("Something else.", ["F9"])
        ]
        let kept = Grounding.checkBullets(bullets, facts: facts)
        XCTAssertEqual(kept.map(\.text), ["Spending was $566.83.", "Spending came to $566.83."])
        XCTAssertEqual(kept[1].facts.map(\.id), ["F1"])
    }

    func testFactsComeFromTheReportEngine() {
        let household = TestHousehold.make()
        let comparison = ReportComparison.build(household.ledger, filter: ReportFilter(span: TestHousehold.september),
                                                today: TestHousehold.today)
        let facts = ReportFacts.build(comparison: comparison, recurring: [], unusual: [])
        XCTAssertEqual(facts.first?.text, "Spending in September 2026 was $566.83, compared with $0.00 in August 2026.")
        XCTAssertEqual(facts.first?.id, "F1")
        XCTAssertTrue(facts.contains { $0.text == "Savings in September 2026 were $3,634.42, 86.5% of income." })
        XCTAssertTrue(facts.contains { $0.text.contains("7 transactions still need review") })
        XCTAssertEqual(Set(facts.map(\.id)).count, facts.count)
    }

    func testSuggestionsAreValidatedAgainstYourCategories() {
        let ledger = Ledger.starter()
        let good = SuggestionCheck.validate(merchant: "Blue Bottle Coffee", category: "dining", kind: "expense", ledger: ledger, amount: -750)
        XCTAssertEqual(good?.merchantName, "Blue Bottle Coffee")
        XCTAssertEqual(good?.categoryID, ledger.category(named: "Dining")?.id)
        XCTAssertEqual(good?.source, .ai)
        XCTAssertNil(SuggestionCheck.validate(merchant: "X Shop", category: "Dining", kind: "income", ledger: ledger, amount: 500))
        XCTAssertNil(SuggestionCheck.validate(merchant: "Blue", category: "Nonexistent", kind: "expense", ledger: ledger, amount: -750))
        XCTAssertNil(SuggestionCheck.validate(merchant: "http://evil.example", category: "Dining", kind: "expense", ledger: ledger, amount: -750))
        XCTAssertNil(SuggestionCheck.validate(merchant: "Payroll", category: "Salary", kind: "income", ledger: ledger, amount: -500))
        XCTAssertNil(SuggestionCheck.validate(merchant: "Shop", category: "Dining", kind: "delete everything", ledger: ledger, amount: -500))
        let transfer = SuggestionCheck.validate(merchant: "Mom", category: "", kind: "transfer", ledger: ledger, amount: -5_000)
        XCTAssertEqual(transfer?.kind, .transfer)
        XCTAssertNil(transfer?.categoryID)
        XCTAssertNil(SuggestionCheck.validate(merchant: "unknown", category: "Dining", kind: "expense", ledger: ledger, amount: -1)?.merchantName)
    }

    func testModelSeesRedactedTextOnly() {
        var ledger = Ledger.starter()
        let account = Account(name: "Card", personID: nil, type: .creditCard)
        _ = ledger.upsertAccount(account)
        let transaction = LedgerTransaction(accountID: account.id, batchID: nil, sourceLine: 1, date: day("2026-09-01"), postedDate: nil,
                                            amount: -10_000, currency: "USD", rawDescription: "PAYPAL *COINBASEINC 4029357733 CA",
                                            status: .posted, fingerprint: "", occurrence: 1)
        let text = SuggestionCheck.describe(transaction, ledger: ledger)
        XCTAssertFalse(text.contains("4029357733"))
        XCTAssertTrue(text.contains("##########"))
        XCTAssertTrue(text.contains("Paid through: PayPal"))
        XCTAssertTrue(text.contains("Direction: money out"))
    }

    func testFinanceQueriesUseTheReportEngine() {
        let household = TestHousehold.make()
        let ledger = household.ledger
        let today = TestHousehold.today
        let summary = FinanceQueries.summary(ledger, start: "2026-09", end: "2026-09", person: nil, today: today)
        XCTAssertTrue(summary.contains("Income: $4,201.25"), summary)
        XCTAssertTrue(summary.contains("Spending: $566.83 (after $27.00 in refunds)"), summary)
        XCTAssertTrue(summary.contains("Savings: $3,634.42 (86.5% of income)"), summary)
        XCTAssertTrue(summary.contains("Not included yet: 7 transactions need review"), summary)
        XCTAssertTrue(FinanceQueries.category(ledger, name: "Dining", start: "2026-09-01", end: "2026-09-30", person: nil, today: today)
            .contains("Dining: $35.38 spent in 3 transactions"))
        XCTAssertTrue(FinanceQueries.merchant(ledger, name: "amazon", start: "2026-09", end: "2026-09", person: nil, today: today)
            .contains("Spending at Amazon: $70.98 in 3 transactions."))
        XCTAssertTrue(FinanceQueries.summary(ledger, start: "2026-09", end: "2026-09", person: "Alex", today: today)
            .contains("Income: $1,800.00"))
        XCTAssertTrue(FinanceQueries.summary(ledger, start: "Sept", end: "2026-09", person: nil, today: today).hasPrefix("Error"))
        XCTAssertTrue(FinanceQueries.summary(ledger, start: "2026-10-01", end: "2026-09-01", person: nil, today: today).hasPrefix("Error"))
        XCTAssertTrue(FinanceQueries.summary(ledger, start: "2010-01", end: "2026-09", person: nil, today: today).hasPrefix("Error"))
        XCTAssertTrue(FinanceQueries.summary(ledger, start: "2026-09", end: "2026-09", person: "Nobody", today: today).hasPrefix("Error"))
        let list = FinanceQueries.transactions(ledger, start: "2026-09", end: "2026-09", text: nil, category: nil, minimumDollars: 100,
                                               person: nil, today: today)
        XCTAssertTrue(list.contains("Pinewood Apartments Rent") || list.contains("PINEWOOD"), list)
        XCTAssertTrue(list.contains("Coinbase"), list)
        let compare = FinanceQueries.compare(ledger, firstStart: "2026-08", firstEnd: "2026-08", secondStart: "2026-09",
                                             secondEnd: "2026-09", person: nil, today: today)
        XCTAssertTrue(compare.contains("Spending: $0.00 then $566.83 (change +$566.83)"), compare)
        XCTAssertEqual(FinanceQueries.recurring(ledger, person: nil, today: today), "No active recurring charges found.")
        XCTAssertTrue(FinanceQueries.context(ledger, today: today).contains("Today is 2026-10-11."))
    }
}
