import Foundation

/// One merchant in the built-in list.
public struct DirectoryEntry: Sendable, Hashable {
    public let name: String
    public let category: String
    /// Upper-case phrases matched with word boundaries. A trailing "~" lets the last word
    /// continue ("COINBASE~" also matches "COINBASEINC").
    public let phrases: [String]
}

/// A built-in rule for generic bank wording (card payments, interest, payroll, ATM…).
public struct BuiltInRule: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let pattern: String
    public let direction: AmountDirection
    /// Empty means every account type.
    public let accountTypes: [AccountType]
    public let kind: TransactionKind
    public let categoryName: String?
}

public enum BuiltInKnowledge {
    public static var merchants: [DirectoryEntry] { merchantEntries }
    public static var rules: [BuiltInRule] { ruleEntries }
}

/// The built-in merchant list, compiled for fast lookups. The longest matching phrase wins, so
/// "UBER *EATS" beats "UBER" and "COSTCO GAS" beats "COSTCO".
public struct MerchantDirectory: Sendable {
    struct CompiledPhrase: Sendable {
        let bytes: [UInt8]
        let allowSuffix: Bool
        let entryIndex: Int
        let text: String
    }

    public let entries: [DirectoryEntry]
    let phrases: [CompiledPhrase]
    /// Grouping keys for every phrase, for "looks similar" suggestions.
    let phraseKeys: [(key: String, entryIndex: Int)]

    public static let shared = MerchantDirectory(entries: BuiltInKnowledge.merchantEntries)

    public init(entries: [DirectoryEntry]) {
        self.entries = entries
        var compiled: [(phrase: CompiledPhrase, order: Int)] = []
        var keys: [(key: String, entryIndex: Int)] = []
        var order = 0
        for (entryIndex, entry) in entries.enumerated() {
            for phrase in entry.phrases {
                let allowSuffix = phrase.hasSuffix("~")
                let text = allowSuffix ? String(phrase.dropLast()) : phrase
                compiled.append((CompiledPhrase(bytes: Array(text.utf8), allowSuffix: allowSuffix,
                                                entryIndex: entryIndex, text: text), order))
                order += 1
                let key = MerchantText.makeKey(text)
                if key.count >= 3 { keys.append((key: key, entryIndex: entryIndex)) }
            }
            let nameKey = MerchantText.makeKey(MerchantText.normalize(entry.name))
            if nameKey.count >= 3 { keys.append((key: nameKey, entryIndex: entryIndex)) }
        }
        compiled.sort { left, right in
            if left.phrase.bytes.count != right.phrase.bytes.count {
                return left.phrase.bytes.count > right.phrase.bytes.count
            }
            return left.order < right.order
        }
        phrases = compiled.map { $0.phrase }
        phraseKeys = keys
    }

    public struct Hit: Sendable, Hashable {
        public let entry: DirectoryEntry
        public let phrase: String
    }

    /// Finds the merchant for upper-case text, longest phrase first.
    public func match(_ upperText: String) -> Hit? {
        let bytes = Array(upperText.utf8)
        for phrase in phrases where PhraseSearch.contains(bytes, phrase: phrase.bytes, allowSuffix: phrase.allowSuffix) {
            return Hit(entry: entries[phrase.entryIndex], phrase: phrase.text)
        }
        return nil
    }

    /// The most similar listed merchant to a grouping key, when it is clearly the best:
    /// at least `minimumScore` and 5 points ahead of any other merchant.
    public func closest(toKey key: String, minimumScore: Int) -> (entry: DirectoryEntry, score: Int)? {
        var bestPerEntry: [Int: Int] = [:]
        for candidate in phraseKeys {
            let score = KeySimilarity.score(key, candidate.key, floor: minimumScore - 5)
            if score > (bestPerEntry[candidate.entryIndex] ?? -1) {
                bestPerEntry[candidate.entryIndex] = score
            }
        }
        var bestIndex = -1
        var bestScore = -1
        var runnerUp = -1
        for (index, score) in bestPerEntry.sorted(by: { $0.key < $1.key }) {
            if score > bestScore {
                runnerUp = bestScore
                bestScore = score
                bestIndex = index
            } else if score > runnerUp {
                runnerUp = score
            }
        }
        guard bestIndex >= 0, bestScore >= minimumScore, bestScore - max(runnerUp, 0) >= 5 else { return nil }
        return (entries[bestIndex], bestScore)
    }
}

/// Built-in rules compiled once.
public enum BuiltInRuleSet {
    struct Compiled: @unchecked Sendable {
        let rule: BuiltInRule
        let regex: NSRegularExpression
    }

    nonisolated(unsafe) static let compiled: [Compiled] = BuiltInKnowledge.ruleEntries.map { rule in
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid built-in rule \(rule.id): \(error)")
        }
        return Compiled(rule: rule, regex: regex)
    }

    /// The first enabled built-in rule that matches.
    static func match(normalized: String, amount: Cents, accountType: AccountType?, disabled: Set<String>) -> BuiltInRule? {
        let range = NSRange(normalized.startIndex..., in: normalized)
        for item in compiled {
            let rule = item.rule
            if disabled.contains(rule.id) { continue }
            if !rule.direction.allows(amount) { continue }
            if !rule.accountTypes.isEmpty {
                guard let accountType, rule.accountTypes.contains(accountType) else { continue }
            }
            if item.regex.firstMatch(in: normalized, range: range) != nil {
                return rule
            }
        }
        return nil
    }
}

/// Maps the category names some banks print (Chase, Apple Card, Capital One) onto EchoLedger's
/// default categories. Only used for suggestions you approve, never automatically.
public enum BankCategoryMap {
    static let table: [String: String] = [
        "FOOD & DRINK": "Dining", "RESTAURANTS": "Dining", "DINING": "Dining", "RESTAURANT": "Dining",
        "GROCERIES": "Groceries", "GROCERY": "Groceries", "SUPERMARKETS": "Groceries",
        "GAS": "Transportation", "GAS/AUTOMOTIVE": "Transportation", "AUTOMOTIVE": "Transportation",
        "TRANSPORTATION": "Transportation", "TRAVEL": "Travel", "OTHER TRAVEL": "Travel", "AIRFARE": "Travel",
        "LODGING": "Travel", "SHOPPING": "Shopping", "MERCHANDISE": "Shopping", "HOME": "Shopping",
        "BILLS & UTILITIES": "Utilities", "UTILITIES": "Utilities", "PHONE/CABLE": "Utilities",
        "ENTERTAINMENT": "Entertainment", "HEALTH & WELLNESS": "Health", "MEDICAL": "Health",
        "HEALTH CARE": "Health", "HEALTHCARE": "Health", "PERSONAL": "Personal Care", "EDUCATION": "Education",
        "GIFTS & DONATIONS": "Gifts & Donations", "FEES & ADJUSTMENTS": "Fees & Interest",
        "FEE/INTEREST CHARGE": "Fees & Interest", "INSURANCE": "Insurance", "PROFESSIONAL SERVICES": "Other Spending"
    ]

    public static func categoryName(for bankCategory: String?) -> String? {
        guard let bankCategory else { return nil }
        let key = MerchantText.normalize(bankCategory)
        return table[key]
    }
}
