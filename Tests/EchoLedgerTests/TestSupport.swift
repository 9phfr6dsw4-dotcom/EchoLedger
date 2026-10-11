import Foundation
@testable import EchoLedgerCore

/// A made-up household (Sam and Alex) with the September files imported, built the same way the
/// app does it: analyze → suggest an account → plan → commit.
struct TestHousehold {
    var ledger: Ledger
    let sam: Person
    let alex: Person

    static let today = LocalDate(year: 2026, month: 10, day: 11)!
    static let september = DateSpan(start: LocalDate(year: 2026, month: 9, day: 1)!, end: LocalDate(year: 2026, month: 9, day: 30)!)

    static func make() -> TestHousehold {
        var ledger = Ledger.starter()
        let sam = Person(name: "Sam")
        let alex = Person(name: "Alex", bankNames: ["Alex Rivera", "RIVERA ALEX"])
        _ = ledger.upsertPerson(sam)
        _ = ledger.upsertPerson(alex)
        for item in Fixtures.september {
            let analysis = ImportAnalyzer.analyze(fileName: item.file.name, data: item.file.data, profiles: ledger.allProfiles)
            let suggestion = ImportAnalyzer.suggestAccount(for: analysis, accounts: ledger.accounts)
            guard case .new(let name, let type, let last4, let profileID) = suggestion else {
                preconditionFailure("Expected a new account for \(item.file.name), got \(suggestion)")
            }
            let owner = item.owner == "Sam" ? sam.id : (item.owner == "Alex" ? alex.id : nil)
            let account = Account(name: name, personID: owner, type: type, last4: last4, profileID: profileID)
            _ = ledger.upsertAccount(account)
            let plan = ImportPlanner.plan(analysis, accountID: account.id, ledger: ledger)
            _ = ledger.commitImport([ImportCommitItem(analysis: analysis, plan: plan)])
        }
        return TestHousehold(ledger: ledger, sam: sam, alex: alex)
    }

    func account(startingWith prefix: String) -> Account {
        guard let account = ledger.accounts.first(where: { $0.name.hasPrefix(prefix) }) else {
            preconditionFailure("No account starting with \(prefix)")
        }
        return account
    }

    func report(people: Set<UUID> = [], span: DateSpan = TestHousehold.september) -> Report {
        ReportEngine.build(ledger, filter: ReportFilter(span: span, personIDs: people), today: TestHousehold.today)
    }
}

func day(_ text: String) -> LocalDate {
    guard let value = LocalDate(iso: text) else { preconditionFailure("Bad test date \(text)") }
    return value
}

func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("EchoLedgerTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
