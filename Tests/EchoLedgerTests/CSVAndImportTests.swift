import XCTest
@testable import EchoLedgerCore

final class CSVAndImportTests: XCTestCase {
    func testQuotedFieldsAndLineEndings() {
        let records = CSVReader.parse("a,\"b,c\",\"d \"\"q\"\"\"\r\n1,2,3", delimiter: ",")
        XCTAssertEqual(records.map(\.fields), [["a", "b,c", "d \"q\""], ["1", "2", "3"]])
        XCTAssertEqual(records.map(\.line), [1, 2])
    }

    func testLineBreakInsideQuotesKeepsLineNumbers() {
        let records = CSVReader.parse("x,\"line1\nline2\",y\nz,1,2\n", delimiter: ",")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].fields, ["x", "line1\nline2", "y"])
        XCTAssertEqual(records[1].line, 3)
    }

    func testBlankLinesAreCountedNotDropped() {
        let records = CSVReader.parse("a,b\n\nc,d\n", delimiter: ",")
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records[1].isBlank)
    }

    func testDetectsDelimiterAndEncoding() throws {
        XCTAssertEqual(CSVReader.detectDelimiter("a;b;c\n1;2;3"), ";")
        XCTAssertEqual(CSVReader.detectDelimiter("a\tb\n1\t2"), "\t")
        XCTAssertEqual(CSVReader.detectDelimiter("a,b\n1,2"), ",")
        XCTAssertEqual(try CSVReader.decode(Data([0xEF, 0xBB, 0xBF]) + Data("a,b".utf8)), "a,b")
        XCTAssertEqual(try CSVReader.decode(Data([0x43, 0x41, 0x46, 0xE9])), "CAF\u{00E9}")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("hi".data(using: .utf16LittleEndian) ?? Data())
        XCTAssertEqual(try CSVReader.decode(utf16), "hi")
        XCTAssertThrowsError(try CSVReader.decode(Data()))
    }

    private func analyze(_ file: Fixtures.File) -> FileAnalysis {
        ImportAnalyzer.analyze(fileName: file.name, data: file.data, profiles: ImportProfile.builtIns)
    }

    func testRecognizesEveryBuiltInLayoutInTheFixtures() {
        let expected: [(Fixtures.File, String, Int, AccountType)] = [
            (Fixtures.chaseChecking, "chase-checking", 6, .checking),
            (Fixtures.chaseCard, "chase-card", 10, .creditCard),
            (Fixtures.appleCard, "apple-card", 5, .creditCard),
            (Fixtures.citi, "citi-card", 5, .creditCard),
            (Fixtures.capitalOne, "capital-one-card", 3, .creditCard),
            (Fixtures.wellsFargoChecking, "wells-fargo", 6, .checking),
            (Fixtures.wellsFargoCard, "wells-fargo", 3, .creditCard),
            (Fixtures.comenity, "comenity-card", 3, .creditCard)
        ]
        for (file, profile, rows, type) in expected {
            let analysis = analyze(file)
            XCTAssertNil(analysis.problem, file.name)
            XCTAssertEqual(analysis.profile?.id, profile, file.name)
            XCTAssertEqual(analysis.rows.count, rows, file.name)
            XCTAssertEqual(analysis.issues.count, 0, file.name)
            XCTAssertEqual(analysis.typeHint, type, file.name)
        }
    }

    func testSignsFollowEachBanksConvention() {
        let apple = analyze(Fixtures.appleCard)
        XCTAssertEqual(apple.rows[0].amount, -2_318)
        XCTAssertEqual(apple.rows[0].bankMerchant, "Uber Eats")
        XCTAssertEqual(apple.rows[2].amount, 15_000)

        let citi = analyze(Fixtures.citi)
        XCTAssertEqual(citi.skippedLines, 2)
        XCTAssertEqual(citi.rows.map(\.amount), [-5_421, -4_800, 20_000, -1_549, 1_200])
        XCTAssertEqual(citi.rows.filter { $0.status == .pending }.count, 1)
        XCTAssertEqual(citi.rows[0].line, 4)

        let capitalOne = analyze(Fixtures.capitalOne)
        XCTAssertEqual(capitalOne.digitHints, ["9876"])
        XCTAssertEqual(capitalOne.rows.map(\.amount), [-6_410, 6_410, -231])
        XCTAssertEqual(capitalOne.rows[0].date, day("2026-09-04"))

        let comenity = analyze(Fixtures.comenity)
        XCTAssertEqual(comenity.delimiter, "\t")
        XCTAssertEqual(comenity.rows.map(\.amount), [-4_500, 4_500, -185])

        let wells = analyze(Fixtures.wellsFargoChecking)
        XCTAssertEqual(wells.rows.filter { $0.status == .pending }.count, 1)
        XCTAssertEqual(wells.rows[1].amount, 180_000)
    }

    func testEveryLineIsAccountedFor() {
        let analysis = analyze(Fixtures.invalid)
        XCTAssertEqual(analysis.profile?.id, "chase-card")
        XCTAssertEqual(analysis.rows.count, 1)
        XCTAssertEqual(analysis.issues.map(\.line), [3, 4, 5, 7])
        XCTAssertEqual(analysis.blankLines, 1)
        XCTAssertEqual(analysis.accountedLines, 7)
        for issue in analysis.issues {
            XCTAssertFalse(issue.reason.isEmpty)
        }
    }

    func testUnknownLayoutAsksForColumns() {
        let analysis = analyze(Fixtures.unknown)
        XCTAssertNil(analysis.profile)
        XCTAssertNotNil(analysis.problem)
        XCTAssertEqual(analysis.headers, ["Foo", "Bar", "Baz"])
    }

    func testCustomLayoutReadsTheFile() {
        let custom = ImportProfile(id: "custom-test", name: "My bank", accountType: .checking,
                                   requiredHeaders: ["Foo", "Bar", "Baz"], dateColumn: "Foo", descriptionColumn: "Bar",
                                   amountColumn: "Baz", isBuiltIn: false)
        let text = "Foo,Bar,Baz\n2026-09-01,LOCAL SHOP,-12.00\n"
        let analysis = ImportAnalyzer.analyze(fileName: "x.csv", data: Data(text.utf8), profile: custom)
        XCTAssertEqual(analysis.rows.count, 1)
        XCTAssertEqual(analysis.rows[0].amount, -1_200)
        XCTAssertEqual(analysis.rows[0].date, day("2026-09-01"))
    }

    func testFlipSignsReversesEveryAmount() {
        let analysis = ImportAnalyzer.analyze(fileName: Fixtures.chaseCard.name, data: Fixtures.chaseCard.data,
                                              profiles: ImportProfile.builtIns, flipSigns: true)
        XCTAssertEqual(analysis.rows[0].amount, 645)
    }

    func testAccountSuggestions() {
        let card = analyze(Fixtures.chaseCard)
        guard case .new(let name, let type, let last4, let profileID) = ImportAnalyzer.suggestAccount(for: card, accounts: []) else {
            return XCTFail("expected a new account")
        }
        XCTAssertEqual(name, "Chase credit card ••9001")
        XCTAssertEqual(type, .creditCard)
        XCTAssertEqual(last4, "9001")
        XCTAssertEqual(profileID, "chase-card")

        let first = Account(name: "Chase 9001", personID: nil, type: .creditCard, last4: "9001", profileID: "chase-card")
        let second = Account(name: "Chase 9002", personID: nil, type: .creditCard, last4: "9002", profileID: "chase-card")
        guard case .existing(let id, _) = ImportAnalyzer.suggestAccount(for: card, accounts: [first, second]) else {
            return XCTFail("expected the 9001 card")
        }
        XCTAssertEqual(id, first.id)

        let unnamed = ImportAnalyzer.analyze(fileName: "activity.csv", data: Fixtures.chaseCard.data, profiles: ImportProfile.builtIns)
        guard case .choose = ImportAnalyzer.suggestAccount(for: unnamed, accounts: [first, second]) else {
            return XCTFail("expected a choice between two cards")
        }

        let wells = analyze(Fixtures.wellsFargoChecking)
        guard case .new(let wellsName, let wellsType, _, _) = ImportAnalyzer.suggestAccount(for: wells, accounts: []) else {
            return XCTFail("expected a new account")
        }
        XCTAssertEqual(wellsName, "Wells Fargo checking")
        XCTAssertEqual(wellsType, .checking)
        // The card file with the same layout isn't sent to the checking account.
        let checking = Account(name: "WF checking", personID: nil, type: .checking, profileID: "wells-fargo")
        guard case .new(_, let cardType, _, _) = ImportAnalyzer.suggestAccount(for: analyze(Fixtures.wellsFargoCard), accounts: [checking]) else {
            return XCTFail("expected a new card account")
        }
        XCTAssertEqual(cardType, .creditCard)
    }

    func testDigitHintsInFileNames() {
        XCTAssertEqual(ImportAnalyzer.digitHints(inFileName: "Chase9001_Activity20260901_20260930.CSV"), ["9001"])
        XCTAssertEqual(ImportAnalyzer.digitHints(inFileName: "card 9002 and 9003.csv"), ["9002", "9003"])
        XCTAssertEqual(ImportAnalyzer.digitHints(inFileName: "export.csv"), [])
    }
}
