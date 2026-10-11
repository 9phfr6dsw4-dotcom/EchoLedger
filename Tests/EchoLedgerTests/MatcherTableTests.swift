import XCTest
@testable import EchoLedgerCore

/// Expected results checked independently (by hand and with a separate implementation).
/// Generated table: bank text, account, amount → kind, category, merchant, method.
final class MatcherTableTests: XCTestCase {
    struct Case {
        let raw: String
        let onCard: Bool
        let amount: Cents
        let bankMerchant: String?
        let bankCategory: String?
        let kind: TransactionKind
        let category: String?
        let merchant: String?
        let method: MatchMethod
        let review: ReviewState
        let suggestedCategory: String?
        let suggestedMerchant: String?
    }

    static let cases: [Case] = [
        Case(raw: "STARBUCKS STORE 05794", onCard: true, amount: -645, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Dining", merchant: "Starbucks", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "PAYPAL *COINBASEINC 4029357733 CA", onCard: true, amount: -10000, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Shopping", merchant: "Coinbase", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "AMAZON.COM*RETURN", onCard: true, amount: 1500, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Shopping", merchant: "Amazon", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "AUTOMATIC PAYMENT - THANK", onCard: true, amount: 31245, bankMerchant: nil, bankCategory: nil, kind: .transfer, category: nil, merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "AUTOMATIC PAYMENT - THANK", onCard: false, amount: 31245, bankMerchant: nil, bankCategory: nil, kind: .unknown, category: nil, merchant: nil, method: .none, review: .unresolved, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "CHASE CREDIT CRD AUTOPAY 9001 PPD ID: 4760039224", onCard: false, amount: -31245, bankMerchant: nil, bankCategory: nil, kind: .transfer, category: nil, merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "ACME CORP PAYROLL PPD ID: 9876543210", onCard: false, amount: 240000, bankMerchant: nil, bankCategory: nil, kind: .income, category: "Salary", merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "ACME CORP PAYROLL PPD ID: 9876543210", onCard: true, amount: 240000, bankMerchant: nil, bankCategory: nil, kind: .unknown, category: nil, merchant: nil, method: .none, review: .unresolved, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "Zelle payment to Alex Rivera JPM99AB12CD", onCard: false, amount: -6000, bankMerchant: nil, bankCategory: nil, kind: .transfer, category: nil, merchant: "Alex", method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "ZELLE TO JOHN DOE ON 09/05 REF # PP0ABC", onCard: false, amount: -2500, bankMerchant: nil, bankCategory: nil, kind: .unknown, category: nil, merchant: nil, method: .none, review: .unresolved, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "INTEREST CHARGE ON PURCHASES", onCard: true, amount: -312, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Fees & Interest", merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "UBER *EATS PENDING 8005928996 CA", onCard: true, amount: -2318, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Dining", merchant: "Uber Eats", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "UBER *TRIP HELP.UBER.COM CA", onCard: true, amount: -1550, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Transportation", merchant: "Uber", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "UBER *ONE MEMBERSHIP HELP.UBER.COM CA", onCard: true, amount: -999, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Subscriptions", merchant: "Uber One", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "COSTCO GAS #0123 DENVER CO", onCard: true, amount: -5000, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Transportation", merchant: "Costco Gas", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "COSTCO WHSE #0123 DENVER CO", onCard: true, amount: -15000, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Groceries", merchant: "Costco", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "SHELLFISH SHACK", onCard: true, amount: -3000, bankMerchant: nil, bankCategory: nil, kind: .unknown, category: nil, merchant: nil, method: .none, review: .unresolved, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "ATM WITHDRAWAL 001234 09/12 MAIN ST", onCard: false, amount: -10000, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Cash & ATM", merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "IRS TREAS 310 TAX REF", onCard: false, amount: 120000, bankMerchant: nil, bankCategory: nil, kind: .income, category: "Refunds & Settlements", merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "ONLINE TRANSFER TO WAY2SAVE SAVINGS XXXXXX9999", onCard: false, amount: -10000, bankMerchant: nil, bankCategory: nil, kind: .transfer, category: nil, merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "DAILY CASH ADJUSTMENT", onCard: true, amount: 125, bankMerchant: nil, bankCategory: nil, kind: .income, category: "Interest & Rewards", merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "MYSTERY GADGETS LLC", onCard: true, amount: -5820, bankMerchant: nil, bankCategory: "Shopping", kind: .unknown, category: nil, merchant: nil, method: .similar, review: .suggested, suggestedCategory: "Shopping", suggestedMerchant: nil),
        Case(raw: "TARGET 00012345 DENVER CO", onCard: true, amount: 1200, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Shopping", merchant: "Target", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "NETFLIX.COM", onCard: true, amount: -1549, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Subscriptions", merchant: "Netflix", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "GOOGLE *YOUTUBE TV g.co/helppay# CA", onCard: true, amount: -8299, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Subscriptions", merchant: "YouTube TV", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "TST* SUNSET TACOS SALEM OR", onCard: true, amount: -1800, bankMerchant: nil, bankCategory: nil, kind: .unknown, category: nil, merchant: nil, method: .none, review: .unresolved, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "BLUE BOTTLE COFFEE 300 WEBSTER ST OAKLAND 94607 CA USA", onCard: true, amount: -750, bankMerchant: "Blue Bottle Coffee", bankCategory: "Restaurants", kind: .unknown, category: nil, merchant: "Blue Bottle Coffee", method: .similar, review: .suggested, suggestedCategory: "Dining", suggestedMerchant: "Blue Bottle Coffee"),
        Case(raw: "PURCHASE AUTHORIZED ON 08/30 STARBUCKS STORE 12345 AUSTIN TX S386248709542601 CARD 1234", onCard: false, amount: -575, bankMerchant: nil, bankCategory: nil, kind: .expense, category: "Dining", merchant: "Starbucks", method: .directory, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "CAPITAL ONE ONLINE PYMT", onCard: true, amount: 6410, bankMerchant: nil, bankCategory: nil, kind: .transfer, category: nil, merchant: nil, method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "KOHLS PAYMENT 1234", onCard: false, amount: -6410, bankMerchant: nil, bankCategory: nil, kind: .transfer, category: nil, merchant: "Kohl's", method: .builtInRule, review: .automatic, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "STARBUCKX STORE", onCard: true, amount: -500, bankMerchant: nil, bankCategory: nil, kind: .unknown, category: nil, merchant: nil, method: .none, review: .unresolved, suggestedCategory: nil, suggestedMerchant: nil),
        Case(raw: "STARBUCKX", onCard: true, amount: -500, bankMerchant: nil, bankCategory: nil, kind: .unknown, category: nil, merchant: nil, method: .similar, review: .suggested, suggestedCategory: "Dining", suggestedMerchant: "Starbucks"),
    ]

    func testTable() {
        var ledger = Ledger.starter()
        _ = ledger.upsertPerson(Person(name: "Alex", bankNames: ["Alex Rivera", "RIVERA ALEX"]))
        let checking = Account(name: "Checking", personID: nil, type: .checking)
        let card = Account(name: "Card", personID: nil, type: .creditCard)
        _ = ledger.upsertAccount(checking)
        _ = ledger.upsertAccount(card)
        let matcher = Matcher(ledger: ledger)
        for item in MatcherTableTests.cases {
            let transaction = LedgerTransaction(accountID: item.onCard ? card.id : checking.id, batchID: nil, sourceLine: 1,
                                                date: day("2026-09-01"), postedDate: nil, amount: item.amount, currency: "USD",
                                                rawDescription: item.raw, bankMerchant: item.bankMerchant,
                                                bankCategory: item.bankCategory, status: .posted, fingerprint: "", occurrence: 1)
            let result = matcher.match(transaction)
            let merchant = result.newMerchantName ?? result.merchantID.flatMap { ledger.merchants[$0]?.name }
            XCTAssertEqual(result.kind, item.kind, item.raw)
            XCTAssertEqual(ledger.category(result.categoryID)?.name, item.category, item.raw)
            XCTAssertEqual(merchant, item.merchant, item.raw)
            XCTAssertEqual(result.method, item.method, item.raw)
            XCTAssertEqual(result.review, item.review, item.raw)
            XCTAssertEqual(ledger.category(result.suggestion?.categoryID)?.name, item.suggestedCategory, item.raw)
            XCTAssertEqual(result.suggestion?.merchantName, item.suggestedMerchant, item.raw)
            XCTAssertFalse(result.evidence.isEmpty, item.raw)
        }
    }
}
