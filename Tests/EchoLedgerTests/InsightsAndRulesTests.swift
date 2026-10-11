import XCTest
@testable import EchoLedgerCore

final class InsightsAndRulesTests: XCTestCase {
    private func ledgerWith(_ rows: [(String, String, Cents)]) -> (Ledger, Account) {
        var ledger = Ledger.starter()
        let card = Account(name: "Card", personID: nil, type: .creditCard)
        _ = ledger.upsertAccount(card)
        var occurrences: [String: Int] = [:]
        for (dateText, raw, amount) in rows {
            let fingerprint = ImportAnalyzer.fingerprint(date: day(dateText), amount: amount, description: raw)
            let occurrence = (occurrences[fingerprint] ?? 0) + 1
            occurrences[fingerprint] = occurrence
            let transaction = LedgerTransaction(accountID: card.id, batchID: nil, sourceLine: 1, date: day(dateText), postedDate: nil,
                                                amount: amount, currency: "USD", rawDescription: raw, status: .posted,
                                                fingerprint: fingerprint, occurrence: occurrence)
            ledger.transactions[transaction.id] = transaction
        }
        ledger.rematch()
        return (ledger, card)
    }

    func testFindsMonthlyAndWeeklyRecurringCharges() {
        let (ledger, _) = ledgerWith([
            ("2026-06-05", "NETFLIX.COM", -1_549), ("2026-07-05", "NETFLIX.COM", -1_549),
            ("2026-08-05", "NETFLIX.COM", -1_549), ("2026-09-05", "NETFLIX.COM", -1_699),
            ("2026-09-01", "STARBUCKS STORE 1", -500), ("2026-09-08", "STARBUCKS STORE 1", -525),
            ("2026-09-15", "STARBUCKS STORE 1", -500), ("2026-09-22", "STARBUCKS STORE 1", -510),
            ("2026-09-03", "TARGET 1234", -2_000), ("2026-09-19", "TARGET 1234", -9_000), ("2026-09-20", "TARGET 1234", -100)
        ])
        let filter = ReportFilter(span: DateSpan(start: day("2026-09-01"), end: day("2026-09-30")))
        let charges = Insights.recurring(ledger, filter: filter, asOf: day("2026-10-11"))
        XCTAssertEqual(charges.map(\.merchantName).sorted(), ["Netflix", "Starbucks"])
        let netflix = charges.first { $0.merchantName == "Netflix" }!
        XCTAssertEqual(netflix.cadence, .monthly)
        XCTAssertEqual(netflix.typicalAmount, 1_549)
        XCTAssertTrue(netflix.priceChanged)
        XCTAssertEqual(netflix.lastAmount, 1_699)
        XCTAssertEqual(netflix.previousAmount, 1_549)
        XCTAssertEqual(netflix.nextExpected, day("2026-10-05"))
        XCTAssertTrue(netflix.isActive)
        XCTAssertEqual(netflix.yearlyCost, 18_588)
        let coffee = charges.first { $0.merchantName == "Starbucks" }!
        XCTAssertEqual(coffee.cadence, .weekly)
        XCTAssertFalse(coffee.isActive) // last charge Sep 22, nothing for almost three weeks
    }

    func testFlagsUnusualCharges() {
        let (ledger, _) = ledgerWith([
            ("2026-06-10", "AMAZON MKTPL*A1", -2_000), ("2026-07-10", "AMAZON MKTPL*A2", -2_200),
            ("2026-08-10", "AMAZON MKTPL*A3", -1_800), ("2026-09-12", "AMAZON MKTPL*A4", -15_000),
            ("2026-09-14", "BEST BUY 00123", -45_000), ("2026-09-15", "CHIPOTLE 1234", -1_500)
        ])
        let filter = ReportFilter(span: DateSpan(start: day("2026-09-01"), end: day("2026-09-30")))
        let unusual = Insights.unusual(ledger, filter: filter)
        XCTAssertEqual(unusual.map(\.merchantName), ["Best Buy", "Amazon"])
        XCTAssertNil(unusual[0].usualAmount)
        XCTAssertEqual(unusual[1].usualAmount, 2_000)
    }

    func testSuggestsRulesFromRepeatedCorrections() {
        var (ledger, _) = ledgerWith([
            ("2026-08-03", "AUTOLOAN PAYMENT 0123", -35_000), ("2026-09-03", "AUTOLOAN PAYMENT 0456", -35_000),
            ("2026-09-04", "LOCAL DINER 77", -2_500)
        ])
        let transportation = ledger.category(named: "Transportation")!
        let loans = ledger.transactions.values.filter { $0.rawDescription.hasPrefix("AUTOLOAN") }.map(\.id)
        _ = ledger.classify(loans, merchantName: "City Auto Loans", kind: .expense, categoryID: transportation.id, remember: false, label: "Set")
        let suggestions = RuleSuggester.suggestions(ledger)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].pattern, "AUTOLOAN PAYMENT")
        XCTAssertEqual(suggestions[0].merchantName, "City Auto Loans")
        XCTAssertEqual(suggestions[0].categoryID, transportation.id)
        XCTAssertEqual(suggestions[0].matchCount, 2)
        XCTAssertTrue(suggestions[0].conflictIDs.isEmpty)
        let rule = suggestions[0].makeRule(categoryName: "Transportation")
        XCTAssertEqual(rule.match, .contains)
        XCTAssertEqual(rule.pattern, "AUTOLOAN PAYMENT")
        // Once the rule exists, nothing more is suggested.
        _ = ledger.addRule(rule)
        XCTAssertTrue(RuleSuggester.suggestions(ledger).isEmpty)
    }

    func testRulePreviewShowsChangesAndShadowing() {
        var (ledger, _) = ledgerWith([
            ("2026-09-03", "LOCAL DINER 77", -2_500), ("2026-09-04", "LOCAL DINER 78", -1_500),
            ("2026-09-05", "STARBUCKS STORE 9", -500)
        ])
        let dining = ledger.category(named: "Dining")!
        let gifts = ledger.category(named: "Gifts & Donations")!
        let rule = Rule(name: "Diner", match: .contains, pattern: "LOCAL DINER", categoryID: dining.id)
        let preview = RulePreview.compute(rule, ledger: ledger)
        XCTAssertEqual(preview.matchingIDs.count, 2)
        XCTAssertEqual(preview.changingIDs.count, 2)
        XCTAssertTrue(preview.shadowedBy.isEmpty)
        _ = ledger.addRule(Rule(name: "Everything local", match: .contains, pattern: "LOCAL", categoryID: gifts.id))
        let shadowed = RulePreview.compute(rule, ledger: ledger, position: 1)
        XCTAssertEqual(shadowed.shadowedBy.first?.name, "Everything local")
        XCTAssertEqual(shadowed.shadowedBy.first?.count, 2)
        XCTAssertTrue(shadowed.changingIDs.isEmpty)
    }

    func testRuleOrderDecidesTheWinner() {
        var (ledger, _) = ledgerWith([("2026-09-03", "LOCAL DINER 77", -2_500)])
        let dining = ledger.category(named: "Dining")!
        let gifts = ledger.category(named: "Gifts & Donations")!
        let first = Rule(name: "Diner", match: .contains, pattern: "LOCAL DINER", categoryID: dining.id)
        let second = Rule(name: "Local", match: .contains, pattern: "LOCAL", categoryID: gifts.id)
        _ = ledger.addRule(first)
        _ = ledger.addRule(second, atTop: false)
        let id = ledger.transactions.keys.first!
        XCTAssertEqual(ledger.transactions[id]?.categoryID, dining.id)
        _ = ledger.setRuleOrder([second.id, first.id])
        XCTAssertEqual(ledger.transactions[id]?.categoryID, gifts.id)
        _ = ledger.deleteRule(second.id)
        XCTAssertEqual(ledger.transactions[id]?.categoryID, dining.id)
    }

    func testMergingMerchantsMovesTransactionsAndKeys() {
        var (ledger, _) = ledgerWith([("2026-09-03", "LOCAL DINER 77", -2_500), ("2026-09-04", "THE DINER", -1_000)])
        let dining = ledger.category(named: "Dining")!
        let ids = ledger.transactions.values.sorted { $0.date < $1.date }.map(\.id)
        _ = ledger.classify([ids[0]], merchantName: "Local Diner", kind: .expense, categoryID: dining.id, remember: true, label: "Set")
        _ = ledger.classify([ids[1]], merchantName: "Diner (other)", kind: .expense, categoryID: dining.id, remember: true, label: "Set")
        let source = ledger.merchant(named: "Diner (other)")!
        let target = ledger.merchant(named: "Local Diner")!
        _ = ledger.mergeMerchants(source.id, into: target.id)
        XCTAssertNil(ledger.merchant(named: "Diner (other)"))
        XCTAssertEqual(ledger.transactions[ids[1]]?.merchantID, target.id)
        XCTAssertTrue(ledger.merchants[target.id]?.keys.contains("THE DINER") == true)
        _ = ledger.renameMerchant(target.id, to: "Local Diner & Bar")
        XCTAssertEqual(ledger.merchants[target.id]?.name, "Local Diner & Bar")
    }
}
