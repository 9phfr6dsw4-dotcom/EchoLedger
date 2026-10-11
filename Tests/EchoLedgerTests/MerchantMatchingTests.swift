import XCTest
@testable import EchoLedgerCore

final class MerchantMatchingTests: XCTestCase {
    func testMerchantTextKeys() {
        let cases: [(String, String, String?)] = [
            ("PAYPAL *COINBASEINC 4029357733 CA", "COINBASEINC", "PayPal"),
            ("GOOGLE *YOUTUBE TV g.co/helppay# CA", "YOUTUBE TV", "Google"),
            ("UBER *ONE MEMBERSHIP HELP.UBER.COM CA", "UBER ONE MEMBERSHIP", nil),
            ("Zelle payment from TAYLOR MORGAN WFCT0ABCDEF", "TAYLOR MORGAN", "Zelle"),
            ("ZELLE TO RIVERA ALEX ON 09/05 REF # PP0ABCDEF", "RIVERA ALEX", "Zelle"),
            ("Amazon.com*RT4XY12Z3 Amzn.com/bill WA", "AMAZON", nil),
            ("APPLE.COM/BILL 866-712-7753 CA", "APPLE BILL", nil),
            ("DEL TACO 1320 AUSTIN TX", "DEL TACO", nil),
            ("NINETY NINE #0123 SALEM OR", "NINETY NINE", nil),
            ("TST* HILLTOP BURGERS SALEM OR", "HILLTOP BURGERS SALEM", nil),
            ("24 HOUR FITNESS USA 800-432-6348 CA", "24 HOUR FITNESS", nil),
            ("TRADER JOE'S #123 DENVER CO", "TRADER JOES", nil),
            ("APLPAY STARBUCKS 800-782-7282 WA", "STARBUCKS", nil),
            ("PURCHASE INTL AUTHORIZED ON 09/05 TOKYO CAFE", "TOKYO CAFE", nil),
            ("TARGET.COM * 800-591-3869 MN", "TARGET", nil),
            ("PURCHASE AUTHORIZED ON 08/30 STARBUCKS STORE 12345 AUSTIN TX S386248709542601 CARD 1234", "STARBUCKS STORE", nil),
            ("VENMO *JOHN SMITH", "JOHN SMITH", "Venmo")
        ]
        for (raw, key, via) in cases {
            let text = MerchantText(raw)
            XCTAssertEqual(text.key, key, raw)
            XCTAssertEqual(text.via, via, raw)
        }
        XCTAssertEqual(MerchantText("SQ *JOES COFFEE").displayName, "Joes Coffee")
        XCTAssertEqual(MerchantText("CVS/PHARMACY #1234").displayName, "CVS Pharmacy")
    }

    func testDirectoryLongestPhraseWinsAndRespectsWordBoundaries() {
        let directory = MerchantDirectory.shared
        XCTAssertEqual(directory.match("UBER *EATS PENDING")?.entry.name, "Uber Eats")
        XCTAssertEqual(directory.match("UBER *TRIP HELP.UBER.COM CA")?.entry.name, "Uber")
        XCTAssertEqual(directory.match("COSTCO GAS #0123")?.entry.name, "Costco Gas")
        XCTAssertEqual(directory.match("COSTCO WHSE #0123")?.entry.name, "Costco")
        XCTAssertEqual(directory.match("PAYPAL *COINBASEINC")?.entry.name, "Coinbase")
        XCTAssertNil(directory.match("SHELLFISH SHACK"))
        XCTAssertEqual(directory.match("T-MOBILE AUTOPAY")?.entry.name, "T-Mobile")
        XCTAssertNil(directory.match("EXXONMOBILE"))
        XCTAssertTrue(PhraseSearch.contains(Array("SQ *JOES".utf8), phrase: Array("JOES".utf8), allowSuffix: false))
        XCTAssertFalse(PhraseSearch.contains(Array("SQ *JOESPH".utf8), phrase: Array("JOES".utf8), allowSuffix: false))
        XCTAssertTrue(PhraseSearch.contains(Array("SQ *JOESPH".utf8), phrase: Array("JOES".utf8), allowSuffix: true))
    }

    func testSimilarityScores() {
        XCTAssertEqual(KeySimilarity.score("JOES COFFEE", "JOES COFFEE"), 100)
        XCTAssertEqual(KeySimilarity.score("JOES COFFE", "JOES COFFEE"), 91)
        XCTAssertEqual(KeySimilarity.score("STARBUCKX", "STARBUCKS"), 89)
        XCTAssertEqual(KeySimilarity.score("JOES", "JOES COFFEE"), 90)
        XCTAssertEqual(KeySimilarity.score("", "X"), 0)
    }

    private func makeLedger() -> (Ledger, checking: Account, card: Account) {
        var ledger = Ledger.starter()
        let checking = Account(name: "Checking", personID: nil, type: .checking)
        let card = Account(name: "Card", personID: nil, type: .creditCard)
        _ = ledger.upsertAccount(checking)
        _ = ledger.upsertAccount(card)
        return (ledger, checking, card)
    }

    private func transaction(_ raw: String, _ amount: Cents, account: Account) -> LedgerTransaction {
        LedgerTransaction(accountID: account.id, batchID: nil, sourceLine: 1, date: day("2026-09-01"), postedDate: nil,
                          amount: amount, currency: "USD", rawDescription: raw, status: .posted, fingerprint: "", occurrence: 1)
    }

    func testYourRulesComeFirstAndKeepTheMerchantSeparate() {
        var (ledger, checking, card) = makeLedger()
        let gifts = ledger.category(named: "Gifts & Donations")!
        let housing = ledger.category(named: "Housing")!
        _ = ledger.addRule(Rule(name: "Amazon gifts", match: .contains, pattern: "amazon", categoryID: gifts.id), applyNow: false)
        _ = ledger.addRule(Rule(name: "Rent", match: .contains, pattern: "PINEWOOD APARTMENTS", merchantName: "Pinewood Apartments",
                                categoryID: housing.id), applyNow: false)
        let matcher = Matcher(ledger: ledger)

        let amazon = matcher.match(transaction("AMAZON MKTPL*AB12C3DE4", -4_299, account: card))
        XCTAssertEqual(amazon.method, .userRule)
        XCTAssertEqual(amazon.categoryID, gifts.id)
        XCTAssertEqual(amazon.newMerchantName, "Amazon")

        let rent = matcher.match(transaction("PINEWOOD APARTMENTS RENT WEB ID: 1234567890", -185_000, account: checking))
        XCTAssertEqual(rent.method, .userRule)
        XCTAssertEqual(rent.kind, .expense)
        XCTAssertEqual(rent.categoryID, housing.id)
        XCTAssertEqual(rent.newMerchantName, "Pinewood Apartments")
    }

    func testRuleConditions() {
        var (ledger, checking, card) = makeLedger()
        let salary = ledger.category(named: "Salary")!
        _ = ledger.addRule(Rule(name: "Tips", match: .regex, pattern: "^ATM CASH DEP", accountIDs: [checking.id],
                                direction: .moneyIn, kind: .income, categoryID: salary.id), applyNow: false)
        _ = ledger.addRule(Rule(name: "Big", match: .startsWith, pattern: "WIRE", minimumAmount: 100_000,
                                kind: .transfer), applyNow: false)
        let matcher = Matcher(ledger: ledger)
        XCTAssertEqual(matcher.match(transaction("ATM CASH DEPOSIT 0912", 4_000, account: checking)).method, .userRule)
        XCTAssertNotEqual(matcher.match(transaction("ATM CASH DEPOSIT 0912", -4_000, account: checking)).method, .userRule)
        XCTAssertNotEqual(matcher.match(transaction("ATM CASH DEPOSIT 0912", 4_000, account: card)).method, .userRule)
        XCTAssertEqual(matcher.match(transaction("WIRE TO SAVINGS", -150_000, account: checking)).kind, .transfer)
        XCTAssertNotEqual(matcher.match(transaction("WIRE TO SAVINGS", -5_000, account: checking)).method, .userRule)
    }

    func testBrokenRegexIsIgnoredRatherThanCrashing() {
        var (ledger, _, card) = makeLedger()
        _ = ledger.addRule(Rule(name: "Broken", match: .regex, pattern: "([unclosed", kind: .transfer), applyNow: false)
        let result = Matcher(ledger: ledger).match(transaction("STARBUCKS STORE 1", -500, account: card))
        XCTAssertEqual(result.method, .directory)
    }

    func testLearnedMerchantsExactPrefixAndSimilar() {
        var (ledger, _, card) = makeLedger()
        let dining = ledger.category(named: "Dining")!
        let joes = Merchant(name: "Joe's Coffee", categoryID: dining.id, keys: ["JOES COFFEE"])
        ledger.merchants[joes.id] = joes
        let matcher = Matcher(ledger: ledger)
        let exact = matcher.match(transaction("SQ *JOES COFFEE", -450, account: card))
        XCTAssertEqual(exact.method, .learned)
        XCTAssertEqual(exact.merchantID, joes.id)
        XCTAssertEqual(exact.categoryID, dining.id)
        let prefix = matcher.match(transaction("SQ *JOES COFFEE AUSTIN TX", -450, account: card))
        XCTAssertEqual(prefix.method, .learned)
        let similar = matcher.match(transaction("JOES COFFE", -450, account: card))
        XCTAssertEqual(similar.review, .suggested)
        XCTAssertEqual(similar.suggestion?.merchantName, "Joe's Coffee")
        XCTAssertEqual(similar.kind, .unknown)
    }

    func testDisabledBuiltInRule() {
        var (ledger, checking, _) = makeLedger()
        _ = ledger.setBuiltInRule("atm-cash", enabled: false)
        let result = Matcher(ledger: ledger).match(transaction("ATM WITHDRAWAL 001234", -10_000, account: checking))
        XCTAssertEqual(result.kind, .unknown)
    }

    func testBuiltInKnowledgeIsConsistent() {
        let names = Set(LedgerCategory.defaults().map(\.name))
        for entry in BuiltInKnowledge.merchants {
            XCTAssertTrue(names.contains(entry.category), entry.name)
            XCTAssertFalse(entry.phrases.isEmpty, entry.name)
        }
        for rule in BuiltInKnowledge.rules {
            if let category = rule.categoryName { XCTAssertTrue(names.contains(category), rule.id) }
        }
        XCTAssertEqual(BuiltInRuleSet.compiled.count, BuiltInKnowledge.rules.count)
    }
}
