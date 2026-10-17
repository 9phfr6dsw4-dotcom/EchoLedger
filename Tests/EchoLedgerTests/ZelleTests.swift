import XCTest
@testable import EchoLedgerCore

final class ZelleTests: XCTestCase {
    let span = DateSpan.month(containing: day("2026-09-15"))

    private struct Setup {
        var ledger: Ledger
        let sam: Person
        let alex: Person
        let alexChecking: Account
        let samChecking: Account
    }

    private func setup() -> Setup {
        var ledger = Ledger.starter()
        let sam = Person(name: "Sam", bankNames: ["Sam Rivera"])
        let alex = Person(name: "Alex", bankNames: ["Alex Rivera"])
        ledger.people = [sam, alex]
        let alexChecking = Account(name: "Example checking", personID: alex.id, type: .checking)
        let samChecking = Account(name: "Sample checking", personID: sam.id, type: .checking)
        ledger.accounts = [alexChecking, samChecking]
        return Setup(ledger: ledger, sam: sam, alex: alex, alexChecking: alexChecking, samChecking: samChecking)
    }

    private func payment(_ text: String, _ amount: Cents, on account: Account, kind: TransactionKind = .unknown,
                         categoryID: UUID? = nil) -> LedgerTransaction {
        var result = LedgerTransaction(accountID: account.id, batchID: nil, sourceLine: 1, date: day("2026-09-10"),
            postedDate: nil, amount: amount, currency: "USD", rawDescription: text, status: .posted,
            fingerprint: UUID().uuidString, occurrence: 1)
        result.kind = kind
        result.categoryID = categoryID
        result.review = kind == .unknown ? .unresolved : .confirmed
        return result
    }

    private func report(_ ledger: Ledger) -> Report {
        ReportEngine.build(ledger, filter: ReportFilter(span: span), today: span.end)
    }

    func testSummaryListsEachNameWithHowItIsCounted() throws {
        var s = setup()
        let groceries = try XCTUnwrap(s.ledger.category(named: "Groceries")).id
        let gifts = LedgerCategory(name: ZelleActivity.giftsReceivedCategory, group: .income, colorIndex: 0)
        _ = s.ledger.upsertCategory(gifts)
        let items = [
            payment("Zelle payment from Sam Rivera", 80_000, on: s.alexChecking, kind: .transfer),
            payment("Zelle payment from Pat Example", 6_000, on: s.samChecking, kind: .expense, categoryID: groceries),
            payment("Zelle payment to Pat Example", -4_500, on: s.samChecking, kind: .expense, categoryID: groceries),
            payment("Zelle payment from Casey Sample", 10_000, on: s.alexChecking, kind: .income, categoryID: gifts.id),
            payment("Example purchase", -2_000, on: s.alexChecking, kind: .expense, categoryID: groceries)
        ]
        for item in items { s.ledger.transactions[item.id] = item }

        let summary = ZelleActivity.build(s.ledger, filter: ReportFilter(span: span))
        XCTAssertEqual(summary.lines.count, 3)
        XCTAssertEqual(summary.received, 96_000)
        XCTAssertEqual(summary.sent, 4_500)
        XCTAssertEqual(summary.net, 91_500)
        XCTAssertEqual(summary.transactionIDs.count, 4)

        let pat = try XCTUnwrap(summary.lines.first { $0.name == "Pat Example" })
        XCTAssertEqual(pat.received, 6_000)
        XCTAssertEqual(pat.sent, 4_500)
        XCTAssertEqual(pat.net, 1_500)
        XCTAssertEqual(pat.howCounted, ["Paying back: Groceries", "Spending: Groceries"])
        let household = try XCTUnwrap(summary.lines.first { $0.name == "Sam Rivera" })
        XCTAssertEqual(household.howCounted, ["Household, not counted"])
        let casey = try XCTUnwrap(summary.lines.first { $0.name == "Casey Sample" })
        XCTAssertEqual(casey.howCounted, ["Gift received"])
        XCTAssertEqual(summary.household.received, 80_000)
    }

    func testHouseholdMoneyShowsOnEachPersonsReportWithoutChangingTotals() throws {
        var s = setup()
        let utilities = try XCTUnwrap(s.ledger.category(named: "Utilities")).id
        let items = [
            payment("Zelle payment from Sam Rivera", 80_000, on: s.alexChecking, kind: .transfer),
            payment("Zelle payment to Alex Rivera", -80_000, on: s.samChecking, kind: .transfer),
            payment("Example power company", -50_000, on: s.alexChecking, kind: .expense, categoryID: utilities)
        ]
        for item in items { s.ledger.transactions[item.id] = item }

        let sam = ZelleActivity.build(s.ledger, filter: ReportFilter(span: span, personIDs: [s.sam.id])).household
        XCTAssertEqual(sam.sent, 80_000)
        XCTAssertEqual(sam.received, 0)
        XCTAssertEqual(sam.sentIDs.count, 1)
        let alex = ZelleActivity.build(s.ledger, filter: ReportFilter(span: span, personIDs: [s.alex.id])).household
        XCTAssertEqual(alex.received, 80_000)
        XCTAssertEqual(alex.sent, 0)

        // The household money is not income or spending for anyone.
        let everyone = report(s.ledger)
        XCTAssertEqual(everyone.income, 0)
        XCTAssertEqual(everyone.spending, 50_000)
        let samReport = ReportEngine.build(s.ledger, filter: ReportFilter(span: span, personIDs: [s.sam.id]), today: span.end)
        XCTAssertEqual(samReport.income, 0)
        XCTAssertEqual(samReport.spending, 0)
    }

    func testPayingEachOtherNetsOutAndIsNeverIncome() {
        var s = setup()
        let out = payment("Zelle payment to Pat Example", -21_000, on: s.samChecking)
        let back = payment("Zelle payment from Pat Example", 15_000, on: s.samChecking)
        for item in [out, back] { s.ledger.transactions[item.id] = item }
        _ = s.ledger.classifyZelle([out.id], merchantName: "Pat Example", choice: .payingEachOther, categoryID: nil,
                                   remember: true, label: "Test")
        _ = s.ledger.classifyZelle([back.id], merchantName: "Pat Example", choice: .payingEachOther, categoryID: nil,
                                   remember: true, label: "Test")
        XCTAssertEqual(s.ledger.categories.filter { $0.name == ZelleActivity.payingEachOtherCategory }.count, 1)
        let result = report(s.ledger)
        XCTAssertEqual(result.income, 0)
        XCTAssertEqual(result.spending, 6_000)
        XCTAssertEqual(result.categories.first?.name, ZelleActivity.payingEachOtherCategory)
        XCTAssertEqual(result.categories.first?.amount, 6_000)

        // A month where more came back than went out nets below zero, and still isn't income.
        var t = setup()
        let sent = payment("Zelle payment to Pat Example", -21_000, on: t.samChecking)
        let received = payment("Zelle payment from Pat Example", 30_000, on: t.samChecking)
        for item in [sent, received] { t.ledger.transactions[item.id] = item }
        _ = t.ledger.classifyZelle([sent.id], merchantName: "Pat Example", choice: .payingEachOther, categoryID: nil,
                                   remember: false, label: "Test")
        _ = t.ledger.classifyZelle([received.id], merchantName: "Pat Example", choice: .payingEachOther, categoryID: nil,
                                   remember: false, label: "Test")
        let negative = report(t.ledger)
        XCTAssertEqual(negative.income, 0)
        XCTAssertEqual(negative.spending, -9_000)
        XCTAssertEqual(negative.categories.first?.amount, -9_000)
    }

    func testSalaryThenHouseholdTransferKeepsAccountDirectionAndOriginalIncome() throws {
        var s = setup()
        let salary = try XCTUnwrap(s.ledger.category(named: "Salary")).id
        let wages = payment("Example employer payroll", 200_000, on: s.samChecking,
                            kind: .income, categoryID: salary)
        let sent = payment("Zelle payment to Alex Rivera", -80_000, on: s.samChecking, kind: .transfer)
        let received = payment("Zelle payment from Sam Rivera", 80_000, on: s.alexChecking, kind: .transfer)
        for item in [wages, sent, received] { s.ledger.transactions[item.id] = item }

        let before = report(s.ledger)
        let summary = ZelleActivity.build(s.ledger, filter: ReportFilter(span: span))
        XCTAssertEqual(summary.sent, 80_000)
        XCTAssertEqual(summary.received, 80_000)
        XCTAssertEqual(summary.net, 0)

        // Rows name the counterpart, not the owner of the bank account.
        let fromSam = try XCTUnwrap(summary.lines.first { $0.name == "Sam Rivera" })
        XCTAssertEqual(fromSam.received, 80_000)
        XCTAssertEqual(fromSam.sent, 0)
        XCTAssertEqual(fromSam.net, 80_000)
        let toAlex = try XCTUnwrap(summary.lines.first { $0.name == "Alex Rivera" })
        XCTAssertEqual(toAlex.sent, 80_000)
        XCTAssertEqual(toAlex.received, 0)
        XCTAssertEqual(toAlex.net, -80_000)

        let senderFilter = ReportFilter(span: span, personIDs: [s.sam.id])
        let sender = ZelleActivity.build(s.ledger, filter: senderFilter)
        XCTAssertEqual(sender.sent, 80_000)
        XCTAssertEqual(sender.received, 0)
        XCTAssertEqual(sender.net, -80_000)
        let senderReport = ReportEngine.build(s.ledger, filter: senderFilter, today: span.end)
        XCTAssertEqual(senderReport.income, 200_000)
        XCTAssertEqual(senderReport.spending, 0)

        let recipientFilter = ReportFilter(span: span, personIDs: [s.alex.id])
        let recipient = ZelleActivity.build(s.ledger, filter: recipientFilter)
        XCTAssertEqual(recipient.received, 80_000)
        XCTAssertEqual(recipient.sent, 0)
        XCTAssertEqual(recipient.net, 80_000)
        let recipientReport = ReportEngine.build(s.ledger, filter: recipientFilter, today: span.end)
        XCTAssertEqual(recipientReport.income, 0)
        XCTAssertEqual(recipientReport.spending, 0)

        let after = report(s.ledger)
        XCTAssertEqual(after.income, before.income)
        XCTAssertEqual(after.spending, before.spending)
        XCTAssertEqual(after.savings, before.savings)
        XCTAssertEqual(after.income, 200_000)
        XCTAssertEqual(after.savings, 200_000)
        XCTAssertEqual(after.transferVolume, 80_000)
        XCTAssertEqual(after.transferCount, 2)
        XCTAssertEqual(s.ledger.transactions[sent.id]?.kind, .transfer)
        XCTAssertEqual(s.ledger.transactions[received.id]?.kind, .transfer)
    }

    func testPayingMeBackLowersTheCategoryYouPick() throws {
        var s = setup()
        let dining = try XCTUnwrap(s.ledger.category(named: "Dining")).id
        let meal = payment("Example restaurant", -8_000, on: s.samChecking, kind: .expense, categoryID: dining)
        let payback = payment("Zelle payment from Pat Example", 3_000, on: s.samChecking)
        for item in [meal, payback] { s.ledger.transactions[item.id] = item }
        _ = s.ledger.classifyZelle([payback.id], merchantName: "Pat Example", choice: .payingMeBack, categoryID: dining,
                                   remember: false, label: "Test")
        let result = report(s.ledger)
        XCTAssertEqual(result.income, 0)
        XCTAssertEqual(result.spending, 5_000)
        XCTAssertEqual(result.refunds, 3_000)
    }

    func testGiftReceivedIsItsOwnLineInsideNetCashFlow() throws {
        var s = setup()
        let salary = try XCTUnwrap(s.ledger.category(named: "Salary")).id
        let pay = payment("Example payroll", 50_000, on: s.alexChecking, kind: .income, categoryID: salary)
        let gift = payment("Zelle payment from Casey Sample", 10_000, on: s.alexChecking)
        for item in [pay, gift] { s.ledger.transactions[item.id] = item }
        _ = s.ledger.classifyZelle([gift.id], merchantName: "Casey Sample", choice: .giftReceived, categoryID: nil,
                                   remember: false, label: "Test")
        let result = report(s.ledger)
        XCTAssertEqual(result.income, 60_000)
        XCTAssertEqual(result.giftsReceived, 10_000)
        XCTAssertEqual(result.savings, 60_000)
        XCTAssertTrue(s.ledger.categories.contains { $0.name == ZelleActivity.giftsReceivedCategory && $0.group == .income })
    }

    func testChoicesAndZelleDetection() {
        XCTAssertFalse(ZelleChoice.choices(moneyIn: true).contains(.spending))
        XCTAssertTrue(ZelleChoice.choices(moneyIn: true).contains(.payingMeBack))
        XCTAssertFalse(ZelleChoice.choices(moneyIn: false).contains(.income))
        XCTAssertTrue(ZelleChoice.choices(moneyIn: false).contains(.payingEachOther))
        XCTAssertEqual(ZelleChoice.payingMeBack.kind, .expense)
        XCTAssertEqual(ZelleChoice.giftReceived.kind, .income)
        XCTAssertEqual(ZelleChoice.dontCount.kind, .transfer)
        XCTAssertTrue(ZelleChoice.spending.needsCategory)
        XCTAssertFalse(ZelleChoice.payingEachOther.needsCategory)
        XCTAssertTrue(ZelleActivity.isZelle("Zelle payment to Pat Example 12345678"))
        XCTAssertTrue(ZelleActivity.isZelle("ZELLE FROM PAT EXAMPLE"))
        XCTAssertFalse(ZelleActivity.isZelle("Example purchase"))
        XCTAssertFalse(ZelleActivity.isZelle("PAYPAL *EXAMPLE"))
    }
}
