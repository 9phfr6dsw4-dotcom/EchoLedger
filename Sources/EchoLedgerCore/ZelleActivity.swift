import Foundation

/// Why a Zelle happened. The bank text never says, so Review asks and you choose.
public enum ZelleChoice: String, CaseIterable, Identifiable, Sendable {
    case spending, giftSent, payingEachOther, income, sold, giftReceived, payingMeBack, dontCount

    public var id: String { rawValue }

    /// The choices that make sense for money going out or coming in.
    public static func choices(moneyIn: Bool) -> [ZelleChoice] {
        moneyIn ? [.income, .sold, .giftReceived, .payingMeBack, .payingEachOther, .dontCount]
            : [.spending, .giftSent, .payingEachOther, .dontCount]
    }

    public var label: String {
        switch self {
        case .spending: return "Bought something or paid someone back"
        case .giftSent: return "A gift I sent"
        case .payingEachOther: return "Paying each other back and forth"
        case .income: return "Income (paid for work)"
        case .sold: return "I sold something"
        case .giftReceived: return "A gift I received"
        case .payingMeBack: return "Paying me back"
        case .dontCount: return "Don't count it"
        }
    }

    /// How EchoLedger files it. Money in filed as spending lowers its category, like a refund.
    public var kind: TransactionKind {
        switch self {
        case .spending, .giftSent, .payingEachOther, .payingMeBack: return .expense
        case .income, .sold, .giftReceived: return .income
        case .dontCount: return .transfer
        }
    }

    /// The category used without asking; nil when you pick one (or when none is used).
    public var fixedCategoryName: String? {
        switch self {
        case .giftSent: return "Gifts & Donations"
        case .payingEachOther: return ZelleActivity.payingEachOtherCategory
        case .sold: return "Other Income"
        case .giftReceived: return ZelleActivity.giftsReceivedCategory
        case .spending, .income, .payingMeBack, .dontCount: return nil
        }
    }

    /// Whether you pick the category yourself.
    public var needsCategory: Bool {
        self == .spending || self == .income || self == .payingMeBack
    }

    /// Which list of categories applies (and where a missing fixed category is added).
    public var categoryGroup: CategoryGroup {
        kind == .income ? .income : .expense
    }
}

/// Everything one person (or business) did over Zelle in a report's period.
public struct ZelleLine: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Money that came in (positive).
    public var received: Cents
    /// Money that went out (positive).
    public var sent: Cents
    public var count: Int
    /// How the Zelles with this name are counted, for example "Spending: Groceries".
    public var howCounted: [String]
    public var transactionIDs: [UUID]

    public var net: Cents { received - sent }
}

/// Money moving between the people of the household (not counted as income or spending).
public struct HouseholdMoney: Hashable, Sendable {
    public var sent: Cents = 0
    public var received: Cents = 0
    public var sentIDs: [UUID] = []
    public var receivedIDs: [UUID] = []

    public var isEmpty: Bool { sentIDs.isEmpty && receivedIDs.isEmpty }
}

public struct ZelleSummary: Sendable {
    public var lines: [ZelleLine]
    public var received: Cents
    public var sent: Cents
    public var transactionIDs: [UUID]
    public var household: HouseholdMoney

    public var net: Cents { received - sent }
}

public enum ZelleActivity {
    public static let payingEachOtherCategory = "Paying each other"
    public static let giftsReceivedCategory = "Gifts received"

    /// True for bank text that is a Zelle payment ("Zelle payment to …", "ZELLE FROM …").
    public static func isZelle(_ rawDescription: String) -> Bool {
        MerchantText(rawDescription).via == "Zelle"
    }

    /// Every Zelle in the report's scope and period, by name, plus money moved inside the household.
    /// Nothing here changes how anything is counted.
    public static func build(_ ledger: Ledger, filter: ReportFilter) -> ZelleSummary {
        let phrases = householdPhrases(ledger)
        let rows = ledger.transactions.values
            .filter { $0.isActive && $0.status == .posted && filter.span.contains($0.date) && filter.includes($0, ledger: ledger) }
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }

        var names: [String: String] = [:]
        var received: [String: Cents] = [:]
        var sent: [String: Cents] = [:]
        var counts: [String: Int] = [:]
        var treatments: [String: Set<String>] = [:]
        var ids: [String: [UUID]] = [:]
        var allIDs: [UUID] = []
        var household = HouseholdMoney()

        for transaction in rows {
            let isHouseholdMoney = transaction.kind == .transfer && matchesHousehold(transaction, phrases: phrases)
            if isHouseholdMoney {
                if transaction.amount < 0 {
                    household.sent += -transaction.amount
                    household.sentIDs.append(transaction.id)
                } else {
                    household.received += transaction.amount
                    household.receivedIDs.append(transaction.id)
                }
            }
            guard isZelle(transaction.rawDescription) else { continue }
            let (key, name) = ReportEngine.merchantIdentity(transaction, ledger: ledger)
            names[key] = name
            counts[key, default: 0] += 1
            ids[key, default: []].append(transaction.id)
            allIDs.append(transaction.id)
            if transaction.amount < 0 { sent[key, default: 0] += -transaction.amount } else { received[key, default: 0] += transaction.amount }
            treatments[key, default: []].insert(treatment(transaction, ledger: ledger, isHouseholdMoney: isHouseholdMoney))
        }

        var lines: [ZelleLine] = []
        for (key, name) in names {
            lines.append(ZelleLine(id: key, name: name, received: received[key] ?? 0, sent: sent[key] ?? 0,
                                   count: counts[key] ?? 0, howCounted: (treatments[key] ?? []).sorted(),
                                   transactionIDs: ids[key] ?? []))
        }
        lines.sort { ($0.received + $0.sent, $1.name) > ($1.received + $1.sent, $0.name) }
        return ZelleSummary(lines: lines, received: received.values.reduce(0, +), sent: sent.values.reduce(0, +),
                            transactionIDs: allIDs, household: household)
    }

    /// How one Zelle is counted, in words.
    static func treatment(_ transaction: LedgerTransaction, ledger: Ledger, isHouseholdMoney: Bool) -> String {
        switch transaction.kind {
        case .income:
            let name = ledger.category(transaction.categoryID)?.name.lowercased()
            return name == giftsReceivedCategory.lowercased() ? "Gift received" : "Income"
        case .expense:
            let base = transaction.amount > 0 ? "Paying back" : "Spending"
            if let name = ledger.category(transaction.categoryID)?.name { return base + ": " + name }
            return base
        case .transfer:
            return isHouseholdMoney ? "Household, not counted" : "Not counted"
        case .unknown:
            return "Needs review"
        }
    }

    /// The names household members use in bank text, ready for matching (same rule as the Matcher).
    static func householdPhrases(_ ledger: Ledger) -> [[UInt8]] {
        var phrases: [[UInt8]] = []
        for person in ledger.people {
            for name in person.bankNames {
                let normalized = MerchantText.normalize(name)
                if normalized.count >= 4 { phrases.append(Array(normalized.utf8)) }
            }
        }
        return phrases
    }

    static func matchesHousehold(_ transaction: LedgerTransaction, phrases: [[UInt8]]) -> Bool {
        guard !phrases.isEmpty else { return false }
        let bytes = Array(MerchantText.normalize(transaction.rawDescription).utf8)
        return phrases.contains { PhraseSearch.contains(bytes, phrase: $0, allowSuffix: false) }
    }
}

extension Ledger {
    /// Files Zelles the way you chose in Review. The categories "Paying each other" and
    /// "Gifts received" are added the first time they're needed. One undoable change.
    public mutating func classifyZelle(_ ids: [UUID], merchantName: String?, choice: ZelleChoice, categoryID: UUID?,
                                       remember: Bool, label: String, now: Date = Date()) -> LedgerDelta {
        var delta = LedgerDelta()
        var category = categoryID
        if let name = choice.fixedCategoryName {
            let group = choice.categoryGroup
            if let existing = categories.first(where: { $0.name.lowercased() == name.lowercased() && $0.group == group }) {
                category = existing.id
            } else {
                let created = LedgerCategory(name: name, group: group,
                                             colorIndex: categories.filter { $0.group == group }.count)
                delta.merge(upsertCategory(created))
                category = created.id
            }
        }
        delta.merge(classify(ids, merchantName: merchantName, kind: choice.kind, categoryID: category,
                             remember: remember, label: label, now: now))
        return delta
    }
}
