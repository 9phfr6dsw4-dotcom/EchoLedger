import Foundation

/// The outcome of matching one transaction.
public struct MatchResult: Equatable, Sendable {
    public var kind: TransactionKind
    public var categoryID: UUID?
    /// An existing merchant, or `newMerchantName` when the merchant has to be created.
    public var merchantID: UUID?
    public var newMerchantName: String?
    public var method: MatchMethod
    public var evidence: String
    public var review: ReviewState
    public var suggestion: Suggestion?

    public static let unresolved = MatchResult(kind: .unknown, categoryID: nil, merchantID: nil, newMerchantName: nil,
                                               method: .none, evidence: "No rule or known merchant matched.",
                                               review: .unresolved, suggestion: nil)
}

/// Decides merchant and category, in this order (first source that answers wins):
/// 1. your rules (top to bottom)
/// 2. money to or from a household member (names from Settings)
/// 3. merchants you've taught EchoLedger (exact key, then whole-word prefix)
/// 4. built-in rules for generic bank wording (card payments, interest, payroll…)
/// 5. the built-in merchant list
/// 6. Apple Intelligence's earlier filing of the same bank text
/// Then, only as suggestions for you to approve: a clearly similar known merchant, or the
/// category your bank printed. The merchant (who) and the category (what for) are decided
/// separately, so recognizing PayPal or Amazon never decides a category on its own.
public struct Matcher {
    struct CompiledRule {
        let rule: Rule
        let upperPattern: String
        let regex: NSRegularExpression?
    }

    let compiledRules: [CompiledRule]
    let merchantsByID: [UUID: Merchant]
    let merchantIDByKey: [String: UUID]
    let merchantIDByName: [String: UUID]
    let prefixKeys: [(key: String, id: UUID)]
    let categoriesByID: [UUID: LedgerCategory]
    let categoryIDByName: [String: UUID]
    let accountsByID: [UUID: Account]
    let household: [(phrase: [UInt8], person: Person)]
    let disabledBuiltIns: Set<String>
    let directory: MerchantDirectory
    let aiFilingsByKey: [String: AIFiling]
    let aiPrefixKeys: [String]
    /// Results that depend only on text, reused across many transactions in one matching run.
    private let memo = MatchMemo()

    final class MatchMemo {
        var texts: [String: MerchantText] = [:]
        var directoryHits: [String: MerchantDirectory.Hit?] = [:]
        var closest: [String: (entry: DirectoryEntry, score: Int)?] = [:]
        var similar: [String: (merchant: Merchant, score: Int)?] = [:]
    }

    func text(_ raw: String) -> MerchantText {
        if let cached = memo.texts[raw] { return cached }
        let value = MerchantText(raw)
        memo.texts[raw] = value
        return value
    }

    func directoryMatch(_ upper: String) -> MerchantDirectory.Hit? {
        if let cached = memo.directoryHits[upper] { return cached }
        let value = directory.match(upper)
        memo.directoryHits[upper] = value
        return value
    }

    public init(ledger: Ledger, directory: MerchantDirectory = .shared) {
        self.init(rules: ledger.orderedRules, merchants: Array(ledger.merchants.values), categories: ledger.categories,
                  accounts: ledger.accounts, people: ledger.people,
                  disabledBuiltIns: Set(ledger.settings.disabledBuiltInRules), aiFilings: Array(ledger.aiFilings.values),
                  directory: directory)
    }

    public init(rules: [Rule], merchants: [Merchant], categories: [LedgerCategory], accounts: [Account],
                people: [Person], disabledBuiltIns: Set<String>, aiFilings: [AIFiling] = [],
                directory: MerchantDirectory = .shared) {
        var filings: [String: AIFiling] = [:]
        for filing in aiFilings where !filing.rejected && !filing.key.isEmpty { filings[filing.key] = filing }
        aiFilingsByKey = filings
        aiPrefixKeys = filings.keys.filter { $0.split(separator: " ").count >= 2 || $0.count >= 6 }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }
        compiledRules = rules.filter { $0.isEnabled && $0.hasOutcome && !$0.pattern.isEmpty }.map { rule in
            var regex: NSRegularExpression?
            if rule.match == .regex {
                regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])
            }
            return CompiledRule(rule: rule, upperPattern: MerchantText.normalize(rule.pattern), regex: regex)
        }
        var byID: [UUID: Merchant] = [:]
        var byKey: [String: UUID] = [:]
        var byName: [String: UUID] = [:]
        var prefixes: [(key: String, id: UUID)] = []
        for merchant in merchants.sorted(by: { $0.name < $1.name || ($0.name == $1.name && $0.id.uuidString < $1.id.uuidString) }) {
            byID[merchant.id] = merchant
            byName[merchant.name.lowercased()] = byName[merchant.name.lowercased()] ?? merchant.id
            for key in merchant.keys where !key.isEmpty {
                byKey[key] = byKey[key] ?? merchant.id
                let words = key.split(separator: " ").count
                if words >= 2 || key.count >= 6 { prefixes.append((key: key, id: merchant.id)) }
            }
        }
        prefixes.sort { $0.key.count > $1.key.count || ($0.key.count == $1.key.count && $0.key < $1.key) }
        merchantsByID = byID
        merchantIDByKey = byKey
        merchantIDByName = byName
        prefixKeys = prefixes
        var catByID: [UUID: LedgerCategory] = [:]
        var catByName: [String: UUID] = [:]
        for category in categories {
            catByID[category.id] = category
            catByName[category.name.lowercased()] = catByName[category.name.lowercased()] ?? category.id
        }
        categoriesByID = catByID
        categoryIDByName = catByName
        var accountMap: [UUID: Account] = [:]
        for account in accounts { accountMap[account.id] = account }
        accountsByID = accountMap
        var names: [(phrase: [UInt8], person: Person)] = []
        for person in people {
            for name in person.bankNames {
                let normalized = MerchantText.normalize(name)
                if normalized.count >= 4 { names.append((phrase: Array(normalized.utf8), person: person)) }
            }
        }
        names.sort { $0.phrase.count > $1.phrase.count }
        household = names
        self.disabledBuiltIns = disabledBuiltIns
        self.directory = directory
    }

    // MARK: Rules

    /// The first of your enabled rules that matches, if any.
    public func firstMatchingRule(_ transaction: LedgerTransaction, normalized: String) -> Rule? {
        for compiled in compiledRules where ruleMatches(compiled, transaction: transaction, normalized: normalized) {
            return compiled.rule
        }
        return nil
    }

    func ruleMatches(_ compiled: CompiledRule, transaction: LedgerTransaction, normalized: String) -> Bool {
        let rule = compiled.rule
        if !rule.accountIDs.isEmpty, !rule.accountIDs.contains(transaction.accountID) { return false }
        if !rule.direction.allows(transaction.amount) { return false }
        let size = transaction.amount.magnitude
        if let minimum = rule.minimumAmount, size < minimum.magnitude { return false }
        if let maximum = rule.maximumAmount, size > maximum.magnitude { return false }
        return Matcher.textMatches(compiled.rule.match, pattern: compiled.upperPattern, regex: compiled.regex, normalized: normalized)
    }

    static func textMatches(_ match: TextMatch, pattern: String, regex: NSRegularExpression?, normalized: String) -> Bool {
        switch match {
        case .contains: return !pattern.isEmpty && normalized.contains(pattern)
        case .startsWith: return !pattern.isEmpty && normalized.hasPrefix(pattern)
        case .exact: return normalized == pattern
        case .regex:
            guard let regex else { return false }
            return regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
        }
    }

    // MARK: Matching

    private struct MerchantPick {
        var id: UUID?
        var name: String?
        var note: String
    }

    private struct ClassPick {
        var kind: TransactionKind?
        var categoryID: UUID?
        var method: MatchMethod
        var note: String
    }

    public func match(_ transaction: LedgerTransaction) -> MatchResult {
        let text = self.text(transaction.rawDescription)
        let normalized = text.normalized
        let account = accountsByID[transaction.accountID]
        var merchant: MerchantPick?
        var classification: ClassPick?

        // 1. Your rules.
        if let rule = firstMatchingRule(transaction, normalized: normalized) {
            if let name = rule.merchantName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                merchant = MerchantPick(id: merchantIDByName[name.lowercased()], name: name, note: "your rule “\(rule.name)”")
            }
            if rule.kind != nil || rule.categoryID != nil {
                classification = ClassPick(kind: rule.kind, categoryID: rule.categoryID, method: .userRule,
                                           note: "Your rule “\(rule.name)”")
            }
        }

        // 2. Household members (money between you and your household is a transfer).
        if classification == nil || merchant == nil {
            let bytes = Array(normalized.utf8)
            if let hit = household.first(where: { PhraseSearch.contains(bytes, phrase: $0.phrase, allowSuffix: false) }) {
                if merchant == nil {
                    merchant = MerchantPick(id: merchantIDByName[hit.person.name.lowercased()], name: hit.person.name,
                                            note: "household member")
                }
                if classification == nil {
                    classification = ClassPick(kind: .transfer, categoryID: nil, method: .builtInRule,
                                               note: "Money to or from \(hit.person.name) (your household)")
                }
            }
        }

        // 3. Merchants you've taught EchoLedger.
        if merchant == nil || classification == nil {
            if let learnedID = learnedMerchant(forKey: text.key), let learned = merchantsByID[learnedID] {
                if merchant == nil {
                    merchant = MerchantPick(id: learned.id, name: learned.name, note: "learned from you")
                }
                if classification == nil, merchant?.id == learned.id, learned.kind != nil || learned.categoryID != nil {
                    classification = ClassPick(kind: learned.kind, categoryID: learned.categoryID, method: .learned,
                                               note: "Learned: you filed \(learned.name) this way before")
                }
            }
        }
        if classification == nil, let id = merchant?.id, let known = merchantsByID[id],
           known.kind != nil || known.categoryID != nil {
            classification = ClassPick(kind: known.kind, categoryID: known.categoryID, method: .learned,
                                       note: "Learned: you filed \(known.name) this way before")
        }

        // 4. Built-in rules for generic bank wording.
        if classification == nil,
           let rule = BuiltInRuleSet.match(normalized: normalized, amount: transaction.amount,
                                           accountType: account?.type, disabled: disabledBuiltIns) {
            let categoryID = rule.categoryName.flatMap { categoryIDByName[$0.lowercased()] }
            classification = ClassPick(kind: rule.kind, categoryID: categoryID, method: .builtInRule,
                                       note: "Built-in rule: \(rule.name.lowercased())")
        }

        // 5. Built-in merchant list (bank text first, then the bank's own merchant column).
        var directoryHit = directoryMatch(text.core)
        var bankMerchantName: String?
        if directoryHit == nil, let bankMerchant = transaction.bankMerchant, !bankMerchant.isEmpty {
            directoryHit = directoryMatch(MerchantText.normalize(bankMerchant))
            bankMerchantName = bankMerchant.trimmingCharacters(in: .whitespaces)
        } else if let bankMerchant = transaction.bankMerchant, !bankMerchant.isEmpty {
            bankMerchantName = bankMerchant.trimmingCharacters(in: .whitespaces)
        }
        if let hit = directoryHit {
            if merchant == nil {
                merchant = MerchantPick(id: merchantIDByName[hit.entry.name.lowercased()], name: hit.entry.name,
                                        note: "built-in merchant list")
            }
            if classification == nil {
                if let id = merchant?.id, let known = merchantsByID[id], known.kind != nil || known.categoryID != nil {
                    classification = ClassPick(kind: known.kind, categoryID: known.categoryID, method: .learned,
                                               note: "Learned: you filed \(known.name) this way before")
                } else if let categoryID = categoryIDByName[hit.entry.category.lowercased()] {
                    classification = ClassPick(kind: nil, categoryID: categoryID, method: .directory,
                                               note: "Built-in merchant list: \(hit.entry.name)")
                }
            }
        }
        // 6. Apple Intelligence's earlier filing of this same bank text.
        if classification == nil, let filing = aiFiling(forKey: text.key) {
            if merchant == nil, let name = filing.merchantName, !name.isEmpty {
                merchant = MerchantPick(id: merchantIDByName[name.lowercased()], name: name, note: "Apple Intelligence")
            }
            let categoryID = filing.categoryID.flatMap { categoriesByID[$0] != nil ? $0 : nil }
            classification = ClassPick(kind: filing.kind, categoryID: categoryID, method: .ai,
                                       note: "Filed by Apple Intelligence: \(filing.reason)")
        }
        if merchant == nil, let name = bankMerchantName {
            merchant = MerchantPick(id: merchantIDByName[name.lowercased()], name: name, note: "bank's merchant name")
            if classification == nil, let id = merchant?.id, let known = merchantsByID[id],
               known.kind != nil || known.categoryID != nil {
                classification = ClassPick(kind: known.kind, categoryID: known.categoryID, method: .learned,
                                           note: "Learned: you filed \(known.name) this way before")
            }
        }

        if let classification, let kind = resolveKind(classification) {
            // A bank's merchant column on a payment ("ACH DEPOSIT INTERNET TRANSFER…") isn't a merchant.
            if kind == .transfer, merchant?.note == "bank's merchant name" { merchant = nil }
            let categoryID = kind == .transfer || kind == .unknown ? nil : classification.categoryID
            var evidence = classification.note
            if let merchant, let name = merchant.name, !classification.note.contains(name) {
                evidence += ". Merchant \(name) from \(merchant.note)"
            }
            if kind == .expense, transaction.amount > 0 {
                evidence += ". Money in, so it counts as a refund"
            }
            return MatchResult(kind: kind, categoryID: categoryID, merchantID: merchant?.id,
                               newMerchantName: merchant?.id == nil ? merchant?.name : nil,
                               method: classification.method, evidence: evidence + ".",
                               review: .automatic, suggestion: nil)
        }

        // Not decided: offer a suggestion if one is clearly likely.
        var result = MatchResult.unresolved
        if let merchant {
            result.merchantID = merchant.id
            result.newMerchantName = merchant.id == nil ? merchant.name : nil
            result.evidence = "Merchant \(merchant.name ?? "") from \(merchant.note); no category yet."
        }
        if merchant == nil, text.key.count >= 3 {
            if let similar = cachedSimilarLearned(text.key) {
                result.review = .suggested
                result.method = .similar
                result.suggestion = Suggestion(merchantName: similar.merchant.name, categoryID: similar.merchant.categoryID,
                                               kind: similar.merchant.kind ?? kindFor(categoryID: similar.merchant.categoryID) ?? .unknown,
                                               source: .similar,
                                               reason: "Looks like \(similar.merchant.name) (\(similar.score)% similar).")
                result.evidence = "Looks like \(similar.merchant.name); waiting for your OK."
                return result
            }
            if let close = cachedClosest(text.key) {
                let categoryID = categoryIDByName[close.entry.category.lowercased()]
                result.review = .suggested
                result.method = .similar
                result.suggestion = Suggestion(merchantName: close.entry.name, categoryID: categoryID,
                                               kind: kindFor(categoryID: categoryID) ?? .expense, source: .similar,
                                               reason: "Looks like \(close.entry.name) (\(close.score)% similar).")
                result.evidence = "Looks like \(close.entry.name); waiting for your OK."
                return result
            }
        }
        if let bankCategory = BankCategoryMap.categoryName(for: transaction.bankCategory),
           let categoryID = categoryIDByName[bankCategory.lowercased()] {
            result.review = .suggested
            result.method = .similar
            result.suggestion = Suggestion(merchantName: merchant?.name, categoryID: categoryID,
                                           kind: kindFor(categoryID: categoryID) ?? .expense, source: .similar,
                                           reason: "Your bank labeled this “\(transaction.bankCategory ?? "")”.")
            result.evidence = "Your bank's category suggests \(bankCategory); waiting for your OK."
        }
        return result
    }

    private func resolveKind(_ pick: ClassPick) -> TransactionKind? {
        if let kind = pick.kind { return kind }
        return kindFor(categoryID: pick.categoryID)
    }

    func kindFor(categoryID: UUID?) -> TransactionKind? {
        guard let categoryID, let category = categoriesByID[categoryID] else { return nil }
        return category.group == .income ? .income : .expense
    }

    /// Exact key first, then a taught key that is a whole-word prefix of this key
    /// ("JOES DINER" also covers "JOES DINER AUSTIN"). Longest taught key wins.
    func learnedMerchant(forKey key: String) -> UUID? {
        if let id = merchantIDByKey[key] { return id }
        for candidate in prefixKeys where key.hasPrefix(candidate.key + " ") {
            return candidate.id
        }
        return nil
    }

    /// Apple Intelligence's filing for this key: exact, then a filed key that is a whole-word prefix.
    func aiFiling(forKey key: String) -> AIFiling? {
        if let filing = aiFilingsByKey[key] { return filing }
        for candidate in aiPrefixKeys where key.hasPrefix(candidate + " ") {
            return aiFilingsByKey[candidate]
        }
        return nil
    }

    func cachedSimilarLearned(_ key: String) -> (merchant: Merchant, score: Int)? {
        if let cached = memo.similar[key] { return cached }
        let value = similarLearned(toKey: key)
        memo.similar[key] = value
        return value
    }

    func cachedClosest(_ key: String) -> (entry: DirectoryEntry, score: Int)? {
        if let cached = memo.closest[key] { return cached }
        let value = directory.closest(toKey: key, minimumScore: 88)
        memo.closest[key] = value
        return value
    }

    func similarLearned(toKey key: String) -> (merchant: Merchant, score: Int)? {
        var best: (id: UUID, score: Int)?
        var runnerUp = -1
        var bestPerMerchant: [UUID: Int] = [:]
        for (candidateKey, id) in merchantIDByKey {
            let score = KeySimilarity.score(key, candidateKey, floor: 83)
            if score > (bestPerMerchant[id] ?? -1) { bestPerMerchant[id] = score }
        }
        for (id, score) in bestPerMerchant.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let current = best {
                if score > current.score {
                    runnerUp = current.score
                    best = (id: id, score: score)
                } else if score > runnerUp {
                    runnerUp = score
                }
            } else {
                best = (id: id, score: score)
            }
        }
        guard let found = best, found.score >= 88, found.score - max(runnerUp, 0) >= 5,
              let merchant = merchantsByID[found.id] else { return nil }
        return (merchant, found.score)
    }
}
