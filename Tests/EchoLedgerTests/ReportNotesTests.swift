import XCTest
@testable import EchoLedgerCore

/// Notes about missing or partial files can be marked as fine, and stop showing until the
/// situation changes (or you bring them back).
final class ReportNotesTests: XCTestCase {
    private let september = DateSpan(start: day("2026-09-01"), end: day("2026-09-30"))
    private let today = day("2026-10-11")

    private func add(_ ledger: inout Ledger, _ account: Account, _ dates: [String]) {
        for (index, date) in dates.enumerated() {
            let transaction = LedgerTransaction(accountID: account.id, batchID: nil, sourceLine: index + 1, date: day(date), postedDate: nil,
                                                amount: -1_000, currency: "USD", rawDescription: "SHOP \(index)", status: .posted,
                                                fingerprint: "\(account.name)-\(index)", occurrence: 1)
            ledger.transactions[transaction.id] = transaction
        }
    }

    /// A rarely used card (Sep 2 and Sep 20), a busy card that stops on Sep 15, and a card whose
    /// history starts on Sep 10.
    private func makeLedger() -> (Ledger, quiet: Account, busy: Account, late: Account) {
        var ledger = Ledger.starter()
        let quiet = Account(name: "Quiet card", personID: nil, type: .creditCard)
        let busy = Account(name: "Busy card", personID: nil, type: .creditCard)
        let late = Account(name: "New card", personID: nil, type: .creditCard)
        for account in [quiet, busy, late] { _ = ledger.upsertAccount(account) }
        add(&ledger, quiet, ["2026-09-02", "2026-09-20"])
        add(&ledger, busy, (1...15).map { String(format: "2026-09-%02d", $0) })
        add(&ledger, late, ["2026-09-10", "2026-09-29"])
        return (ledger, quiet, busy, late)
    }

    private func notes(_ ledger: Ledger, span: DateSpan? = nil) -> [DataNote] {
        ReportEngine.build(ledger, filter: ReportFilter(span: span ?? september), today: today).notes
    }

    func testRarelyUsedCardsAreFlaggedGentlyAndBusyOnesAsWarnings() {
        let (ledger, quiet, busy, late) = makeLedger()
        let found = notes(ledger)
        let quietNote = found.first { $0.id == "late-\(quiet.id)" }
        XCTAssertEqual(quietNote?.severity, .info)
        XCTAssertEqual(quietNote?.text, "Quiet card has nothing after Sep 20, 2026. It's only used now and then, so that's probably right.")
        XCTAssertEqual(quietNote?.acknowledgement, .upToDate(accountID: quiet.id, through: day("2026-09-30")))
        let busyNote = found.first { $0.id == "late-\(busy.id)" }
        XCTAssertEqual(busyNote?.severity, .warning)
        XCTAssertEqual(busyNote?.text, "Busy card has nothing after Sep 15, 2026. Import a newer file if this report should run to Sep 30, 2026.")
        XCTAssertNil(found.first { $0.id == "late-\(late.id)" })
        XCTAssertEqual(found.first { $0.id == "early-\(late.id)" }?.acknowledgement, .historyStart(accountID: late.id, on: day("2026-09-10")))
        XCTAssertEqual(found.first { $0.id == "early-\(late.id)" }?.accountID, late.id)
    }

    func testMarkingNotesAsFineHidesThemUntilSomethingChanges() {
        let (initial, quiet, busy, late) = makeLedger()
        var ledger = initial
        _ = ledger.acknowledge(notes(ledger).compactMap(\.acknowledgement))
        XCTAssertTrue(notes(ledger).filter { $0.acknowledgement != nil }.isEmpty)
        XCTAssertEqual(ledger.account(quiet.id)?.upToDateThrough, day("2026-09-30"))
        XCTAssertEqual(ledger.account(busy.id)?.upToDateThrough, day("2026-09-30"))
        XCTAssertEqual(ledger.account(late.id)?.historyStartsOn, day("2026-09-10"))
        XCTAssertEqual(ledger.acknowledgedNoteCount, 3)

        // A report that runs further than what you confirmed asks again.
        let throughMidOctober = DateSpan(start: day("2026-09-01"), end: day("2026-10-10"))
        XCTAssertNotNil(notes(ledger, span: throughMidOctober).first { $0.id == "late-\(busy.id)" })

        // Older history imported later moves the start, so that note comes back with the new date.
        add(&ledger, late, ["2026-08-20"])
        let fromAugust = DateSpan(start: day("2026-08-01"), end: day("2026-09-30"))
        XCTAssertEqual(notes(ledger, span: fromAugust).first { $0.id == "early-\(late.id)" }?.acknowledgement,
                       .historyStart(accountID: late.id, on: day("2026-08-20")))

        _ = ledger.showAllReportNotes()
        XCTAssertEqual(ledger.acknowledgedNoteCount, 0)
        XCTAssertNotNil(notes(ledger).first { $0.id == "late-\(quiet.id)" })
    }

    func testRarelyUsedAccountsNeverGetFileNotes() {
        let (initial, _, busy, _) = makeLedger()
        var ledger = initial
        _ = ledger.acknowledge([.rarelyUsed(accountID: busy.id)])
        let throughMidOctober = DateSpan(start: day("2026-09-01"), end: day("2026-10-10"))
        XCTAssertFalse(notes(ledger, span: throughMidOctober).contains { $0.accountID == busy.id })
        let october = DateSpan(start: day("2026-10-01"), end: day("2026-10-31"))
        XCTAssertFalse(notes(ledger, span: october).contains { $0.id == "nodata-\(busy.id)" })
    }

    func testUnfinishedPeriodNoteCanBeDismissedForThatPeriod() {
        var household = TestHousehold.make()
        let october = DateSpan(start: day("2026-10-01"), end: day("2026-10-31"))
        let before = household.report(span: october).notes
        let partial = before.first { $0.id == "partial" }
        XCTAssertEqual(partial?.acknowledgement, .dismiss(key: "partial|2026-10-31"))
        XCTAssertEqual(before.filter { $0.id.hasPrefix("nodata-") }.count, 8)
        _ = household.ledger.acknowledge(before.compactMap(\.acknowledgement))
        let after = household.report(span: october).notes
        XCTAssertFalse(after.contains { $0.acknowledgement != nil })
        XCTAssertTrue(after.isEmpty)
        // Notes that need a decision in Review can't be dismissed.
        let septemberNotes = household.report().notes
        XCTAssertNil(septemberNotes.first { $0.id == "unknown" }?.acknowledgement)
        XCTAssertNotNil(septemberNotes.first { $0.id == "unknown" })
    }

    func testAccountsSavedByEarlierVersionsStillLoad() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Old card","type":"creditCard","currency":"USD","flipSigns":false,"isArchived":false}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(account.id, id)
        XCTAssertFalse(account.rarelyUsed)
        XCTAssertNil(account.upToDateThrough)
        XCTAssertNil(account.historyStartsOn)

        var marked = account
        marked.rarelyUsed = true
        marked.upToDateThrough = day("2026-09-30")
        let again = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(again, marked)

        let settings = try JSONDecoder().decode(LedgerSettings.self, from: Data(#"{"timeZoneID":"America/Denver"}"#.utf8))
        XCTAssertEqual(settings.dismissedNotes, [])
    }

    func testAcknowledgementsSurviveSavingAndReopening() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (initial, quiet, _, late) = makeLedger()
        var ledger = initial
        let store = try LedgerStore(url: folder.appendingPathComponent("EchoLedger.sqlite"))
        try store.saveAll(ledger)
        let delta = ledger.acknowledge([.rarelyUsed(accountID: quiet.id), .historyStart(accountID: late.id, on: day("2026-09-10")),
                                        .dismiss(key: "partial|2026-10-31")])
        try store.save(delta, from: ledger)
        let loaded = try store.load()
        XCTAssertEqual(loaded.account(quiet.id)?.rarelyUsed, true)
        XCTAssertEqual(loaded.account(late.id)?.historyStartsOn, day("2026-09-10"))
        XCTAssertEqual(loaded.settings.dismissedNotes, ["partial|2026-10-31"])
    }
}
