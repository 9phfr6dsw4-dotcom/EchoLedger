import Foundation

// MARK: - Classification vocabulary

public enum TransactionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case expense
    case income
    case transfer
    case unknown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .expense: return "Spending"
        case .income: return "Income"
        case .transfer: return "Transfer"
        case .unknown: return "Needs review"
        }
    }
}

public enum TransactionStatus: String, Codable, Sendable {
    case posted
    case pending
}

/// How a transaction got its merchant and category. Shown to the user as the "why".
public enum MatchMethod: String, Codable, Sendable {
    case manual        // set by you
    case userRule      // one of your rules
    case learned       // learned from an earlier correction
    case builtInRule   // built-in rule (card payments, interest, payroll…)
    case directory     // built-in merchant list
    case bankMerchant  // the merchant name printed by the bank (Apple Card)
    case transferPair  // matched with the other side of a transfer
    case similar       // looks like a known merchant; waiting for your OK
    case ai            // Apple Intelligence suggestion; waiting for your OK
    case none

    public var label: String {
        switch self {
        case .manual: return "Set by you"
        case .userRule: return "Your rule"
        case .learned: return "Learned from you"
        case .builtInRule: return "Built-in rule"
        case .directory: return "Built-in merchant list"
        case .bankMerchant: return "Bank's merchant name"
        case .transferPair: return "Matching transfer"
        case .similar: return "Similar merchant"
        case .ai: return "Filed by Apple Intelligence"
        case .none: return "Not matched"
        }
    }
}

/// Where a transaction stands. Only confirmed and automatic results count as categorized in
/// reports; suggestions stay "Needs review" until you approve them.
public enum ReviewState: String, Codable, Sendable {
    case confirmed
    case automatic
    case suggested
    case unresolved
}

/// A proposed classification waiting for approval (from similarity or Apple Intelligence).
public struct Suggestion: Codable, Sendable, Hashable {
    public var merchantName: String?
    public var categoryID: UUID?
    public var kind: TransactionKind
    public var source: MatchMethod
    public var reason: String

    public init(merchantName: String?, categoryID: UUID?, kind: TransactionKind, source: MatchMethod, reason: String) {
        self.merchantName = merchantName
        self.categoryID = categoryID
        self.kind = kind
        self.source = source
        self.reason = reason
    }
}

// MARK: - Transactions

public struct LedgerTransaction: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var accountID: UUID
    public var batchID: UUID?
    /// Physical line in the source file (1-based).
    public var sourceLine: Int
    /// The purchase date (the posting date when the file has no separate purchase date).
    public var date: LocalDate
    public var postedDate: LocalDate?
    /// Positive = money in, negative = money out.
    public var amount: Cents
    public var currency: String
    /// Exactly as the bank printed it.
    public var rawDescription: String
    /// A merchant name printed in its own column by some banks (Apple Card).
    public var bankMerchant: String?
    public var bankCategory: String?
    public var checkNumber: String?
    public var status: TransactionStatus
    /// Date, amount and normalized description; used to recognize re-imported rows.
    public var fingerprint: String
    /// The nth identical row in its file (identical purchases on one day stay separate).
    public var occurrence: Int

    public var kind: TransactionKind
    public var categoryID: UUID?
    public var merchantID: UUID?
    public var method: MatchMethod
    public var evidence: String
    public var review: ReviewState
    public var suggestion: Suggestion?
    public var transferPairID: UUID?
    /// A pending row that a posted row replaced. Never counted.
    public var supersededBy: UUID?
    /// Removed by you (for example a pending charge that never posted). Never counted.
    public var voided: Bool
    public var note: String

    public init(
        id: UUID = UUID(), accountID: UUID, batchID: UUID?, sourceLine: Int, date: LocalDate,
        postedDate: LocalDate?, amount: Cents, currency: String, rawDescription: String,
        bankMerchant: String? = nil, bankCategory: String? = nil, checkNumber: String? = nil,
        status: TransactionStatus, fingerprint: String, occurrence: Int
    ) {
        self.id = id
        self.accountID = accountID
        self.batchID = batchID
        self.sourceLine = sourceLine
        self.date = date
        self.postedDate = postedDate
        self.amount = amount
        self.currency = currency
        self.rawDescription = rawDescription
        self.bankMerchant = bankMerchant
        self.bankCategory = bankCategory
        self.checkNumber = checkNumber
        self.status = status
        self.fingerprint = fingerprint
        self.occurrence = occurrence
        self.kind = .unknown
        self.categoryID = nil
        self.merchantID = nil
        self.method = .none
        self.evidence = ""
        self.review = .unresolved
        self.suggestion = nil
        self.transferPairID = nil
        self.supersededBy = nil
        self.voided = false
        self.note = ""
    }

    /// Still part of your records (not replaced and not removed).
    public var isActive: Bool { supersededBy == nil && !voided }

    public var needsReview: Bool { isActive && (review == .suggested || review == .unresolved) }

    public var isInflow: Bool { amount > 0 }
}

// MARK: - People, accounts, categories, merchants

public struct Person: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// How this person's name appears in bank text, for example on Zelle transfers.
    public var bankNames: [String]

    public init(id: UUID = UUID(), name: String, bankNames: [String] = []) {
        self.id = id
        self.name = name
        self.bankNames = bankNames
    }
}

public enum AccountType: String, Codable, Sendable, CaseIterable, Identifiable {
    case checking
    case savings
    case creditCard
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit card"
        case .other: return "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .checking: return "building.columns"
        case .savings: return "banknote"
        case .creditCard: return "creditcard"
        case .other: return "wallet.bifold"
        }
    }
}

public struct Account: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var personID: UUID?
    public var type: AccountType
    public var currency: String
    /// Last four digits, used to tell apart files from several cards at one bank.
    public var last4: String?
    /// The bank file layout this account's files use.
    public var profileID: String?
    /// Set when this bank prints money in and out the other way around from its layout.
    public var flipSigns: Bool
    public var isArchived: Bool
    /// Used only now and then: reports don't warn when it has gaps or no recent transactions.
    public var rarelyUsed: Bool
    /// You said this account's files are complete through this date, even if its last
    /// transaction is earlier.
    public var upToDateThrough: LocalDate?
    /// You said this account's history starts here, so a report starting earlier isn't flagged.
    public var historyStartsOn: LocalDate?

    public init(id: UUID = UUID(), name: String, personID: UUID?, type: AccountType, currency: String = "USD",
                last4: String? = nil, profileID: String? = nil, flipSigns: Bool = false, isArchived: Bool = false,
                rarelyUsed: Bool = false, upToDateThrough: LocalDate? = nil, historyStartsOn: LocalDate? = nil) {
        self.id = id
        self.name = name
        self.personID = personID
        self.type = type
        self.currency = currency
        self.last4 = last4
        self.profileID = profileID
        self.flipSigns = flipSigns
        self.isArchived = isArchived
        self.rarelyUsed = rarelyUsed
        self.upToDateThrough = upToDateThrough
        self.historyStartsOn = historyStartsOn
    }

    /// Reads accounts saved by any earlier version (fields added later get their defaults).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        personID = try container.decodeIfPresent(UUID.self, forKey: .personID)
        type = try container.decode(AccountType.self, forKey: .type)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        last4 = try container.decodeIfPresent(String.self, forKey: .last4)
        profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        flipSigns = try container.decodeIfPresent(Bool.self, forKey: .flipSigns) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        rarelyUsed = try container.decodeIfPresent(Bool.self, forKey: .rarelyUsed) ?? false
        upToDateThrough = try container.decodeIfPresent(LocalDate.self, forKey: .upToDateThrough)
        historyStartsOn = try container.decodeIfPresent(LocalDate.self, forKey: .historyStartsOn)
    }
}

public enum CategoryGroup: String, Codable, Sendable, CaseIterable {
    case expense
    case income
}

public struct LedgerCategory: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var group: CategoryGroup
    /// Index into the app's chart palette.
    public var colorIndex: Int

    public init(id: UUID = UUID(), name: String, group: CategoryGroup, colorIndex: Int) {
        self.id = id
        self.name = name
        self.group = group
        self.colorIndex = colorIndex
    }

    /// The categories a new ledger starts with. You can rename, add and remove them.
    public static func defaults() -> [LedgerCategory] {
        let expenses = ["Housing", "Utilities", "Groceries", "Dining", "Transportation", "Shopping",
                        "Subscriptions", "Health", "Personal Care", "Entertainment", "Travel", "Education",
                        "Insurance", "Pets", "Gifts & Donations", "Cash & ATM", "Fees & Interest", "Taxes",
                        "Other Spending"]
        let incomes = ["Salary", "Interest & Rewards", "Refunds & Settlements", "Other Income"]
        var result: [LedgerCategory] = []
        for (index, name) in expenses.enumerated() {
            result.append(LedgerCategory(name: name, group: .expense, colorIndex: index))
        }
        for (index, name) in incomes.enumerated() {
            result.append(LedgerCategory(name: name, group: .income, colorIndex: index))
        }
        return result
    }
}

public struct Merchant: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Your default category for this merchant (set when you choose "remember").
    public var categoryID: UUID?
    /// Your default kind for this merchant (for example Transfer for a family member).
    public var kind: TransactionKind?
    /// Cleaned bank-text keys you've told EchoLedger belong to this merchant.
    public var keys: [String]
    /// Set when you named this merchant yourself, so Apple Intelligence never renames it.
    public var nameLocked: Bool

    public init(id: UUID = UUID(), name: String, categoryID: UUID? = nil, kind: TransactionKind? = nil, keys: [String] = [],
                nameLocked: Bool = false) {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.kind = kind
        self.keys = keys
        self.nameLocked = nameLocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        kind = try container.decodeIfPresent(TransactionKind.self, forKey: .kind)
        keys = try container.decodeIfPresent([String].self, forKey: .keys) ?? []
        nameLocked = try container.decodeIfPresent(Bool.self, forKey: .nameLocked) ?? false
    }
}

/// How Apple Intelligence filed one piece of bank text (a merchant key). Reused for later
/// transactions with the same text, so the model isn't asked again. Your rules, your
/// corrections and what you've taught EchoLedger always come first.
public struct AIFiling: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var merchantName: String?
    public var categoryID: UUID?
    public var kind: TransactionKind
    public var reason: String
    public var date: Date
    /// Set when you corrected a transaction it filed: the filing is no longer used, and
    /// Apple Intelligence won't file this text again.
    public var rejected: Bool

    public var id: String { key }

    public init(key: String, merchantName: String?, categoryID: UUID?, kind: TransactionKind, reason: String,
                date: Date = Date(), rejected: Bool = false) {
        self.key = key
        self.merchantName = merchantName
        self.categoryID = categoryID
        self.kind = kind
        self.reason = reason
        self.date = date
        self.rejected = rejected
    }
}

// MARK: - Rules

public enum TextMatch: String, Codable, Sendable, CaseIterable, Identifiable {
    case contains
    case startsWith
    case exact
    case regex

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .contains: return "contains"
        case .startsWith: return "starts with"
        case .exact: return "is exactly"
        case .regex: return "matches pattern"
        }
    }
}

public enum AmountDirection: String, Codable, Sendable, CaseIterable, Identifiable {
    case any
    case moneyIn
    case moneyOut

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .any: return "Money in or out"
        case .moneyIn: return "Money in only"
        case .moneyOut: return "Money out only"
        }
    }

    public func allows(_ amount: Cents) -> Bool {
        switch self {
        case .any: return true
        case .moneyIn: return amount > 0
        case .moneyOut: return amount < 0
        }
    }
}

/// One of your rules. Rules are checked top to bottom and the first match wins.
public struct Rule: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var match: TextMatch
    public var pattern: String
    /// Empty means every account.
    public var accountIDs: [UUID]
    public var direction: AmountDirection
    /// Optional limits on the size of the amount (in cents, ignoring sign).
    public var minimumAmount: Cents?
    public var maximumAmount: Cents?
    public var merchantName: String?
    public var kind: TransactionKind?
    public var categoryID: UUID?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, match: TextMatch, pattern: String,
                accountIDs: [UUID] = [], direction: AmountDirection = .any, minimumAmount: Cents? = nil,
                maximumAmount: Cents? = nil, merchantName: String? = nil, kind: TransactionKind? = nil,
                categoryID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.match = match
        self.pattern = pattern
        self.accountIDs = accountIDs
        self.direction = direction
        self.minimumAmount = minimumAmount
        self.maximumAmount = maximumAmount
        self.merchantName = merchantName
        self.kind = kind
        self.categoryID = categoryID
        self.createdAt = createdAt
    }

    public var hasOutcome: Bool {
        !(merchantName ?? "").trimmingCharacters(in: .whitespaces).isEmpty || kind != nil || categoryID != nil
    }
}

// MARK: - Imports, budgets, history

public struct ImportCounts: Codable, Sendable, Hashable {
    public var totalRows: Int = 0
    public var imported: Int = 0
    public var duplicates: Int = 0
    public var replacedPending: Int = 0
    public var heldDuplicates: Int = 0
    public var forcedDuplicates: Int = 0
    public var errors: Int = 0
    public var blank: Int = 0

    public init() {}
}

public struct ImportBatch: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var fileName: String
    public var fileHash: String
    public var accountID: UUID
    public var profileID: String
    public var importedAt: Date
    public var counts: ImportCounts
    public var firstDate: LocalDate?
    public var lastDate: LocalDate?

    public init(id: UUID = UUID(), fileName: String, fileHash: String, accountID: UUID, profileID: String,
                importedAt: Date = Date(), counts: ImportCounts, firstDate: LocalDate?, lastDate: LocalDate?) {
        self.id = id
        self.fileName = fileName
        self.fileHash = fileHash
        self.accountID = accountID
        self.profileID = profileID
        self.importedAt = importedAt
        self.counts = counts
        self.firstDate = firstDate
        self.lastDate = lastDate
    }
}

/// A monthly spending target for one category.
public struct Budget: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var categoryID: UUID
    public var monthlyAmount: Cents

    public init(id: UUID = UUID(), categoryID: UUID, monthlyAmount: Cents) {
        self.id = id
        self.categoryID = categoryID
        self.monthlyAmount = monthlyAmount
    }
}

/// One undoable change: the transactions as they were before, plus anything it created.
public struct ChangeSet: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var label: String
    public var before: [LedgerTransaction]
    public var merchantsBefore: [Merchant]
    public var createdMerchantIDs: [UUID]
    public var createdRuleIDs: [UUID]
    /// Apple Intelligence filings this change created (removed on undo).
    public var createdAIFilingKeys: [String]
    /// Apple Intelligence filings as they were before this change (restored on undo).
    public var aiFilingsBefore: [AIFiling]

    public init(id: UUID = UUID(), date: Date = Date(), label: String, before: [LedgerTransaction],
                merchantsBefore: [Merchant] = [], createdMerchantIDs: [UUID] = [], createdRuleIDs: [UUID] = [],
                createdAIFilingKeys: [String] = [], aiFilingsBefore: [AIFiling] = []) {
        self.id = id
        self.date = date
        self.label = label
        self.before = before
        self.merchantsBefore = merchantsBefore
        self.createdMerchantIDs = createdMerchantIDs
        self.createdRuleIDs = createdRuleIDs
        self.createdAIFilingKeys = createdAIFilingKeys
        self.aiFilingsBefore = aiFilingsBefore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        label = try container.decode(String.self, forKey: .label)
        before = try container.decodeIfPresent([LedgerTransaction].self, forKey: .before) ?? []
        merchantsBefore = try container.decodeIfPresent([Merchant].self, forKey: .merchantsBefore) ?? []
        createdMerchantIDs = try container.decodeIfPresent([UUID].self, forKey: .createdMerchantIDs) ?? []
        createdRuleIDs = try container.decodeIfPresent([UUID].self, forKey: .createdRuleIDs) ?? []
        createdAIFilingKeys = try container.decodeIfPresent([String].self, forKey: .createdAIFilingKeys) ?? []
        aiFilingsBefore = try container.decodeIfPresent([AIFiling].self, forKey: .aiFilingsBefore) ?? []
    }
}

/// Settings that belong with your data (rather than with the app window).
public struct LedgerSettings: Codable, Sendable, Hashable {
    public var timeZoneID: String = "America/Los_Angeles"
    public var keepSourceText: Bool = true
    public var disabledBuiltInRules: [String] = []
    public var reportCurrency: String = "USD"
    /// The order of your rules, top to bottom.
    public var ruleOrder: [UUID] = []
    /// Report notes you marked as seen (for example "This period isn't over yet" for one month).
    public var dismissedNotes: [String] = []

    public init() {}

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "America/Los_Angeles") ?? .current
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID) ?? "America/Los_Angeles"
        keepSourceText = try container.decodeIfPresent(Bool.self, forKey: .keepSourceText) ?? true
        disabledBuiltInRules = try container.decodeIfPresent([String].self, forKey: .disabledBuiltInRules) ?? []
        reportCurrency = try container.decodeIfPresent(String.self, forKey: .reportCurrency) ?? "USD"
        ruleOrder = try container.decodeIfPresent([UUID].self, forKey: .ruleOrder) ?? []
        dismissedNotes = try container.decodeIfPresent([String].self, forKey: .dismissedNotes) ?? []
    }
}
