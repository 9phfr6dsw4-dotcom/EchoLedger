import XCTest
@testable import EchoLedgerCore

/// End-to-end checks on a made-up household's September. Every expected figure was worked out by
/// hand from the fixture files and cross-checked with a separate implementation.
final class LedgerAndReportTests: XCTestCase {
    func testSeptemberTotalsForEveryone() {
        let household = TestHousehold.make()
        let report = household.report()
        XCTAssertEqual(report.income, 420_125)          // $2,400 + $1,800 paychecks + $1.25 Daily Cash
        XCTAssertEqual(report.spending, 56_683)         // after refunds
        XCTAssertEqual(report.refunds, 2_700)           // Amazon $15 + Target $12 returns
        XCTAssertEqual(report.savings, 363_442)
        XCTAssertEqual(report.savingsRateTenths, 865)
        XCTAssertEqual(report.transferCount, 10)
        XCTAssertEqual(report.transferVolume, 51_245)
        XCTAssertEqual(report.unknownCount, 7)
        XCTAssertEqual(report.unknownIn, 0)
        XCTAssertEqual(report.unknownOut, -208_770)
        XCTAssertEqual(report.pendingCount, 2)
        XCTAssertEqual(report.pendingTotal, -4_759)
        XCTAssertEqual(report.includedIDs.count, 22)
        XCTAssertFalse(report.isComplete)

        let expected: [(String, Cents, Int)] = [
            ("Shopping", 26_808, 7), ("Cash & ATM", 10_000, 1), ("Groceries", 5_421, 1), ("Transportation", 4_800, 1),
            ("Dining", 3_538, 3), ("Personal Care", 2_840, 1), ("Subscriptions", 2_548, 2), ("Fees & Interest", 728, 3)
        ]
        XCTAssertEqual(report.categories.map(\.name), expected.map { $0.0 })
        XCTAssertEqual(report.categories.map(\.amount), expected.map { $0.1 })
        XCTAssertEqual(report.categories.map(\.count), expected.map { $0.2 })
        let shopping = report.categories[0]
        XCTAssertEqual(shopping.merchants.map(\.name), ["Coinbase", "Amazon", "Kohl's", "Macy's", "Target"])
        XCTAssertEqual(shopping.merchants.map(\.amount), [10_000, 7_098, 6_410, 4_500, -1_200])
        XCTAssertEqual(report.incomeSources.map(\.amount), [240_000, 180_000, 125])
    }

    func testTotalsReconcile() {
        let report = TestHousehold.make().report()
        XCTAssertEqual(report.categories.reduce(Cents(0)) { $0 + $1.amount }, report.spending)
        for category in report.categories {
            XCTAssertEqual(category.merchants.reduce(Cents(0)) { $0 + $1.amount }, category.amount, category.name)
            XCTAssertEqual(category.merchants.reduce(0) { $0 + $1.count }, category.count, category.name)
        }
        XCTAssertEqual(report.incomeSources.reduce(Cents(0)) { $0 + $1.amount }, report.income)
        XCTAssertEqual(report.months.reduce(Cents(0)) { $0 + $1.spending }, report.spending)
        XCTAssertEqual(report.months.reduce(Cents(0)) { $0 + $1.income }, report.income)
    }

    func testPersonFilterIncludesSharedAccounts() {
        let household = TestHousehold.make()
        let alex = household.report(people: [household.alex.id])
        XCTAssertEqual(alex.income, 180_000)
        XCTAssertEqual(alex.spending, 25_623)
        XCTAssertEqual(alex.unknownCount, 0)
        XCTAssertEqual(alex.pendingCount, 2)
        XCTAssertEqual(alex.transferCount, 6)
        XCTAssertTrue(alex.notes.contains { $0.id == "shared" })
        let sam = household.report(people: [household.sam.id])
        XCTAssertEqual(sam.income, 240_125)
        XCTAssertEqual(sam.spending, 40_081)
        XCTAssertEqual(sam.transferCount, 5)
    }

    func testCardPaymentIsPairedAndNeverSpending() {
        let household = TestHousehold.make()
        let paired = household.ledger.transactions.values.filter { $0.transferPairID != nil }
        XCTAssertEqual(paired.count, 2)
        XCTAssertEqual(Set(paired.map(\.amount)), [-31_245, 31_245])
        XCTAssertTrue(paired.allSatisfy { $0.kind == .transfer })
        for transaction in paired {
            XCTAssertEqual(household.ledger.transactions[transaction.transferPairID!]?.transferPairID, transaction.id)
        }
    }

    func testIdenticalPurchasesOnOneDayStaySeparate() {
        let household = TestHousehold.make()
        let joes = household.ledger.transactions.values.filter { $0.rawDescription == "SQ *JOES COFFEE" }
        XCTAssertEqual(joes.count, 2)
        XCTAssertEqual(Set(joes.map(\.occurrence)), [1, 2])
    }

    func testReimportingTheSameFileAddsNothing() {
        let household = TestHousehold.make()
        let card = household.account(startingWith: "Chase credit")
        let analysis = ImportAnalyzer.analyze(fileName: Fixtures.chaseCard.name, data: Fixtures.chaseCard.data,
                                              profiles: household.ledger.allProfiles)
        guard case .existing(let id, _) = ImportAnalyzer.suggestAccount(for: analysis, accounts: household.ledger.accounts) else {
            return XCTFail("expected the existing card")
        }
        XCTAssertEqual(id, card.id)
        let plan = ImportPlanner.plan(analysis, accountID: card.id, ledger: household.ledger)
        XCTAssertEqual(plan.duplicateCount, 10)
        XCTAssertEqual(plan.newCount, 0)
        XCTAssertNotNil(plan.previousImport)
    }

    func testOverlappingExportFindsRepeatsAndHoldsLookalikes() {
        var household = TestHousehold.make()
        let card = household.account(startingWith: "Chase credit")
        let analysis = ImportAnalyzer.analyze(fileName: Fixtures.chaseCardOverlap.name, data: Fixtures.chaseCardOverlap.data,
                                              profiles: household.ledger.allProfiles)
        let plan = ImportPlanner.plan(analysis, accountID: card.id, ledger: household.ledger)
        XCTAssertEqual(plan.duplicateCount, 1)
        XCTAssertEqual(plan.possibleDuplicates.map(\.row.line), [3])
        XCTAssertEqual(plan.newCount, 2)
        let before = household.ledger.activeTransactions.count
        let result = household.ledger.commitImport([ImportCommitItem(analysis: analysis, plan: plan)])
        XCTAssertEqual(household.ledger.activeTransactions.count, before + 2)
        XCTAssertEqual(result.batches.first?.counts.heldDuplicates, 1)
        XCTAssertEqual(result.batches.first?.counts.imported, 2)
        XCTAssertEqual(result.batches.first?.counts.duplicates, 1)
    }

    func testChosenLookalikeIsImported() {
        var household = TestHousehold.make()
        let card = household.account(startingWith: "Chase credit")
        let analysis = ImportAnalyzer.analyze(fileName: Fixtures.chaseCardOverlap.name, data: Fixtures.chaseCardOverlap.data,
                                              profiles: household.ledger.allProfiles)
        let plan = ImportPlanner.plan(analysis, accountID: card.id, ledger: household.ledger)
        let before = household.ledger.activeTransactions.count
        _ = household.ledger.commitImport([ImportCommitItem(analysis: analysis, plan: plan, forcedLines: [3])])
        XCTAssertEqual(household.ledger.activeTransactions.count, before + 3)
    }

    func testPostedRowReplacesPendingAndUndoBringsItBack() {
        var household = TestHousehold.make()
        let citi = household.account(startingWith: "Citi")
        let analysis = ImportAnalyzer.analyze(fileName: Fixtures.citiOctober.name, data: Fixtures.citiOctober.data,
                                              profiles: household.ledger.allProfiles)
        let plan = ImportPlanner.plan(analysis, accountID: citi.id, ledger: household.ledger)
        XCTAssertEqual(plan.replacesPendingCount, 1)
        XCTAssertEqual(plan.newCount, 1)
        let result = household.ledger.commitImport([ImportCommitItem(analysis: analysis, plan: plan)])
        var report = household.report()
        XCTAssertEqual(report.spending, 58_232)
        XCTAssertEqual(report.pendingCount, 1)
        XCTAssertEqual(report.pendingTotal, -3_210)
        XCTAssertEqual(report.categories.first { $0.name == "Subscriptions" }?.amount, 4_097)

        _ = household.ledger.undoImport(result.batches[0].id)
        report = household.report()
        XCTAssertEqual(report.spending, 56_683)
        XCTAssertEqual(report.pendingCount, 2)
        XCTAssertEqual(household.ledger.activeTransactions.count, 41)
    }

    func testRememberTeachesSimilarTransactionsAndUndoReverses() {
        var household = TestHousehold.make()
        let joes = household.ledger.transactions.values.filter { $0.rawDescription == "SQ *JOES COFFEE" }
            .sorted { $0.occurrence < $1.occurrence }
        let dining = household.ledger.category(named: "Dining")!
        _ = household.ledger.classify([joes[0].id], merchantName: "Joe's Coffee", kind: .expense, categoryID: dining.id,
                                      remember: true, label: "Set category")
        XCTAssertEqual(household.ledger.transactions[joes[0].id]?.review, .confirmed)
        XCTAssertEqual(household.ledger.transactions[joes[1].id]?.method, .learned)
        XCTAssertEqual(household.ledger.transactions[joes[1].id]?.categoryID, dining.id)
        var report = household.report()
        XCTAssertEqual(report.spending, 57_583)
        XCTAssertEqual(report.unknownCount, 5)
        XCTAssertEqual(report.categories.first { $0.name == "Dining" }?.amount, 4_438)
        XCTAssertEqual(household.ledger.undoLabel, "Set category")

        XCTAssertNotNil(household.ledger.undoLastChange())
        XCTAssertEqual(household.ledger.transactions[joes[0].id]?.kind, .unknown)
        XCTAssertEqual(household.ledger.transactions[joes[1].id]?.kind, .unknown)
        XCTAssertNil(household.ledger.merchant(named: "Joe's Coffee"))
        report = household.report()
        XCTAssertEqual(report.spending, 56_683)
        XCTAssertEqual(report.unknownCount, 7)
    }

    func testRulesNeverOverrideYourConfirmedChoice() {
        var household = TestHousehold.make()
        let mystery = household.ledger.transactions.values.first { $0.rawDescription == "MYSTERY GADGETS LLC" }!
        let gifts = household.ledger.category(named: "Gifts & Donations")!
        let shopping = household.ledger.category(named: "Shopping")!
        _ = household.ledger.classify([mystery.id], merchantName: nil, kind: .expense, categoryID: gifts.id, remember: false, label: "Set")
        _ = household.ledger.addRule(Rule(name: "Gadgets", match: .contains, pattern: "GADGETS", categoryID: shopping.id))
        XCTAssertEqual(household.ledger.transactions[mystery.id]?.categoryID, gifts.id)
        let preview = RulePreview.compute(Rule(name: "Gadgets 2", match: .contains, pattern: "GADGETS", categoryID: shopping.id),
                                          ledger: household.ledger)
        XCTAssertEqual(preview.matchingIDs, [mystery.id])
        XCTAssertEqual(preview.confirmedIDs, [mystery.id])
        XCTAssertTrue(preview.changingIDs.isEmpty)
    }

    func testReclassifyingOneSideBreaksTheTransferPair() {
        var household = TestHousehold.make()
        let paired = household.ledger.transactions.values.filter { $0.transferPairID != nil }.sorted { $0.amount < $1.amount }
        let shopping = household.ledger.category(named: "Shopping")!
        _ = household.ledger.classify([paired[0].id], merchantName: nil, kind: .expense, categoryID: shopping.id, remember: false, label: "Set")
        XCTAssertNil(household.ledger.transactions[paired[0].id]?.transferPairID)
        XCTAssertNil(household.ledger.transactions[paired[1].id]?.transferPairID)
        // The other side was a built-in card-payment rule, so it stays a transfer.
        XCTAssertEqual(household.ledger.transactions[paired[1].id]?.kind, .transfer)
    }

    func testVoidingAStalePendingCharge() {
        var household = TestHousehold.make()
        let stale = ReviewQueue.stalePending(household.ledger, today: day("2026-10-20"))
        XCTAssertEqual(stale.count, 2)
        _ = household.ledger.setVoided(true, ids: [stale[0].id], label: "Remove")
        XCTAssertEqual(household.report().pendingCount, 1)
        _ = household.ledger.undoLastChange()
        XCTAssertEqual(household.report().pendingCount, 2)
    }

    func testReviewGroupsCombineIdenticalText() {
        let groups = ReviewQueue.groups(TestHousehold.make().ledger)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, 7)
        XCTAssertEqual(groups.first?.key, "JOES COFFEE")
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(groups.first?.total, -900)
    }

    func testDataNotesFlagMissingFilesAndOtherCurrencies() {
        var household = TestHousehold.make()
        let euro = Account(name: "Euro account", personID: nil, type: .checking, currency: "EUR")
        _ = household.ledger.upsertAccount(euro)
        let october = DateSpan(start: day("2026-10-01"), end: day("2026-10-31"))
        let report = household.report(span: october)
        XCTAssertTrue(report.notes.contains { $0.id == "currency" })
        XCTAssertTrue(report.notes.contains { $0.id == "partial" })
        XCTAssertTrue(report.notes.contains { $0.id.hasPrefix("nodata-") })
        XCTAssertEqual(report.spending, 0)
    }

    func testComparisonAndBudgets() {
        var household = TestHousehold.make()
        let comparison = ReportComparison.build(household.ledger, filter: ReportFilter(span: TestHousehold.september),
                                                today: TestHousehold.today)
        XCTAssertEqual(comparison.previous.spending, 0)
        XCTAssertEqual(comparison.spendingChange, 56_683)
        XCTAssertEqual(comparison.categoryChanges.first?.name, "Shopping")
        let dining = household.ledger.category(named: "Dining")!
        _ = household.ledger.setBudget(categoryID: dining.id, monthlyAmount: 3_000)
        let lines = BudgetReport.lines(household.ledger, report: household.report())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].budgeted, 3_000)
        XCTAssertEqual(lines[0].spent, 3_538)
        XCTAssertTrue(lines[0].isOver)
        XCTAssertEqual(lines[0].remaining, -538)
        let quarter = DateSpan(start: day("2026-07-01"), end: day("2026-09-30"))
        XCTAssertEqual(BudgetReport.lines(household.ledger, report: household.report(span: quarter))[0].budgeted, 9_000)
    }

    func testDeletingACategoryMovesItsTransactions() {
        var household = TestHousehold.make()
        let fees = household.ledger.category(named: "Fees & Interest")!
        let other = household.ledger.category(named: "Other Spending")!
        _ = household.ledger.deleteCategory(fees.id, replacement: other.id)
        XCTAssertNil(household.ledger.category(named: "Fees & Interest"))
        XCTAssertEqual(household.report().spending, 56_683)
    }

    func testCSVExportMatchesReport() {
        let household = TestHousehold.make()
        let report = household.report()
        let csv = CSVExport.transactions(report.includedIDs, ledger: household.ledger)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, report.includedIDs.count + 1)
        XCTAssertTrue(csv.hasPrefix("Date,Posted,Account,Owner,Description"))
        let summary = CSVExport.reportSummary(report)
        XCTAssertTrue(summary.contains("Spending (after refunds),566.83"))
        XCTAssertTrue(summary.contains("Income,4201.25"))
    }
}
