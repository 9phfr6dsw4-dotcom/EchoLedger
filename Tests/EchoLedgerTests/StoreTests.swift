import XCTest
@testable import EchoLedgerCore

final class StoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let household = TestHousehold.make()
        let store = try LedgerStore(url: folder.appendingPathComponent("EchoLedger.sqlite"))
        XCTAssertTrue(try store.isEmpty())
        try store.saveAll(household.ledger)
        XCTAssertFalse(try store.isEmpty())

        let loaded = try store.load()
        XCTAssertEqual(store.unreadableRecords, 0)
        XCTAssertEqual(loaded.transactions.count, household.ledger.transactions.count)
        XCTAssertEqual(loaded.accounts.count, household.ledger.accounts.count)
        XCTAssertEqual(loaded.people.count, 2)
        XCTAssertEqual(loaded.merchants.count, household.ledger.merchants.count)
        XCTAssertEqual(loaded.batches.count, 8)
        for (id, transaction) in household.ledger.transactions {
            XCTAssertEqual(loaded.transactions[id], transaction)
        }
        let report = ReportEngine.build(loaded, filter: ReportFilter(span: TestHousehold.september), today: TestHousehold.today)
        XCTAssertEqual(report.spending, 56_683)
        XCTAssertEqual(report.income, 420_125)
    }

    func testDeltaSavesOnlyWhatChangedAndSurvivesReopen() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("EchoLedger.sqlite")
        var household = TestHousehold.make()
        do {
            let store = try LedgerStore(url: url)
            try store.saveAll(household.ledger)
            let joes = household.ledger.transactions.values.filter { $0.rawDescription == "SQ *JOES COFFEE" }.map(\.id)
            let dining = household.ledger.category(named: "Dining")!
            let delta = household.ledger.classify(joes, merchantName: "Joe's Coffee", kind: .expense, categoryID: dining.id,
                                                  remember: true, label: "Set category")
            try store.save(delta, from: household.ledger)
            store.close()
        }
        let reopened = try LedgerStore(url: url)
        let loaded = try reopened.load()
        XCTAssertNotNil(loaded.merchant(named: "Joe's Coffee"))
        XCTAssertEqual(loaded.changes.count, 1)
        let report = ReportEngine.build(loaded, filter: ReportFilter(span: TestHousehold.september), today: TestHousehold.today)
        XCTAssertEqual(report.spending, 57_583)

        // Undo after reopening still works and saves.
        var ledger = loaded
        let undo = try XCTUnwrap(ledger.undoLastChange())
        try reopened.save(undo, from: ledger)
        let again = try reopened.load()
        XCTAssertEqual(ReportEngine.build(again, filter: ReportFilter(span: TestHousehold.september), today: TestHousehold.today).spending, 56_683)
        XCTAssertNil(again.merchant(named: "Joe's Coffee"))
    }

    func testSourceLinesAreKeptAndRemovedWithTheirImport() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LedgerStore(url: folder.appendingPathComponent("EchoLedger.sqlite"))
        var ledger = Ledger.starter()
        let account = Account(name: "Card", personID: nil, type: .creditCard, profileID: "chase-card")
        var delta = ledger.upsertAccount(account)
        let analysis = ImportAnalyzer.analyze(fileName: Fixtures.chaseCard.name, data: Fixtures.chaseCard.data, profiles: ledger.allProfiles)
        let plan = ImportPlanner.plan(analysis, accountID: account.id, ledger: ledger)
        let result = ledger.commitImport([ImportCommitItem(analysis: analysis, plan: plan)])
        delta.merge(result.delta)
        try store.saveAll(ledger)
        try store.save(delta, from: ledger)
        let batch = result.batches[0]
        XCTAssertEqual(store.sourceLine(batchID: batch.id, line: 2), "09/01/2026,09/02/2026,STARBUCKS STORE 05794,Food & Drink,Sale,-6.45,")
        let undo = ledger.undoImport(batch.id)
        try store.save(undo, from: ledger)
        XCTAssertNil(store.sourceLine(batchID: batch.id, line: 2))
        XCTAssertEqual(try store.load().transactions.count, 0)
    }

    func testBackupVerifyAndRestore() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("EchoLedger.sqlite")
        let household = TestHousehold.make()
        let manager = BackupManager(folder: folder.appendingPathComponent("Backups"), keep: 3)
        do {
            let store = try LedgerStore(url: url)
            try store.saveAll(household.ledger)
            let first = try manager.makeBackup(of: store, reason: "test")
            XCTAssertTrue(LedgerStore.verify(first))
            // Change the live data after the backup.
            var ledger = household.ledger
            let id = ledger.transactions.keys.sorted { $0.uuidString < $1.uuidString }[0]
            let delta = ledger.setVoided(true, ids: [id], label: "Remove")
            try store.save(delta, from: ledger)
            for index in 0..<4 { try manager.makeBackup(of: store, reason: "extra\(index)") }
            store.close()
        }
        XCTAssertEqual(manager.list().count, 3)
        XCTAssertFalse(manager.needsDailyBackup())
        let notADatabase = folder.appendingPathComponent("junk.sqlite")
        try Data("not sqlite".utf8).write(to: notADatabase)
        XCTAssertFalse(LedgerStore.verify(notADatabase))
        XCTAssertThrowsError(try BackupManager.restore(notADatabase, over: url))

        let newest = try XCTUnwrap(manager.list().first)
        try BackupManager.restore(newest.url, over: url)
        let restored = try LedgerStore(url: url).load()
        XCTAssertEqual(restored.transactions.count, household.ledger.transactions.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("replaced.sqlite").path))
    }

    func testAllRecordKindsAreStored() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LedgerStore(url: folder.appendingPathComponent("EchoLedger.sqlite"))
        var ledger = TestHousehold.make().ledger
        let dining = ledger.category(named: "Dining")!
        var delta = ledger.setBudget(categoryID: dining.id, monthlyAmount: 30_000)
        delta.merge(ledger.addRule(Rule(name: "Coffee", match: .contains, pattern: "COFFEE", categoryID: dining.id)))
        delta.merge(ledger.upsertProfile(ImportProfile(id: "custom-1", name: "Mine", accountType: .checking, requiredHeaders: ["A", "B", "C"],
                                                       dateColumn: "A", descriptionColumn: "B", amountColumn: "C", isBuiltIn: true)))
        delta.merge(ledger.updateSettings { $0.timeZoneID = "America/New_York" })
        try store.saveAll(ledger)
        let loaded = try store.load()
        XCTAssertEqual(loaded.budgets.first?.monthlyAmount, 30_000)
        XCTAssertEqual(loaded.rules.first?.name, "Coffee")
        XCTAssertEqual(loaded.orderedRules.first?.name, "Coffee")
        XCTAssertEqual(loaded.profiles.first?.id, "custom-1")
        XCTAssertEqual(loaded.profiles.first?.isBuiltIn, false)
        XCTAssertEqual(loaded.settings.timeZoneID, "America/New_York")
        XCTAssertEqual(loaded.categories.count, LedgerCategory.defaults().count)
    }

    func testNewStoreStartsWithDefaultCategories() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LedgerStore(url: folder.appendingPathComponent("EchoLedger.sqlite"))
        let ledger = try store.load()
        XCTAssertEqual(ledger.categories.count, LedgerCategory.defaults().count)
        XCTAssertEqual(ledger.settings.timeZoneID, "America/Los_Angeles")
    }
}
