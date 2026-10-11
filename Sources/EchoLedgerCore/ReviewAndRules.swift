import Foundation

/// Transactions needing review, grouped by merchant text so one decision can settle many.
public struct ReviewGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var key: String
    public var displayName: String
    public var example: String
    public var transactionIDs: [UUID]
    public var total: Cents
    public var firstDate: LocalDate
    public var lastDate: LocalDate
    public var isMoneyIn: Bool
    /// The suggestion shared by every transaction in the group, if they agree.
    public var suggestion: Suggestion?
    public var merchantID: UUID?
    public var accountNames: [String]

    public var count: Int { transactionIDs.count }
}

public enum ReviewQueue {
    public static func groups(_ ledger: Ledger) -> [ReviewGroup] {
        makeGroups(ledger.transactions.values.filter(\.needsReview), ledger: ledger)
    }

    /// Transactions Apple Intelligence filed that you haven't checked, grouped the same way.
    public static func aiFiledGroups(_ ledger: Ledger) -> [ReviewGroup] {
        makeGroups(ledger.aiFiledUnchecked, ledger: ledger)
    }

    static func makeGroups(_ open: [LedgerTransaction], ledger: Ledger) -> [ReviewGroup] {
        let grouped = Dictionary(grouping: open) { transaction -> String in
            let key = MerchantText(transaction.rawDescription).key
            return (transaction.amount > 0 ? "in|" : "out|") + key
        }
        var result: [ReviewGroup] = []
        for (groupID, items) in grouped {
            let sorted = items.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            guard let first = sorted.first, let last = sorted.last else { continue }
            let text = MerchantText(first.rawDescription)
            let suggestions = Set(sorted.compactMap(\.suggestion))
            let merchantIDs = Set(sorted.compactMap(\.merchantID))
            let accountNames = Set(sorted.compactMap { ledger.account($0.accountID)?.name }).sorted()
            let merchantID = merchantIDs.count == 1 ? merchantIDs.first : nil
            let name = merchantID.flatMap { ledger.merchants[$0]?.name } ?? text.displayName
            result.append(ReviewGroup(id: groupID, key: text.key, displayName: name, example: last.rawDescription,
                                      transactionIDs: sorted.map(\.id), total: sorted.reduce(Cents(0)) { $0 + $1.amount },
                                      firstDate: first.date, lastDate: last.date, isMoneyIn: first.amount > 0,
                                      suggestion: suggestions.count == 1 && sorted.allSatisfy({ $0.suggestion != nil }) ? suggestions.first : nil,
                                      merchantID: merchantID, accountNames: accountNames))
        }
        return result.sorted { ($0.count, abs($0.total), $1.id) > ($1.count, abs($1.total), $0.id) }
    }

    /// Pending charges that probably never posted: a newer file for the same account covers
    /// dates at least 5 days after them, or they're more than 14 days old.
    public static func stalePending(_ ledger: Ledger, today: LocalDate) -> [LedgerTransaction] {
        ledger.transactions.values.filter { transaction in
            guard transaction.isActive, transaction.status == .pending else { return false }
            if transaction.date.days(until: today) > 14 { return true }
            return ledger.batches.contains { batch in
                batch.accountID == transaction.accountID && batch.id != transaction.batchID
                    && (batch.lastDate.map { $0 >= transaction.date.adding(days: 5) } ?? false)
            }
        }
        .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
    }
}

// MARK: - Rule preview

/// What a rule would do if saved, before you save it.
public struct RulePreview: Sendable {
    /// Every transaction the rule's conditions match.
    public var matchingIDs: [UUID]
    /// Matches whose result would change.
    public var changingIDs: [UUID]
    /// Matches you confirmed by hand; rules never change those.
    public var confirmedIDs: [UUID]
    /// Matches an earlier rule in your list catches first: (rule name, count).
    public var shadowedBy: [(name: String, count: Int)]

    public static func compute(_ rule: Rule, ledger: Ledger, position: Int? = nil) -> RulePreview {
        var probe = rule
        probe.isEnabled = true
        let single = Matcher(rules: [probe], merchants: Array(ledger.merchants.values), categories: ledger.categories,
                             accounts: ledger.accounts, people: ledger.people,
                             disabledBuiltIns: Set(ledger.settings.disabledBuiltInRules))
        let ordered = ledger.orderedRules.filter { $0.id != rule.id }
        let earlier = Array(ordered.prefix(position ?? 0))
        let earlierMatchers = earlier.map { other in
            (other, Matcher(rules: [other], merchants: [], categories: ledger.categories, accounts: ledger.accounts,
                            people: [], disabledBuiltIns: []))
        }
        var matching: [UUID] = []
        var changing: [UUID] = []
        var confirmed: [UUID] = []
        var shadow: [String: Int] = [:]
        // Simulate the ledger with this rule in place to see what would change.
        var simulated = ledger
        if let index = simulated.rules.firstIndex(where: { $0.id == rule.id }) {
            simulated.rules[index] = probe
        } else {
            simulated.rules.append(probe)
        }
        var order = ordered.map(\.id)
        order.insert(rule.id, at: min(position ?? 0, order.count))
        simulated.settings.ruleOrder = order
        let full = Matcher(ledger: simulated)
        for transaction in ledger.transactions.values.sorted(by: { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) })
        where transaction.isActive {
            let normalized = MerchantText.normalize(transaction.rawDescription)
            guard single.firstMatchingRule(transaction, normalized: normalized) != nil else { continue }
            matching.append(transaction.id)
            if transaction.review == .confirmed {
                confirmed.append(transaction.id)
                continue
            }
            if let blocker = earlierMatchers.first(where: { $0.1.firstMatchingRule(transaction, normalized: normalized) != nil }) {
                shadow[blocker.0.name, default: 0] += 1
                continue
            }
            let result = full.match(transaction)
            if result.kind != transaction.kind || result.categoryID != transaction.categoryID
                || (result.merchantID != nil && result.merchantID != transaction.merchantID) || result.newMerchantName != nil {
                changing.append(transaction.id)
            }
        }
        let shadowList = shadow.map { (name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
        return RulePreview(matchingIDs: matching, changingIDs: changing, confirmedIDs: confirmed, shadowedBy: shadowList)
    }
}

// MARK: - Rule suggestions

/// A rule proposed from corrections you keep making by hand.
public struct RuleSuggestion: Identifiable, Hashable, Sendable {
    public var id: String
    public var pattern: String
    public var merchantName: String?
    public var kind: TransactionKind
    public var categoryID: UUID?
    /// Your corrections it is based on.
    public var exampleIDs: [UUID]
    /// Everything the pattern would match.
    public var matchCount: Int
    /// Matches you confirmed with a different result (a rule won't change them, but look).
    public var conflictIDs: [UUID]

    public func makeRule(categoryName: String?) -> Rule {
        let target = merchantName ?? categoryName ?? kind.label
        return Rule(name: "\(pattern.capitalized) → \(target)", match: .contains, pattern: pattern,
                    merchantName: merchantName, kind: kind, categoryID: categoryID)
    }
}

public enum RuleSuggester {
    /// Looks for groups of your manual corrections with the same result whose bank text shares a
    /// common beginning (at least 5 letters), that no rule or learned merchant already covers.
    public static func suggestions(_ ledger: Ledger) -> [RuleSuggestion] {
        let manual = ledger.transactions.values.filter { $0.isActive && $0.method == .manual && $0.review == .confirmed }
        let groups = Dictionary(grouping: manual) { transaction in
            "\(transaction.merchantID?.uuidString ?? "-")|\(transaction.kind.rawValue)|\(transaction.categoryID?.uuidString ?? "-")"
        }
        let matcher = Matcher(ledger: ledger)
        let existingPatterns = Set(ledger.rules.map { MerchantText.normalize($0.pattern) })
        var result: [RuleSuggestion] = []
        for (groupID, items) in groups {
            guard items.count >= 2, let first = items.first else { continue }
            // Skip when learning already handles every one of them.
            let uncovered = items.filter { item in
                var probe = item
                probe.review = .unresolved
                let outcome = matcher.match(probe)
                return outcome.kind != item.kind || outcome.categoryID != item.categoryID
            }
            guard uncovered.count >= 2 else { continue }
            let cores = uncovered.map { MerchantText($0.rawDescription).core.split(separator: " ").map(String.init) }
            var prefix: [String] = cores[0]
            for words in cores.dropFirst() {
                var cut = 0
                while cut < min(prefix.count, words.count), prefix[cut] == words[cut] { cut += 1 }
                prefix = Array(prefix.prefix(cut))
            }
            // Drop trailing store numbers from the shared beginning.
            while let last = prefix.last, MerchantText.isReferenceToken(last) || last.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                prefix.removeLast()
            }
            let pattern = prefix.joined(separator: " ")
            guard pattern.filter({ $0.isLetter }).count >= 5, !existingPatterns.contains(pattern) else { continue }
            let all = ledger.transactions.values.filter { $0.isActive && MerchantText.normalize($0.rawDescription).contains(pattern) }
            let conflicts = all.filter {
                $0.review == .confirmed && ($0.kind != first.kind || $0.categoryID != first.categoryID)
            }
            let merchantName = first.merchantID.flatMap { ledger.merchants[$0]?.name }
            result.append(RuleSuggestion(id: groupID + "|" + pattern, pattern: pattern, merchantName: merchantName,
                                         kind: first.kind, categoryID: first.categoryID,
                                         exampleIDs: uncovered.map(\.id).sorted { $0.uuidString < $1.uuidString },
                                         matchCount: all.count, conflictIDs: conflicts.map(\.id)))
        }
        return result.sorted { ($0.exampleIDs.count, $1.pattern) > ($1.exampleIDs.count, $0.pattern) }
    }
}
