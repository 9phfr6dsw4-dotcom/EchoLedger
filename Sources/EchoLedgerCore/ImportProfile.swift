import Foundation

public enum SignConvention: String, Codable, Sendable, CaseIterable {
    /// Deposits and refunds are positive, purchases negative (Chase, Wells Fargo).
    case positiveIsMoneyIn
    /// Purchases are positive, payments negative (Apple Card, Comenity, Discover, Amex).
    case positiveIsMoneyOut

    public var label: String {
        switch self {
        case .positiveIsMoneyIn: return "Purchases are negative"
        case .positiveIsMoneyOut: return "Purchases are positive"
        }
    }
}

/// Extra shape checks for files that have no header row.
public enum HeaderlessShape: String, Codable, Sendable {
    case none
    /// Wells Fargo classic: "date","amount","*","check","description"
    case wellsFargoClassic
    /// Comenity (Macy's and other store cards): date, $amount, description, type — tab separated
    case comenity
}

/// A bank file layout: which columns hold what, and how amounts are signed.
public struct ImportProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The account type this layout always means, or nil when the file's content decides
    /// (Wells Fargo uses one layout for checking and cards).
    public var accountType: AccountType?
    public var hasHeader: Bool
    /// Header names (any letter case) that identify this layout.
    public var requiredHeaders: [String]
    public var forbiddenHeaders: [String]
    /// Column names used for files without a header row.
    public var headerlessColumns: [String]
    public var headerlessShape: HeaderlessShape
    public var dateColumn: String
    public var postedDateColumn: String?
    public var descriptionColumn: String
    public var merchantColumn: String?
    public var categoryColumn: String?
    public var amountColumn: String?
    public var debitColumn: String?
    public var creditColumn: String?
    public var signConvention: SignConvention
    public var statusColumn: String?
    public var pendingValues: [String]
    public var checkNumberColumn: String?
    public var cardNumberColumn: String?
    public var cardholderColumn: String?
    /// nil = detected from the file.
    public var dateLayout: DateLayout?
    public var isBuiltIn: Bool

    public init(id: String, name: String, accountType: AccountType?, hasHeader: Bool = true, requiredHeaders: [String],
                forbiddenHeaders: [String] = [], headerlessColumns: [String] = [], headerlessShape: HeaderlessShape = .none,
                dateColumn: String, postedDateColumn: String? = nil, descriptionColumn: String,
                merchantColumn: String? = nil, categoryColumn: String? = nil, amountColumn: String? = nil,
                debitColumn: String? = nil, creditColumn: String? = nil, signConvention: SignConvention = .positiveIsMoneyIn,
                statusColumn: String? = nil, pendingValues: [String] = [], checkNumberColumn: String? = nil,
                cardNumberColumn: String? = nil, cardholderColumn: String? = nil, dateLayout: DateLayout? = nil, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.accountType = accountType
        self.hasHeader = hasHeader
        self.requiredHeaders = requiredHeaders
        self.forbiddenHeaders = forbiddenHeaders
        self.headerlessColumns = headerlessColumns
        self.headerlessShape = headerlessShape
        self.dateColumn = dateColumn
        self.postedDateColumn = postedDateColumn
        self.descriptionColumn = descriptionColumn
        self.merchantColumn = merchantColumn
        self.categoryColumn = categoryColumn
        self.amountColumn = amountColumn
        self.debitColumn = debitColumn
        self.creditColumn = creditColumn
        self.signConvention = signConvention
        self.statusColumn = statusColumn
        self.pendingValues = pendingValues
        self.checkNumberColumn = checkNumberColumn
        self.cardNumberColumn = cardNumberColumn
        self.cardholderColumn = cardholderColumn
        self.dateLayout = dateLayout
        self.isBuiltIn = isBuiltIn
    }

    public var usesDebitCredit: Bool { debitColumn != nil && creditColumn != nil }

    /// Layouts EchoLedger recognizes out of the box. Each import shows a preview with totals, so
    /// a bank that changes its format is caught before anything is saved.
    public static let builtIns: [ImportProfile] = [
        ImportProfile(id: "chase-checking", name: "Chase checking or savings", accountType: .checking,
                      requiredHeaders: ["Details", "Posting Date", "Description", "Amount"],
                      forbiddenHeaders: ["Transaction Date"],
                      dateColumn: "Posting Date", descriptionColumn: "Description", amountColumn: "Amount",
                      signConvention: .positiveIsMoneyIn, checkNumberColumn: "Check or Slip #", isBuiltIn: true),
        ImportProfile(id: "chase-card", name: "Chase credit card", accountType: .creditCard,
                      requiredHeaders: ["Transaction Date", "Post Date", "Description", "Amount"],
                      forbiddenHeaders: ["Clearing Date", "Card No."],
                      dateColumn: "Transaction Date", postedDateColumn: "Post Date", descriptionColumn: "Description",
                      categoryColumn: "Category", amountColumn: "Amount", signConvention: .positiveIsMoneyIn, isBuiltIn: true),
        ImportProfile(id: "apple-card", name: "Apple Card", accountType: .creditCard,
                      requiredHeaders: ["Transaction Date", "Clearing Date", "Description", "Amount (USD)"],
                      dateColumn: "Transaction Date", postedDateColumn: "Clearing Date", descriptionColumn: "Description",
                      merchantColumn: "Merchant", categoryColumn: "Category", amountColumn: "Amount (USD)",
                      signConvention: .positiveIsMoneyOut, isBuiltIn: true),
        ImportProfile(id: "citi-card", name: "Citi credit card", accountType: .creditCard,
                      requiredHeaders: ["Status", "Date", "Description", "Debit", "Credit"],
                      dateColumn: "Date", descriptionColumn: "Description", debitColumn: "Debit", creditColumn: "Credit",
                      statusColumn: "Status", pendingValues: ["Pending"], isBuiltIn: true),
        ImportProfile(id: "capital-one-card", name: "Capital One credit card", accountType: .creditCard,
                      requiredHeaders: ["Transaction Date", "Posted Date", "Card No.", "Description", "Debit", "Credit"],
                      dateColumn: "Transaction Date", postedDateColumn: "Posted Date", descriptionColumn: "Description",
                      categoryColumn: "Category", debitColumn: "Debit", creditColumn: "Credit",
                      cardNumberColumn: "Card No.", isBuiltIn: true),
        ImportProfile(id: "wells-fargo", name: "Wells Fargo", accountType: nil,
                      requiredHeaders: ["Date", "Description", "Amount", "Status"],
                      forbiddenHeaders: ["Clearing Date", "Posting Date"],
                      dateColumn: "Date", descriptionColumn: "Description", amountColumn: "Amount",
                      signConvention: .positiveIsMoneyIn, statusColumn: "Status", pendingValues: ["Pending"],
                      checkNumberColumn: "Check #", isBuiltIn: true),
        ImportProfile(id: "wells-fargo-classic", name: "Wells Fargo (no header)", accountType: nil, hasHeader: false,
                      requiredHeaders: [], headerlessColumns: ["Date", "Amount", "Marker", "Check #", "Description"],
                      headerlessShape: .wellsFargoClassic,
                      dateColumn: "Date", descriptionColumn: "Description", amountColumn: "Amount",
                      signConvention: .positiveIsMoneyIn, checkNumberColumn: "Check #", dateLayout: .monthDayYear,
                      isBuiltIn: true),
        ImportProfile(id: "comenity-card", name: "Comenity store card (Macy's and others)", accountType: .creditCard,
                      hasHeader: false, requiredHeaders: [], headerlessColumns: ["Date", "Amount", "Description", "Type"],
                      headerlessShape: .comenity,
                      dateColumn: "Date", descriptionColumn: "Description", amountColumn: "Amount",
                      signConvention: .positiveIsMoneyOut, dateLayout: .monthDayYear, isBuiltIn: true),
        ImportProfile(id: "discover-card", name: "Discover card", accountType: .creditCard,
                      requiredHeaders: ["Trans. Date", "Post Date", "Description", "Amount"],
                      dateColumn: "Trans. Date", postedDateColumn: "Post Date", descriptionColumn: "Description",
                      categoryColumn: "Category", amountColumn: "Amount", signConvention: .positiveIsMoneyOut, isBuiltIn: true),
        ImportProfile(id: "amex-card", name: "American Express", accountType: .creditCard,
                      requiredHeaders: ["Date", "Description", "Card Member", "Amount"],
                      dateColumn: "Date", descriptionColumn: "Description", amountColumn: "Amount",
                      signConvention: .positiveIsMoneyOut, cardholderColumn: "Card Member", isBuiltIn: true),
        ImportProfile(id: "bank-of-america", name: "Bank of America checking", accountType: .checking,
                      requiredHeaders: ["Date", "Description", "Amount", "Running Bal."],
                      dateColumn: "Date", descriptionColumn: "Description", amountColumn: "Amount",
                      signConvention: .positiveIsMoneyIn, isBuiltIn: true)
    ]
}

/// Words that show a Wells Fargo file (one layout for both) is a credit card or a checking account.
enum AccountTypeMarkers {
    static let card = ["ONLINE PAYMENT, THANK YOU", "ONLINE PAYMENT THANK YOU", "INTEREST CHARGE ON PURCHASES",
                       "PAYMENT THANK YOU", "AUTOMATIC PAYMENT - THANK YOU", "AUTOPAY PAYMENT"]
    static let checking = ["ZELLE", "PAYROLL", "DIRECT DEP", "DIR DEP", "ATM ", "CASH DEPOSIT", "PURCHASE AUTHORIZED ON",
                           "ONLINE TRANSFER", "MOBILE DEPOSIT", "CHECK #"]

    static func guess(descriptions: [String]) -> AccountType? {
        let upper = descriptions.map { MerchantText.normalize($0) }
        let cardHits = card.filter { marker in upper.contains(where: { $0.contains(marker) }) }.count
        let checkingHits = checking.filter { marker in upper.contains(where: { $0.contains(marker) }) }.count
        if cardHits > 0, checkingHits == 0 { return .creditCard }
        if checkingHits > 0, cardHits == 0 { return .checking }
        return nil
    }
}
