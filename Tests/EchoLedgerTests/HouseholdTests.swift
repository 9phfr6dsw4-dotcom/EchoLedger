import XCTest
@testable import EchoLedgerCore

final class HouseholdTests: XCTestCase {
    let span = DateSpan.month(containing: day("2026-09-15"))

    func testPeopleSharedAndUnassignedPartitionHouseholdExactly() {
        var ledger = Ledger.starter()
        let sam = Person(name: "Sam"), alex = Person(name: "Alex")
        ledger.people = [sam, alex]
        let personal = Account(name: "Sample card", personID: sam.id, type: .creditCard)
        let other = Account(name: "Example checking", personID: alex.id, type: .checking)
        let shared = Account(name: "Joint", personID: nil, type: .checking)
        let unassigned = Account(name: "New", personID: nil, type: .savings, isUnassigned: true)
        ledger.accounts = [personal, other, shared, unassigned]
        for (account, amount) in [(personal, Cents(-1_000)), (other, -2_000), (shared, -300), (unassigned, -400)] {
            let transaction = expense(account: account, amount: amount)
            ledger.transactions[transaction.id] = transaction
        }
        var corrected = expense(account: personal, amount: -500)
        corrected.spendingAssignment = .person(alex.id)
        ledger.transactions[corrected.id] = corrected
        var transfer = expense(account: personal, amount: -900)
        transfer.kind = .transfer
        ledger.transactions[transfer.id] = transfer
        let everyone = report(ledger)
        let samReport = report(ledger, people: [sam.id])
        let alexReport = report(ledger, people: [alex.id])
        let sharedReport = report(ledger, whole: false, shared: true)
        let unassignedReport = report(ledger, whole: false, unassigned: true)
        XCTAssertEqual(everyone.spending, 4_200)
        XCTAssertEqual(samReport.spending, 1_000)
        XCTAssertEqual(alexReport.spending, 2_500)
        XCTAssertEqual(sharedReport.spending, 300)
        XCTAssertEqual(unassignedReport.spending, 400)
        XCTAssertEqual(samReport.spending + alexReport.spending + sharedReport.spending + unassignedReport.spending, everyone.spending)
        XCTAssertEqual(report(ledger, people: [sam.id, alex.id]).spending, 3_500)
        XCTAssertEqual(report(ledger, people: [sam.id], shared: true).spending, 1_300)
        XCTAssertEqual(report(ledger, whole: false).spending, 0)
        XCTAssertEqual(everyone.transferVolume, 900)
        XCTAssertEqual(CSVExport.transactions([corrected.id], ledger: ledger).contains("Alex"), true)
        XCTAssertTrue(CSVExport.reportSummary(alexReport).contains("People,Alex"))
        XCTAssertTrue(FinanceQueries.summary(ledger, start: "2026-09", end: "2026-09", person: "Alex", today: span.end).contains("$25.00"))
        XCTAssertTrue(FinanceQueries.summary(ledger, start: "2026-09", end: "2026-09", person: "shared", today: span.end).contains("$3.00"))
        XCTAssertEqual(FinanceQueries.peopleFilter("Sam, Alex", ledger: ledger), [sam.id, alex.id])
    }

    func testDefaultChangesFreezeHistoryAndExplicitReapplyPreservesCorrections() {
        var ledger = Ledger.starter()
        let sam = Person(name: "Sam"), alex = Person(name: "Alex")
        ledger.people = [sam, alex]
        var account = Account(name: "Example card", personID: sam.id, type: .creditCard)
        ledger.accounts = [account]
        let original = expense(account: account)
        var manual = expense(account: account)
        manual.spendingAssignment = .shared
        ledger.transactions = [original.id: original, manual.id: manual]
        account.defaultAssignment = .person(alex.id)
        _ = ledger.upsertAccount(account)
        XCTAssertEqual(ledger.assignment(for: ledger.transactions[original.id]!), .person(sam.id))
        _ = ledger.applySpendingDefault(accountID: account.id)
        XCTAssertEqual(ledger.assignment(for: ledger.transactions[original.id]!), .person(alex.id))
        XCTAssertEqual(ledger.assignment(for: ledger.transactions[manual.id]!), .shared)
        _ = ledger.undoLastChange()
        XCTAssertEqual(ledger.assignment(for: ledger.transactions[original.id]!), .person(sam.id))
        _ = ledger.assignSpending(.person(alex.id), ids: [original.id, manual.id])
        XCTAssertEqual(report(ledger, people: [alex.id]).spending, 2_000)
        _ = ledger.undoLastChange()
        XCTAssertEqual(ledger.assignment(for: ledger.transactions[manual.id]!), .shared)
    }

    func testAdditionalCardPurchasesAreDistinctAndReorderedImportsStayDuplicates() {
        var ledger = Ledger.starter()
        let sam = Person(name: "Sam"), alex = Person(name: "Alex")
        ledger.people = [sam, alex]
        let account = Account(name: "Example credit", personID: sam.id, type: .creditCard,
                              cardAssignments: ["Cardholder: Alex": .person(alex.id)])
        ledger.accounts = [account]
        let samFile = analysis(["09/10/2026,AMAZON,Sam,5.00"])
        importFile(samFile, account: account, ledger: &ledger)
        let alexFile = analysis(["09/10/2026,AMAZON,Alex,5.00"])
        XCTAssertEqual(ImportPlanner.plan(alexFile, accountID: account.id, ledger: ledger).newCount, 1)
        importFile(alexFile, account: account, ledger: &ledger)
        let combined = analysis(["09/10/2026,AMAZON,Alex,5.00", "09/10/2026,AMAZON,Sam,5.00"])
        XCTAssertEqual(ImportPlanner.plan(combined, accountID: account.id, ledger: ledger).duplicateCount, 2)
        XCTAssertEqual(report(ledger, people: [alex.id]).spending, 500)
        XCTAssertEqual(report(ledger, people: [sam.id]).spending, 500)
        let twoForSam = analysis(["09/10/2026,AMAZON,Sam,5.00", "09/10/2026,AMAZON,Sam,5.00"])
        XCTAssertEqual(ImportPlanner.plan(twoForSam, accountID: account.id, ledger: ledger).newCount, 1)
    }

    func testLegacyCardAmbiguityIsHeldForReviewAndPendingLearnsCardDefault() {
        var ledger = Ledger.starter()
        let alex = Person(name: "Alex")
        ledger.people = [alex]
        let account = Account(name: "Example card", personID: nil, type: .creditCard,
                              cardAssignments: ["Cardholder: Alex": .person(alex.id)])
        ledger.accounts = [account]
        let incoming = analysis(["09/10/2026,AMAZON,Alex,5.00"])
        var old = expense(account: account, amount: -500)
        old.date = day("2026-09-10")
        old.rawDescription = "AMAZON"
        old.fingerprint = ImportAnalyzer.fingerprint(date: old.date, amount: old.amount, description: old.rawDescription)
        ledger.transactions[old.id] = old
        XCTAssertEqual(ImportPlanner.plan(incoming, accountID: account.id, ledger: ledger).possibleDuplicates.count, 1)
        old.status = .pending
        old.inheritedAssignment = .shared
        old.spendingAssignment = .unassigned
        ledger.transactions[old.id] = old
        XCTAssertEqual(ImportPlanner.plan(incoming, accountID: account.id, ledger: ledger).replacesPendingCount, 1)
        importFile(incoming, account: account, ledger: &ledger)
        let posted = ledger.activeTransactions.first { $0.status == .posted }!
        XCTAssertEqual(posted.inheritedAssignment, .person(alex.id))
        XCTAssertEqual(posted.spendingAssignment, .unassigned)
    }

    func testRemovingPersonMovesDefaultsAndHistoryToUnassigned() {
        var ledger = Ledger.starter()
        let person = Person(name: "Alex")
        ledger.people = [person]
        let account = Account(name: "Example card", personID: person.id, type: .creditCard,
                              cardAssignments: ["Cardholder: Alex": .person(person.id)])
        ledger.accounts = [account]
        let transaction = expense(account: account)
        ledger.transactions[transaction.id] = transaction
        _ = ledger.deletePerson(person.id)
        XCTAssertEqual(ledger.accounts[0].defaultAssignment, .unassigned)
        XCTAssertEqual(ledger.accounts[0].cardAssignments["Cardholder: Alex"], .unassigned)
        XCTAssertEqual(ledger.assignment(for: ledger.transactions[transaction.id]!), .unassigned)
    }

    func testOldSavedModelsDecodeAndAssignmentsRoundTripThroughSQLite() throws {
        var ledger = Ledger.starter()
        let person = Person(name: "Sam", monthlyAllowance: 30_000)
        let account = Account(name: "Example card", personID: person.id, type: .creditCard)
        var transaction = expense(account: account)
        transaction.spendingAssignment = .shared
        transaction.inheritedAssignment = .person(person.id)
        transaction.cardIdentifier = "Cardholder: Sam"
        ledger.people = [person]; ledger.accounts = [account]; ledger.transactions[transaction.id] = transaction
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LedgerStore(url: folder.appendingPathComponent("test.sqlite"))
        try store.saveAll(ledger)
        let loaded = try store.load()
        XCTAssertEqual(loaded.transactions[transaction.id], transaction)
        XCTAssertEqual(loaded.people[0].monthlyAllowance, 30_000)
        let oldAccount: Account = try legacy(account, removing: ["isUnassigned", "cardAssignments"])
        XCTAssertFalse(oldAccount.isUnassigned)
        XCTAssertEqual(oldAccount.cardAssignments, [:])
        let oldTransaction: LedgerTransaction = try legacy(transaction, removing: ["spendingAssignment", "inheritedAssignment", "cardIdentifier"])
        XCTAssertNil(oldTransaction.spendingAssignment)
        XCTAssertNil(oldTransaction.cardIdentifier)
        let oldPerson: Person = try legacy(person, removing: ["monthlyAllowance"])
        XCTAssertNil(oldPerson.monthlyAllowance)
    }

    func testSeveralPeopleCanShareACardAndReportsCanFollowTheirCards() {
        var ledger = Ledger.starter()
        let sam = Person(name: "Sam"), alex = Person(name: "Alex")
        ledger.people = [sam, alex]
        let joint = Account(name: "Example joint card", personID: nil, type: .creditCard, userIDs: [sam.id, alex.id])
        let personal = Account(name: "Sample card", personID: sam.id, type: .creditCard)
        let household = Account(name: "Plain household", personID: nil, type: .checking)
        let undecided = Account(name: "New", personID: nil, type: .savings, isUnassigned: true)
        ledger.accounts = [joint, personal, household, undecided]
        for (account, amount) in [(joint, Cents(-1_000)), (personal, -2_000), (household, -300), (undecided, -400)] {
            let transaction = expense(account: account, amount: amount)
            ledger.transactions[transaction.id] = transaction
        }
        var reassigned = expense(account: personal, amount: -500)
        reassigned.spendingAssignment = .person(alex.id)
        ledger.transactions[reassigned.id] = reassigned

        XCTAssertNil(joint.personID)
        XCTAssertEqual(joint.defaultAssignment, .shared)
        XCTAssertEqual(ledger.usersLabel(joint), "Sam, Alex")
        XCTAssertEqual(ledger.usersLabel(household), "Household")
        XCTAssertEqual(ledger.usersLabel(undecided), "Unassigned")
        XCTAssertEqual(ledger.cardUserNames(for: reassigned), ["Sam"])

        // Spending assigned to them: a card with two users is shared unless a purchase is reassigned.
        XCTAssertEqual(report(ledger).spending, 4_200)
        XCTAssertEqual(report(ledger, people: [sam.id]).spending, 2_000)
        XCTAssertEqual(report(ledger, people: [alex.id]).spending, 500)
        XCTAssertEqual(report(ledger, whole: false, shared: true).spending, 1_300)
        XCTAssertEqual(report(ledger, whole: false, unassigned: true).spending, 400)

        // Everything on the cards they use: the reassigned purchase stays with Sam's card, and the
        // joint card counts for both of them.
        XCTAssertEqual(report(ledger, people: [sam.id], mode: .cards).spending, 3_500)
        XCTAssertEqual(report(ledger, people: [alex.id], mode: .cards).spending, 1_000)
        XCTAssertEqual(report(ledger, people: [sam.id, alex.id], mode: .cards).spending, 3_500)
        XCTAssertEqual(report(ledger, people: [sam.id], shared: true, mode: .cards).spending, 3_800)
        XCTAssertEqual(report(ledger, whole: false, shared: true, mode: .cards).spending, 300)
        XCTAssertEqual(report(ledger, whole: false, unassigned: true, mode: .cards).spending, 400)
        XCTAssertEqual(report(ledger, whole: true, mode: .cards).spending, 4_200)
        XCTAssertEqual(report(ledger, people: [sam.id], mode: .cards).scopeLabel, "Sam (their cards)")
        XCTAssertEqual(report(ledger, people: [sam.id]).scopeLabel, "Sam")
        XCTAssertTrue(report(ledger, people: [sam.id], mode: .cards).notes.contains { $0.id == "shared" && $0.text.contains("counted once") })
    }

    func testChangingCardUsersKeepsPastAssignmentsAndRemovingAUserKeepsTheOthers() {
        var ledger = Ledger.starter()
        let sam = Person(name: "Sam"), alex = Person(name: "Alex")
        ledger.people = [sam, alex]
        var account = Account(name: "Example card", personID: sam.id, type: .creditCard)
        ledger.accounts = [account]
        let transaction = expense(account: account)
        ledger.transactions[transaction.id] = transaction
        account.userIDs.append(alex.id)
        XCTAssertNil(account.personID)
        _ = ledger.upsertAccount(account)
        // The past purchase stays Sam's in "assigned" reports; new ones follow the shared card.
        XCTAssertEqual(ledger.assignment(for: ledger.transactions[transaction.id]!), .person(sam.id))
        XCTAssertEqual(ledger.accounts[0].defaultAssignment, .shared)
        // But the card itself is now used by both, which "their cards" reports follow.
        XCTAssertEqual(Set(ledger.cardUsers(for: ledger.transactions[transaction.id]!)), [sam.id, alex.id])
        _ = ledger.deletePerson(sam.id)
        XCTAssertEqual(ledger.accounts[0].userIDs, [alex.id])
        XCTAssertEqual(ledger.accounts[0].personID, alex.id)
        XCTAssertEqual(ledger.cardUsers(for: ledger.transactions[transaction.id]!), [alex.id])
    }

    func testCardUsersSurviveSavingAndOlderAccountsBecomeOneUser() throws {
        let sam = Person(name: "Sam"), alex = Person(name: "Alex")
        let shared = Account(name: "Example card", personID: nil, type: .creditCard, userIDs: [sam.id, alex.id])
        let again: Account = try legacy(shared, removing: [])
        XCTAssertEqual(again.userIDs, [sam.id, alex.id])
        XCTAssertNil(again.personID)
        let single = Account(name: "Sample card", personID: sam.id, type: .creditCard)
        XCTAssertEqual(single.userIDs, [sam.id])
        let old: Account = try legacy(single, removing: ["userIDs"])
        XCTAssertEqual(old.userIDs, [sam.id])
        XCTAssertEqual(old.personID, sam.id)
        let oldHousehold: Account = try legacy(Account(name: "Joint", personID: nil, type: .checking), removing: ["userIDs", "personID"])
        XCTAssertEqual(oldHousehold.userIDs, [])
        XCTAssertEqual(oldHousehold.defaultAssignment, .shared)
    }

    private func report(_ ledger: Ledger, people: Set<UUID> = [], whole: Bool? = nil, shared: Bool = false, unassigned: Bool = false,
                        mode: PeopleMode = .assigned) -> Report {
        ReportEngine.build(ledger, filter: ReportFilter(span: span, personIDs: people, wholeHousehold: whole,
            includeShared: shared, includeUnassigned: unassigned, peopleMode: mode), today: span.end)
    }

    private func expense(account: Account, amount: Cents = -1_000) -> LedgerTransaction {
        var result = LedgerTransaction(accountID: account.id, batchID: nil, sourceLine: 1, date: day("2026-09-15"),
            postedDate: nil, amount: amount, currency: "USD", rawDescription: "Example purchase", status: .posted,
            fingerprint: UUID().uuidString, occurrence: 1)
        result.kind = .expense; result.review = .confirmed
        return result
    }

    private func analysis(_ rows: [String]) -> FileAnalysis {
        ImportAnalyzer.analyze(fileName: "example.csv", data: Data((["Date,Description,Card Member,Amount"] + rows).joined(separator: "\n").utf8), profiles: ImportProfile.builtIns)
    }

    private func importFile(_ analysis: FileAnalysis, account: Account, ledger: inout Ledger) {
        let plan = ImportPlanner.plan(analysis, accountID: account.id, ledger: ledger)
        _ = ledger.commitImport([ImportCommitItem(analysis: analysis, plan: plan)])
    }

    private func legacy<T: Codable>(_ value: T, removing keys: [String]) throws -> T {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for key in keys { json.removeValue(forKey: key) }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
