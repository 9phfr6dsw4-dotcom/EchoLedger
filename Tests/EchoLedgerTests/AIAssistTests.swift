import XCTest
@testable import EchoLedgerCore

/// The parts of the Apple Intelligence features that don't need the model: remembering its
/// filings, undoing and correcting them, your filing style, merchant names and new bank layouts.
/// The model's answers are stood in for by fixed values.
final class AIAssistTests: XCTestCase {
    private func ids(_ ledger: Ledger, raw: String) -> [UUID] {
        ledger.transactions.values.filter { $0.rawDescription == raw }.map(\.id)
    }

    private func request(_ ledger: Ledger, raw: String, merchant: String, category: String, reason: String) -> Ledger.AIFilingRequest {
        Ledger.AIFilingRequest(ids: ids(ledger, raw: raw), key: MerchantText(raw).key, merchantName: merchant, kind: .expense,
                               categoryID: ledger.category(named: category)?.id, reason: reason)
    }

    private func filedHousehold() -> TestHousehold {
        var household = TestHousehold.make()
        let ledger = household.ledger
        let requests = [
            request(ledger, raw: "PINEWOOD APARTMENTS RENT WEB ID: 1234567890", merchant: "Pinewood Apartments", category: "Housing",
                    reason: "Rent payment to an apartment complex."),
            request(ledger, raw: "TRATTORIA ROMA, NEW YORK", merchant: "Trattoria Roma", category: "Dining", reason: "An Italian restaurant."),
            request(ledger, raw: "MYSTERY GADGETS LLC", merchant: "Mystery Gadgets", category: "Shopping", reason: "An electronics shop.")
        ]
        XCTAssertEqual(requests.map(\.key), ["PINEWOOD APARTMENTS RENT", "TRATTORIA ROMA NEW YORK", "MYSTERY GADGETS LLC"])
        _ = household.ledger.fileByAI(requests)
        return household
    }

    private func importOctober(_ household: inout TestHousehold) -> UUID {
        let file = Fixtures.chaseCardOctober
        let analysis = ImportAnalyzer.analyze(fileName: file.name, data: file.data, profiles: household.ledger.allProfiles)
        let card = household.account(startingWith: "Chase credit")
        let plan = ImportPlanner.plan(analysis, accountID: card.id, ledger: household.ledger)
        _ = household.ledger.commitImport([ImportCommitItem(analysis: analysis, plan: plan)])
        guard let october = household.ledger.transactions.values.first(where: { $0.date == day("2026-10-12") }) else {
            preconditionFailure("October charge missing")
        }
        return october.id
    }

    func testFilingEverythingItCanIsCountedAndFlagged() {
        let household = filedHousehold()
        let report = household.report()
        XCTAssertEqual(report.spending, 256_303)
        XCTAssertEqual(report.unknownCount, 4)
        XCTAssertEqual(report.unknownOut, -9_150)
        XCTAssertEqual(report.aiFiledIDs.count, 3)
        XCTAssertEqual(household.ledger.changes.count, 1)
        XCTAssertEqual(household.ledger.changes.last?.label, "Filed by Apple Intelligence (3)")
        XCTAssertEqual(Array(report.categories.prefix(4).map(\.name)), ["Housing", "Shopping", "Dining", "Cash & ATM"])
        XCTAssertEqual(Array(report.categories.prefix(4).map(\.amount)), [185_000, 32_628, 12_338, 10_000])
        let note = report.notes.first { $0.id == "ai-filed" }
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.text.hasPrefix("3 transactions were filed by Apple Intelligence") ?? false)

        let rent = household.ledger.transactions[ids(household.ledger, raw: "PINEWOOD APARTMENTS RENT WEB ID: 1234567890")[0]]
        XCTAssertEqual(rent?.method, .ai)
        XCTAssertEqual(rent?.review, .automatic)
        XCTAssertEqual(household.ledger.merchant(rent?.merchantID)?.name, "Pinewood Apartments")
        XCTAssertEqual(ReviewQueue.aiFiledGroups(household.ledger).count, 3)
    }

    func testFilingIsRememberedForTheNextImport() {
        var household = filedHousehold()
        let octoberID = importOctober(&household)
        let october = household.ledger.transactions[octoberID]
        XCTAssertEqual(october?.kind, .expense)
        XCTAssertEqual(october?.method, .ai)
        XCTAssertEqual(october?.review, .automatic)
        XCTAssertEqual(october?.categoryID, household.ledger.category(named: "Dining")?.id)
        XCTAssertEqual(household.ledger.merchant(october?.merchantID)?.name, "Trattoria Roma")
    }

    func testCorrectingAFilingStopsUsingItAndUndoBringsItBack() {
        var household = filedHousehold()
        let octoberID = importOctober(&household)
        let key = "TRATTORIA ROMA NEW YORK"
        let september = ids(household.ledger, raw: "TRATTORIA ROMA, NEW YORK").filter { household.ledger.transactions[$0]?.date.month == 9 }
        XCTAssertEqual(september.count, 1)
        let gifts = household.ledger.category(named: "Gifts & Donations")!
        _ = household.ledger.classify(september, merchantName: nil, kind: .expense, categoryID: gifts.id, remember: false, label: "Set category")

        XCTAssertEqual(household.ledger.aiFilings[key]?.rejected, true)
        XCTAssertTrue(household.ledger.rejectedAIKeys.contains(key))
        let october = household.ledger.transactions[octoberID]
        XCTAssertEqual(october?.kind, .unknown)
        XCTAssertEqual(october?.review, .suggested)
        XCTAssertNil(october?.merchantID)
        XCTAssertNil(october?.suggestion?.merchantName)
        XCTAssertEqual(october?.suggestion?.categoryID, household.ledger.category(named: "Dining")?.id)
        XCTAssertEqual(household.report().spending, 256_303)
        XCTAssertEqual(household.report().aiFiledIDs.count, 2)

        XCTAssertNotNil(household.ledger.undoLastChange())
        XCTAssertEqual(household.ledger.aiFilings[key]?.rejected, false)
        XCTAssertEqual(household.ledger.transactions[octoberID]?.method, .ai)
        XCTAssertEqual(household.ledger.transactions[octoberID]?.kind, .expense)
        XCTAssertEqual(household.report().aiFiledIDs.count, 3)

        // Bank text you corrected isn't filed again.
        _ = household.ledger.classify(september, merchantName: nil, kind: .expense, categoryID: gifts.id, remember: false, label: "Set category")
        let changes = household.ledger.changes.count
        let again = request(household.ledger, raw: "TRATTORIA ROMA, NEW YORK", merchant: "Trattoria Roma", category: "Dining", reason: "x")
        _ = household.ledger.fileByAI([again])
        XCTAssertEqual(household.ledger.changes.count, changes)
    }

    func testLooksRightKeepsAndLearnsTheFiling() {
        var household = filedHousehold()
        let filed = household.ledger.aiFiledUnchecked.map(\.id)
        XCTAssertEqual(filed.count, 3)
        _ = household.ledger.confirmAIFiled(filed)
        XCTAssertTrue(household.ledger.aiFiledUnchecked.isEmpty)
        XCTAssertEqual(household.ledger.changes.count, 4)
        let report = household.report()
        XCTAssertEqual(report.spending, 256_303)
        XCTAssertTrue(report.aiFiledIDs.isEmpty)
        XCTAssertEqual(household.ledger.merchant(named: "Trattoria Roma")?.keys, ["TRATTORIA ROMA NEW YORK"])
        let octoberID = importOctober(&household)
        let october = household.ledger.transactions[octoberID]
        XCTAssertEqual(october?.method, .learned)
        XCTAssertEqual(october?.review, .automatic)
        XCTAssertEqual(household.ledger.merchant(october?.merchantID)?.name, "Trattoria Roma")
    }

    func testUndoingTheFilingRemovesIt() {
        var household = filedHousehold()
        XCTAssertNotNil(household.ledger.undoLastChange())
        XCTAssertTrue(household.ledger.aiFilings.isEmpty)
        XCTAssertNil(household.ledger.merchant(named: "Trattoria Roma"))
        let report = household.report()
        XCTAssertEqual(report.spending, 56_683)
        XCTAssertEqual(report.unknownCount, 7)
        XCTAssertTrue(report.aiFiledIDs.isEmpty)
    }

    func testFilingsSurviveSavingAndReopening() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let household = filedHousehold()
        let store = try LedgerStore(url: folder.appendingPathComponent("EchoLedger.sqlite"))
        try store.saveAll(household.ledger)
        let loaded = try store.load()
        XCTAssertEqual(store.unreadableRecords, 0)
        XCTAssertEqual(loaded.aiFilings.count, 3)
        for (key, filing) in household.ledger.aiFilings {
            let saved = try XCTUnwrap(loaded.aiFilings[key])
            XCTAssertEqual(saved.merchantName, filing.merchantName, key)
            XCTAssertEqual(saved.categoryID, filing.categoryID, key)
            XCTAssertEqual(saved.kind, filing.kind, key)
            XCTAssertEqual(saved.reason, filing.reason, key)
            XCTAssertFalse(saved.rejected, key)
        }
        XCTAssertEqual(loaded.changes.last?.createdAIFilingKeys.count, 3)
        let report = ReportEngine.build(loaded, filter: ReportFilter(span: TestHousehold.september), today: TestHousehold.today)
        XCTAssertEqual(report.spending, 256_303)
        XCTAssertEqual(report.aiFiledIDs.count, 3)
    }

    func testStyleExamplesFollowWhatYouFiled() {
        var household = TestHousehold.make()
        let joes = household.ledger.transactions.values.filter { $0.rawDescription == "SQ *JOES COFFEE" }.sorted { $0.occurrence < $1.occurrence }
        let dining = household.ledger.category(named: "Dining")!
        _ = household.ledger.classify([joes[0].id], merchantName: "Joe's Coffee", kind: .expense, categoryID: dining.id,
                                      remember: true, label: "Set category")
        let card = household.account(startingWith: "Chase credit")
        func probe(_ raw: String, bankCategory: String?) -> LedgerTransaction {
            var transaction = LedgerTransaction(accountID: card.id, batchID: nil, sourceLine: 1, date: day("2026-09-20"), postedDate: nil,
                                                amount: -450, currency: "USD", rawDescription: raw, status: .posted, fingerprint: "", occurrence: 1)
            transaction.bankCategory = bankCategory
            return transaction
        }
        XCTAssertEqual(StyleExamples.examples(for: probe("SQ *JOES COFFE", bankCategory: "Food & Drink"), ledger: household.ledger),
                       ["“SQ *JOES COFFEE” → Joe's Coffee, Dining"])
        XCTAssertEqual(StyleExamples.examples(for: probe("ZZZ UNRELATED", bankCategory: nil), ledger: household.ledger), [])
    }

    func testWhichMerchantNamesNeedTidying() {
        let directory = Set(BuiltInKnowledge.merchants.map { $0.name.lowercased() })
        let cases: [(Merchant, Bool)] = [
            (Merchant(name: "BJSRESTAURANTS"), true),
            (Merchant(name: "Joes Coffee", keys: ["JOES COFFEE"]), true),
            (Merchant(name: "Joe's Coffee", keys: ["JOES COFFEE"]), false),
            (Merchant(name: "Starbucks"), false),
            (Merchant(name: "PY *TERIYAKI"), true),
            (Merchant(name: "Store 1234"), true),
            (Merchant(name: "JOES COFFEE", nameLocked: true), false),
            (Merchant(name: "Blue Bottle Coffee"), false)
        ]
        for (merchant, expected) in cases {
            XCTAssertEqual(MerchantNames.needsTidying(merchant, directoryNames: directory), expected, merchant.name)
        }
    }

    func testOnlyPlausibleRenamesAreAccepted() {
        let cases: [(String, String, String?)] = [
            ("BJSRESTAURANTS", "BJ's Restaurant", "BJ's Restaurant"),
            ("Joes Coffee", "Joe's Coffee", "Joe's Coffee"),
            ("PY *TERIYAKI MADNESS", "Teriyaki Madness", "Teriyaki Madness"),
            ("CITY BAKERY", "City Bakery & Cafe", "City Bakery & Cafe"),
            ("AMZN MKTP", "Amazon", nil),
            ("Joes Diner", "Starbucks", nil),
            ("Joes Coffee", "Joes Coffee", nil),
            ("Local Hardware", "http://x", nil),
            ("X", "A very long name that goes on and on beyond forty chars", nil)
        ]
        for (old, proposed, expected) in cases {
            XCTAssertEqual(MerchantNames.acceptRename(from: old, to: proposed), expected, "\(old) → \(proposed)")
        }
    }

    func testTidyingNamesSkipsLockedNamesAndUndoes() {
        var ledger = Ledger.starter()
        let shouting = Merchant(name: "JOES COFFEE", keys: ["JOES COFFEE"])
        let yours = Merchant(name: "TACO TRUCK", nameLocked: true)
        ledger.merchants[shouting.id] = shouting
        ledger.merchants[yours.id] = yours
        _ = ledger.tidyMerchantNames([(id: shouting.id, name: "Joe's Coffee"), (id: yours.id, name: "Taco Truck")])
        XCTAssertEqual(ledger.merchants[shouting.id]?.name, "Joe's Coffee")
        XCTAssertEqual(ledger.merchants[yours.id]?.name, "TACO TRUCK")
        XCTAssertEqual(ledger.changes.count, 1)
        XCTAssertNotNil(ledger.undoLastChange())
        XCTAssertEqual(ledger.merchants[shouting.id]?.name, "JOES COFFEE")
        // A rename you make yourself locks the name.
        _ = ledger.renameMerchant(shouting.id, to: "Joe's")
        XCTAssertEqual(ledger.merchants[shouting.id]?.nameLocked, true)
    }

    private func guess(headerRow: Int, date: Int, description: Int, amount: Int = 0, moneyOut: Int = 0, moneyIn: Int = 0,
                       purchasesArePositive: Bool = false, bank: String, type: AccountType?) -> LayoutGuess {
        LayoutGuess(headerRow: headerRow, dateColumn: date, descriptionColumn: description, amountColumn: amount,
                    moneyOutColumn: moneyOut, moneyInColumn: moneyIn, postedDateColumn: 0, statusColumn: 0,
                    purchasesArePositive: purchasesArePositive, bankName: bank, accountType: type)
    }

    func testCreditUnionLayoutFromAGuess() throws {
        let file = Fixtures.creditUnion
        let rows = LayoutProposal.sampleRows(file.data)
        XCTAssertEqual(String(LayoutProposal.promptText(rows).split(separator: "\n")[1]),
                       "Row 2: [1] Date | [2] Memo | [3] Withdrawal | [4] Deposit | [5] Balance")
        let good = guess(headerRow: 2, date: 1, description: 2, moneyOut: 3, moneyIn: 4, bank: "Credit Union", type: .checking)
        let profile = try XCTUnwrap(LayoutProposal.makeProfile(good, rows: rows, id: "custom-cu"))
        XCTAssertEqual(profile.requiredHeaders, ["Date", "Memo", "Withdrawal", "Deposit", "Balance"])
        XCTAssertEqual(profile.debitColumn, "Withdrawal")
        XCTAssertEqual(profile.creditColumn, "Deposit")
        XCTAssertEqual(profile.name, "Credit Union")

        let check = LayoutProposal.check(profile, fileName: file.name, data: file.data)
        XCTAssertTrue(check.accepted)
        XCTAssertFalse(check.flippedSigns)
        XCTAssertEqual(check.analysis.rows.map(\.amount), [-450, 120_000, -8_210])
        XCTAssertEqual(check.analysis.skippedLines, 1)
        XCTAssertEqual(check.analysis.issues.count, 0)

        // Saved, the layout recognizes the same file next time.
        let again = ImportAnalyzer.analyze(fileName: file.name, data: file.data, profiles: [check.profile] + ImportProfile.builtIns)
        XCTAssertEqual(again.profile?.id, "custom-cu")
        XCTAssertEqual(again.rows.count, 3)

        // Guesses that don't fit the file are refused rather than half-used.
        var bad = good
        bad.dateColumn = 2
        XCTAssertNil(LayoutProposal.makeProfile(bad, rows: rows, id: "x"))
        bad = good
        bad.moneyOutColumn = 9
        XCTAssertNil(LayoutProposal.makeProfile(bad, rows: rows, id: "x"))
        bad = good
        bad.moneyOutColumn = 0
        bad.moneyInColumn = 0
        XCTAssertNil(LayoutProposal.makeProfile(bad, rows: rows, id: "x"))
        bad = good
        bad.headerRow = 9
        XCTAssertNil(LayoutProposal.makeProfile(bad, rows: rows, id: "x"))
        bad = good
        bad.descriptionColumn = 3
        XCTAssertNil(LayoutProposal.makeProfile(bad, rows: rows, id: "x"))
    }

    func testBackwardsSignsAreReversed() throws {
        let file = Fixtures.storeCard
        let rows = LayoutProposal.sampleRows(file.data)
        let profile = try XCTUnwrap(LayoutProposal.makeProfile(guess(headerRow: 1, date: 1, description: 2, amount: 3, bank: "Store",
                                                                     type: .creditCard), rows: rows, id: "custom-store"))
        let check = LayoutProposal.check(profile, fileName: file.name, data: file.data)
        XCTAssertTrue(check.accepted)
        XCTAssertTrue(check.flippedSigns)
        XCTAssertEqual(check.profile.signConvention, .positiveIsMoneyOut)
        XCTAssertEqual(check.analysis.rows.map(\.amount), [-2_500, -3_000, -1_200, -800, -4_000, 11_500])
    }

    func testFileWithoutHeaders() throws {
        let file = Fixtures.noHeader
        let rows = LayoutProposal.sampleRows(file.data)
        let profile = try XCTUnwrap(LayoutProposal.makeProfile(guess(headerRow: 0, date: 1, description: 2, amount: 3, bank: "Local Bank",
                                                                     type: nil), rows: rows, id: "custom-nh"))
        XCTAssertFalse(profile.hasHeader)
        XCTAssertEqual(profile.headerlessColumns, ["Column 1", "Column 2", "Column 3"])
        XCTAssertEqual(profile.dateLayout, .monthDayYear)
        let check = LayoutProposal.check(profile, fileName: file.name, data: file.data)
        XCTAssertTrue(check.accepted)
        XCTAssertFalse(check.flippedSigns)
        XCTAssertEqual(check.analysis.rows.map(\.amount), [-2_500, -3_000, 500])

        let profiles = [check.profile] + ImportProfile.builtIns
        XCTAssertEqual(ImportAnalyzer.analyze(fileName: file.name, data: file.data, profiles: profiles).profile?.id, "custom-nh")
        // A saved headerless layout never takes over a built-in bank's files.
        XCTAssertEqual(ImportAnalyzer.analyze(fileName: Fixtures.comenity.name, data: Fixtures.comenity.data, profiles: profiles).profile?.id,
                       "comenity-card")
    }

    func testAccountTypeWords() {
        XCTAssertEqual(LayoutProposal.accountType(from: "Credit card"), .creditCard)
        XCTAssertEqual(LayoutProposal.accountType(from: "savings"), .savings)
        XCTAssertEqual(LayoutProposal.accountType(from: "Checking account"), .checking)
        XCTAssertNil(LayoutProposal.accountType(from: "unknown"))
    }
}
