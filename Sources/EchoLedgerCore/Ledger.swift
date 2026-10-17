import Foundation

/// Kinds of stored records.
public enum RecordKind: String, CaseIterable, Sendable {
    case person, account, category, merchant, rule, transaction, batch, budget, change, profile, aiFiling, settings
}

/// What changed in one operation, so the store can save exactly that.
public struct LedgerDelta: Sendable {
    public var changed: [RecordKind: Set<String>] = [:]
    public var deleted: [RecordKind: Set<String>] = [:]
    public var sourceLines: [SourceLine] = []
    public var deletedSourceBatches: [UUID] = []

    public init() {}

    public mutating func change(_ kind: RecordKind, _ id: UUID) { change(kind, id.uuidString) }

    public mutating func change(_ kind: RecordKind, _ id: String) {
        changed[kind, default: []].insert(id)
        deleted[kind]?.remove(id)
    }

    public mutating func delete(_ kind: RecordKind, _ id: UUID) { delete(kind, id.uuidString) }

    public mutating func delete(_ kind: RecordKind, _ id: String) {
        deleted[kind, default: []].insert(id)
        changed[kind]?.remove(id)
    }

    public mutating func merge(_ other: LedgerDelta) {
        for (kind, ids) in other.changed { for id in ids { change(kind, id) } }
        for (kind, ids) in other.deleted { for id in ids { delete(kind, id) } }
        sourceLines.append(contentsOf: other.sourceLines)
        deletedSourceBatches.append(contentsOf: other.deletedSourceBatches)
    }

    public var isEmpty: Bool {
        changed.values.allSatisfy(\.isEmpty) && deleted.values.allSatisfy(\.isEmpty)
            && sourceLines.isEmpty && deletedSourceBatches.isEmpty
    }
}

/// The original text of one file line, kept on this Mac for provenance.
public struct SourceLine: Sendable, Hashable {
    public var batchID: UUID
    public var line: Int
    public var text: String

    public init(batchID: UUID, line: Int, text: String) {
        self.batchID = batchID
        self.line = line
        self.text = text
    }
}

/// One file to save, with your choices from the preview.
public struct ImportCommitItem: Sendable {
    public var analysis: FileAnalysis
    public var plan: ImportPlan
    /// Possible duplicates (by line) you chose to import anyway.
    public var forcedLines: Set<Int>

    public init(analysis: FileAnalysis, plan: ImportPlan, forcedLines: Set<Int> = []) {
        self.analysis = analysis
        self.plan = plan
        self.forcedLines = forcedLines
    }
}

/// All of your financial data, in memory. Every change goes through a method here that returns
/// a `LedgerDelta`, which the store then saves in one database transaction.
public struct Ledger: Sendable {
    public var people: [Person] = []
    public var accounts: [Account] = []
    public var categories: [LedgerCategory] = []
    public var merchants: [UUID: Merchant] = [:]
    public var rules: [Rule] = []
    public var transactions: [UUID: LedgerTransaction] = [:]
    public var batches: [ImportBatch] = []
    public var budgets: [Budget] = []
    public var profiles: [ImportProfile] = []
    public var changes: [ChangeSet] = []
    /// How Apple Intelligence filed each piece of bank text, keyed by merchant key.
    public var aiFilings: [String: AIFiling] = [:]
    public var settings = LedgerSettings()

    public static let maximumUndoSteps = 50

    public init() {}

    /// A brand-new ledger with the default categories.
    public static func starter() -> Ledger {
        var ledger = Ledger()
        ledger.categories = LedgerCategory.defaults()
        return ledger
    }

    // MARK: Lookups

    public var orderedRules: [Rule] {
        let order = Dictionary(settings.ruleOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return rules.sorted { left, right in
            let l = order[left.id] ?? Int.max
            let r = order[right.id] ?? Int.max
            if l != r { return l < r }
            return left.createdAt < right.createdAt
        }
    }

    /// Your saved layouts first, then the built-in ones.
    public var allProfiles: [ImportProfile] { profiles + ImportProfile.builtIns }

    public func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    public func category(_ id: UUID?) -> LedgerCategory? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    public func category(named name: String) -> LedgerCategory? {
        categories.first { $0.name.lowercased() == name.lowercased() }
    }

    public func merchant(_ id: UUID?) -> Merchant? {
        guard let id else { return nil }
        return merchants[id]
    }

    public func merchant(named name: String) -> Merchant? {
        let lower = name.lowercased()
        return merchants.values.filter { $0.name.lowercased() == lower }
            .min { $0.id.uuidString < $1.id.uuidString }
    }

    public func person(_ id: UUID?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    public var activeTransactions: [LedgerTransaction] {
        transactions.values.filter(\.isActive)
    }

    public var reviewCount: Int {
        transactions.values.filter(\.needsReview).count
    }

    /// Transactions Apple Intelligence filed that you haven't checked yet.
    public var aiFiledUnchecked: [LedgerTransaction] {
        transactions.values.filter { $0.isActive && $0.method == .ai && $0.review == .automatic }
    }

    /// Bank text you corrected after Apple Intelligence filed it; it isn't asked about again.
    public var rejectedAIKeys: Set<String> {
        Set(aiFilings.values.filter(\.rejected).map(\.key))
    }

    /// The Apple Intelligence filing that applies to a key (exact, or a filed whole-word prefix).
    public func aiFilingKey(for key: String) -> String? {
        if aiFilings[key] != nil { return key }
        return aiFilings.keys.filter { key.hasPrefix($0 + " ") && ($0.split(separator: " ").count >= 2 || $0.count >= 6) }
            .max { $0.count < $1.count }
    }

    // MARK: Import

    /// Saves files from the import preview: creates the batch and transactions, replaces pending
    /// charges, matches merchants and pairs transfers.
    public mutating func commitImport(_ items: [ImportCommitItem], importedAt: Date = Date()) -> (delta: LedgerDelta, batches: [ImportBatch]) {
        var delta = LedgerDelta()
        var created: [ImportBatch] = []
        var newIDs: [UUID] = []
        for item in items {
            let plan = item.plan
            guard let account = self.account(plan.accountID), let profile = item.analysis.profile else { continue }
            var counts = ImportCounts()
            counts.totalRows = item.analysis.rows.count + item.analysis.issues.count
            counts.errors = item.analysis.issues.count
            counts.blank = item.analysis.blankLines
            let batch = ImportBatch(fileName: item.analysis.fileName, fileHash: item.analysis.fileHash,
                                    accountID: account.id, profileID: profile.id, importedAt: importedAt,
                                    counts: counts, firstDate: plan.firstDate, lastDate: plan.lastDate)
            var batchCounts = counts
            for planned in plan.rows {
                let row = planned.row
                switch planned.disposition {
                case .duplicate:
                    batchCounts.duplicates += 1
                    continue
                case .possibleDuplicate:
                    if !item.forcedLines.contains(row.line) {
                        batchCounts.heldDuplicates += 1
                        continue
                    }
                    batchCounts.forcedDuplicates += 1
                case .new:
                    batchCounts.imported += 1
                case .replacesPending:
                    batchCounts.replacedPending += 1
                }
                var transaction = LedgerTransaction(
                    accountID: account.id, batchID: batch.id, sourceLine: row.line, date: row.date,
                    postedDate: row.postedDate, amount: row.amount, currency: account.currency,
                    rawDescription: row.description, bankMerchant: row.bankMerchant, bankCategory: row.bankCategory,
                    checkNumber: row.checkNumber, status: row.status, fingerprint: row.fingerprint,
                    occurrence: row.occurrence)
                transaction.cardIdentifier = row.cardIdentifier
                transaction.inheritedAssignment = defaultAssignment(accountID: account.id, cardIdentifier: row.cardIdentifier)
                if case .replacesPending(let pendingID) = planned.disposition, var pending = transactions[pendingID] {
                    transaction.spendingAssignment = pending.spendingAssignment
                    if pending.cardIdentifier != nil || transaction.cardIdentifier == nil {
                        transaction.inheritedAssignment = pending.inheritedAssignment ?? transaction.inheritedAssignment
                    }
                    transaction.cardIdentifier = transaction.cardIdentifier ?? pending.cardIdentifier
                    pending.supersededBy = transaction.id
                    transactions[pendingID] = pending
                    delta.change(.transaction, pendingID)
                    if pending.review == .confirmed {
                        transaction.kind = pending.kind
                        transaction.categoryID = pending.categoryID
                        transaction.merchantID = pending.merchantID
                        transaction.method = pending.method
                        transaction.evidence = pending.evidence
                        transaction.review = .confirmed
                        transaction.note = pending.note
                    }
                    if let partnerID = pending.transferPairID { unpair(partnerID, delta: &delta) }
                }
                transactions[transaction.id] = transaction
                delta.change(.transaction, transaction.id)
                newIDs.append(transaction.id)
                if settings.keepSourceText {
                    delta.sourceLines.append(SourceLine(batchID: batch.id, line: row.line, text: row.rawText))
                }
            }
            if settings.keepSourceText {
                for issue in item.analysis.issues {
                    delta.sourceLines.append(SourceLine(batchID: batch.id, line: issue.line, text: issue.rawText))
                }
            }
            var saved = batch
            saved.counts = batchCounts
            batches.append(saved)
            delta.change(.batch, saved.id)
            created.append(saved)
            // Remember the layout on the account so the next file is recognized.
            if let index = accounts.firstIndex(where: { $0.id == account.id }), accounts[index].profileID != profile.id {
                accounts[index].profileID = profile.id
                delta.change(.account, account.id)
            }
        }
        delta.merge(rematch(ids: Set(newIDs)))
        return (delta, created)
    }

    /// Removes everything one import added and brings back any pending charges it replaced.
    public mutating func undoImport(_ batchID: UUID) -> LedgerDelta {
        var delta = LedgerDelta()
        let removed = transactions.values.filter { $0.batchID == batchID }
        let removedIDs = Set(removed.map(\.id))
        for transaction in removed {
            if let partnerID = transaction.transferPairID, !removedIDs.contains(partnerID) {
                unpair(partnerID, delta: &delta)
            }
            transactions[transaction.id] = nil
            delta.delete(.transaction, transaction.id)
        }
        var restored: Set<UUID> = []
        for (id, transaction) in transactions where transaction.supersededBy.map({ removedIDs.contains($0) }) == true {
            var copy = transaction
            copy.supersededBy = nil
            transactions[id] = copy
            delta.change(.transaction, id)
            restored.insert(id)
        }
        batches.removeAll { $0.id == batchID }
        delta.delete(.batch, batchID)
        delta.deletedSourceBatches.append(batchID)
        // Undo history that mentions removed transactions can no longer be applied cleanly.
        let stale = changes.filter { change in change.before.contains { removedIDs.contains($0.id) } }
        for change in stale { delta.delete(.change, change.id) }
        changes.removeAll { change in change.before.contains { removedIDs.contains($0.id) } }
        if !restored.isEmpty { delta.merge(pairTransfers()) }
        return delta
    }

    // MARK: Matching

    /// Re-runs matching for the given transactions (or all), never touching ones you confirmed.
    @discardableResult
    public mutating func rematch(ids: Set<UUID>? = nil) -> LedgerDelta {
        var delta = LedgerDelta()
        let matcher = Matcher(ledger: self)
        var createdMerchants: [String: UUID] = [:]
        let targets = ids.map { Array($0) } ?? Array(transactions.keys)
        for id in targets.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var transaction = transactions[id], transaction.isActive, transaction.review != .confirmed else { continue }
            let before = transaction
            let result = matcher.match(transaction)
            var merchantID = result.merchantID
            if merchantID == nil, let name = result.newMerchantName {
                let lower = name.lowercased()
                if let existing = createdMerchants[lower] ?? merchant(named: name)?.id {
                    merchantID = existing
                } else {
                    let newMerchant = Merchant(name: name)
                    merchants[newMerchant.id] = newMerchant
                    delta.change(.merchant, newMerchant.id)
                    createdMerchants[lower] = newMerchant.id
                    merchantID = newMerchant.id
                }
            }
            let keepAISuggestion = result.review == .unresolved && transaction.suggestion?.source == .ai
            if transaction.method == .transferPair, result.review == .unresolved, transaction.transferPairID != nil {
                // Still paired with its other half; pairing below re-checks it.
                continue
            }
            transaction.kind = result.kind
            transaction.categoryID = result.categoryID
            transaction.merchantID = merchantID
            transaction.method = keepAISuggestion ? .ai : result.method
            transaction.evidence = keepAISuggestion ? transaction.evidence : result.evidence
            transaction.review = keepAISuggestion ? .suggested : result.review
            if !keepAISuggestion { transaction.suggestion = result.suggestion }
            if transaction != before {
                transactions[id] = transaction
                delta.change(.transaction, id)
            }
        }
        delta.merge(pairTransfers())
        return delta
    }

    /// Words that suggest money moving between your own accounts.
    static let transferWords: [String] = ["PAYMENT", "PYMT", "PMT", "TRANSFER", "XFER", "AUTOPAY", "AUTO PAY", "EPAY",
                                          "THANK YOU", "ZELLE", "ACH", "DEPOSIT", "WITHDRAWAL", "ONLINE BANKING"]

    static func looksLikeTransfer(_ transaction: LedgerTransaction) -> Bool {
        if transaction.kind == .transfer { return true }
        let text = MerchantText.normalize(transaction.rawDescription)
        return transferWords.contains { text.contains($0) }
    }

    /// Pairs the two sides of transfers and card payments between your accounts: opposite amounts,
    /// different accounts, at most 5 days apart, with transfer wording on at least one side, and
    /// only when the match is unique. Paired transactions count as transfers, never as spending
    /// or income.
    @discardableResult
    public mutating func pairTransfers() -> LedgerDelta {
        var delta = LedgerDelta()
        // Break pairs that no longer hold.
        for (id, transaction) in transactions {
            guard let partnerID = transaction.transferPairID else { continue }
            let partner = transactions[partnerID]
            let valid = transaction.isActive && transaction.kind == .transfer && partner?.isActive == true
                && partner?.kind == .transfer && partner?.transferPairID == id
            if !valid {
                var copy = transaction
                copy.transferPairID = nil
                if copy.method == .transferPair, copy.review != .confirmed {
                    copy.kind = .unknown
                    copy.method = .none
                    copy.review = .unresolved
                    copy.evidence = "Its matching transfer was removed."
                }
                transactions[id] = copy
                delta.change(.transaction, id)
            }
        }
        let candidates = transactions.values.filter { transaction in
            transaction.isActive && transaction.transferPairID == nil && transaction.amount != 0
                && (transaction.kind == .transfer || (transaction.kind == .unknown && transaction.review != .confirmed))
        }
        let inflowsByAmount = Dictionary(grouping: candidates.filter { $0.amount > 0 }, by: \.amount)
        let outflows = candidates.filter { $0.amount < 0 }
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        var used: Set<UUID> = []
        for outflow in outflows {
            let options = (inflowsByAmount[-outflow.amount] ?? []).filter { inflow in
                !used.contains(inflow.id) && inflow.accountID != outflow.accountID
                    && abs(inflow.date.days(until: outflow.date)) <= 5
                    && (Ledger.looksLikeTransfer(outflow) || Ledger.looksLikeTransfer(inflow))
            }
            guard !options.isEmpty else { continue }
            let nearest = options.map { abs($0.date.days(until: outflow.date)) }.min() ?? 0
            let closest = options.filter { abs($0.date.days(until: outflow.date)) == nearest }
            guard closest.count == 1, let inflow = closest.first else { continue }
            used.insert(inflow.id)
            used.insert(outflow.id)
            let fromName = account(outflow.accountID)?.name ?? "another account"
            let toName = account(inflow.accountID)?.name ?? "another account"
            let sides: [(LedgerTransaction, String, LocalDate)] = [(outflow, toName, inflow.date), (inflow, fromName, outflow.date)]
            for (side, otherName, otherDate) in sides {
                var copy = side
                copy.transferPairID = side.id == outflow.id ? inflow.id : outflow.id
                if copy.kind != .transfer || copy.method == .none {
                    copy.kind = .transfer
                    copy.categoryID = nil
                    copy.method = .transferPair
                    copy.review = .automatic
                    copy.suggestion = nil
                    copy.evidence = "Matches \(Money.format(-side.amount)) in \(otherName) on \(DateText.short(otherDate))."
                }
                transactions[copy.id] = copy
                delta.change(.transaction, copy.id)
            }
        }
        return delta
    }

    /// Clears a transaction's transfer pairing (its other half was removed or reclassified).
    mutating func unpair(_ id: UUID, delta: inout LedgerDelta) {
        guard var transaction = transactions[id] else { return }
        transaction.transferPairID = nil
        if transaction.method == .transferPair, transaction.review != .confirmed {
            transaction.kind = .unknown
            transaction.method = .none
            transaction.review = .unresolved
            transaction.evidence = "Its matching transfer was removed."
        }
        transactions[id] = transaction
        delta.change(.transaction, id)
    }

    // MARK: Your corrections

    /// Sets merchant, kind and category for transactions. With `remember`, EchoLedger also
    /// learns this merchant's bank text and default category, and applies it to similar
    /// transactions that aren't confirmed yet. Undoable.
    public mutating func classify(_ ids: [UUID], merchantName: String?, kind: TransactionKind, categoryID: UUID?,
                                  remember: Bool, label: String, now: Date = Date()) -> LedgerDelta {
        var delta = LedgerDelta()
        var before: [UUID: LedgerTransaction] = [:]
        var merchantsBefore: [UUID: Merchant] = [:]
        var createdMerchantIDs: [UUID] = []
        let cleanName = merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
        var merchantID: UUID?
        if !cleanName.isEmpty {
            if let existing = merchant(named: cleanName) {
                merchantID = existing.id
            } else {
                // A name you typed yourself is kept; a name EchoLedger only tidied from bank text can be improved later.
                let mechanical = ids.compactMap { transactions[$0] }.contains { MerchantText($0.rawDescription).displayName == cleanName }
                let created = Merchant(name: cleanName, nameLocked: !mechanical)
                merchants[created.id] = created
                createdMerchantIDs.append(created.id)
                delta.change(.merchant, created.id)
                merchantID = created.id
            }
        }
        let category = kind == .transfer || kind == .unknown ? nil : categoryID
        var learnedKeys: [String] = []
        var correctedAIKeys: Set<String> = []
        for id in ids {
            guard var transaction = transactions[id] else { continue }
            before[id] = transaction
            if transaction.method == .ai, transaction.review == .automatic,
               transaction.kind != kind || transaction.categoryID != category
                || (merchantID != nil && transaction.merchantID != merchantID),
               let filingKey = aiFilingKey(for: MerchantText(transaction.rawDescription).key) {
                correctedAIKeys.insert(filingKey)
            }
            if let partnerID = transaction.transferPairID, kind != .transfer {
                if before[partnerID] == nil, let partner = transactions[partnerID] { before[partnerID] = partner }
                transaction.transferPairID = nil
                unpair(partnerID, delta: &delta)
            }
            transaction.kind = kind
            transaction.categoryID = category
            transaction.merchantID = merchantID ?? (cleanName.isEmpty ? transaction.merchantID : nil)
            transaction.method = .manual
            transaction.review = kind == .unknown ? .unresolved : .confirmed
            transaction.suggestion = nil
            transaction.evidence = "Set by you."
            transactions[id] = transaction
            delta.change(.transaction, id)
            let key = MerchantText(transaction.rawDescription).key
            if !key.isEmpty, !learnedKeys.contains(key) { learnedKeys.append(key) }
        }
        if remember, let merchantID, var target = merchants[merchantID] {
            if merchantsBefore[merchantID] == nil, !createdMerchantIDs.contains(merchantID) { merchantsBefore[merchantID] = target }
            // A key belongs to one merchant only.
            for key in learnedKeys {
                for (otherID, other) in merchants where otherID != merchantID && other.keys.contains(key) {
                    if merchantsBefore[otherID] == nil { merchantsBefore[otherID] = other }
                    var updated = other
                    updated.keys.removeAll { $0 == key }
                    merchants[otherID] = updated
                    delta.change(.merchant, otherID)
                }
                if !target.keys.contains(key) { target.keys.append(key) }
            }
            if kind == .transfer {
                target.kind = .transfer
                target.categoryID = nil
            } else if kind != .unknown {
                target.kind = nil
                target.categoryID = category
            }
            merchants[merchantID] = target
            delta.change(.merchant, merchantID)
            // Apply what was learned to other open transactions.
            let others = transactions.values.filter { $0.isActive && $0.review != .confirmed && !ids.contains($0.id) }
            let affected = others.filter { other in
                let key = MerchantText(other.rawDescription).key
                return learnedKeys.contains { key == $0 || key.hasPrefix($0 + " ") }
            }
            for other in affected where before[other.id] == nil { before[other.id] = other }
            delta.merge(rematch(ids: Set(affected.map(\.id))))
        } else if let merchantID, !createdMerchantIDs.contains(merchantID), merchantsBefore[merchantID] == nil,
                  let current = merchants[merchantID] {
            merchantsBefore[merchantID] = current
        }
        // You corrected something Apple Intelligence filed: stop using that filing, and re-check
        // the other transactions it filed the same way.
        var aiFilingsBefore: [AIFiling] = []
        if !correctedAIKeys.isEmpty {
            for key in correctedAIKeys.sorted() {
                guard var filing = aiFilings[key], !filing.rejected else { continue }
                aiFilingsBefore.append(filing)
                filing.rejected = true
                aiFilings[key] = filing
                delta.change(.aiFiling, key)
            }
            let others = transactions.values.filter { other in
                other.isActive && other.method == .ai && other.review == .automatic && !ids.contains(other.id)
                    && correctedAIKeys.contains { key in
                        let otherKey = MerchantText(other.rawDescription).key
                        return otherKey == key || otherKey.hasPrefix(key + " ")
                    }
            }
            for other in others where before[other.id] == nil { before[other.id] = other }
            delta.merge(rematch(ids: Set(others.map(\.id))))
        }
        delta.merge(pairTransfers())
        let change = ChangeSet(date: now, label: label, before: Array(before.values),
                               merchantsBefore: Array(merchantsBefore.values), createdMerchantIDs: createdMerchantIDs,
                               aiFilingsBefore: aiFilingsBefore)
        delta.merge(record(change))
        return delta
    }

    /// One Apple Intelligence decision about a group of transactions that share bank text.
    public struct AIFilingRequest: Sendable {
        public var ids: [UUID]
        public var key: String
        public var merchantName: String?
        public var kind: TransactionKind
        public var categoryID: UUID?
        public var reason: String

        public init(ids: [UUID], key: String, merchantName: String?, kind: TransactionKind, categoryID: UUID?, reason: String) {
            self.ids = ids
            self.key = key
            self.merchantName = merchantName
            self.kind = kind
            self.categoryID = categoryID
            self.reason = reason
        }
    }

    /// Files transactions the way Apple Intelligence decided (already checked by
    /// `SuggestionCheck`), remembers the decision for the same bank text in later imports, and
    /// records it as one undoable change. Transactions you've confirmed are never touched, and
    /// bank text you corrected before is skipped.
    public mutating func fileByAI(_ requests: [AIFilingRequest], now: Date = Date()) -> LedgerDelta {
        var delta = LedgerDelta()
        var before: [UUID: LedgerTransaction] = [:]
        var createdKeys: [String] = []
        var filingsBefore: [AIFiling] = []
        var keys: Set<String> = []
        let merchantsBeforeIDs = Set(merchants.keys)
        for request in requests {
            let key = request.key
            guard !key.isEmpty, aiFilings[key]?.rejected != true else { continue }
            let categoryID = request.kind == .transfer ? nil : request.categoryID
            if let existing = aiFilings[key] { filingsBefore.append(existing) } else { createdKeys.append(key) }
            aiFilings[key] = AIFiling(key: key, merchantName: request.merchantName, categoryID: categoryID,
                                      kind: request.kind, reason: request.reason, date: now)
            delta.change(.aiFiling, key)
            keys.insert(key)
        }
        guard !keys.isEmpty else { return delta }
        // Every open transaction with this bank text (not only the ones asked about) gets filed.
        let targets = transactions.values.filter { transaction in
            guard transaction.needsReview else { return false }
            let key = MerchantText(transaction.rawDescription).key
            return keys.contains { key == $0 || key.hasPrefix($0 + " ") }
        }
        for transaction in targets { before[transaction.id] = transaction }
        delta.merge(rematch(ids: Set(targets.map(\.id))))
        let createdMerchants = Array(Set(merchants.keys).subtracting(merchantsBeforeIDs))
        let filed = targets.filter { transactions[$0.id]?.method == .ai }.count
        let change = ChangeSet(date: now, label: "Filed by Apple Intelligence (\(filed))", before: Array(before.values),
                               createdMerchantIDs: createdMerchants, createdAIFilingKeys: createdKeys,
                               aiFilingsBefore: filingsBefore)
        delta.merge(record(change))
        return delta
    }

    /// Keeps what Apple Intelligence filed for these transactions and learns it, so the same bank
    /// text is filed this way from now on. One undoable change per merchant and category.
    public mutating func confirmAIFiled(_ ids: [UUID]) -> LedgerDelta {
        var delta = LedgerDelta()
        let filed = ids.compactMap { transactions[$0] }.filter { $0.method == .ai && $0.review == .automatic }
        let groups = Dictionary(grouping: filed) { transaction in
            "\(transaction.merchantID?.uuidString ?? "")|\(transaction.kind.rawValue)|\(transaction.categoryID?.uuidString ?? "")"
        }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            delta.merge(classify(group.map(\.id), merchantName: merchant(first.merchantID)?.name, kind: first.kind,
                                 categoryID: first.categoryID, remember: true, label: "Keep Apple Intelligence filing"))
        }
        return delta
    }

    /// Gives merchants tidier names chosen by Apple Intelligence (already checked by
    /// `MerchantNames.acceptRename`). Names you set yourself, and names another merchant already
    /// uses, are left alone. Undoable.
    public mutating func tidyMerchantNames(_ renames: [(id: UUID, name: String)]) -> LedgerDelta {
        var delta = LedgerDelta()
        var merchantsBefore: [Merchant] = []
        for rename in renames {
            guard var merchant = merchants[rename.id], !merchant.nameLocked, merchant.name != rename.name,
                  self.merchant(named: rename.name) == nil else { continue }
            merchantsBefore.append(merchant)
            merchant.name = rename.name
            merchants[rename.id] = merchant
            delta.change(.merchant, rename.id)
        }
        guard !merchantsBefore.isEmpty else { return delta }
        delta.merge(record(ChangeSet(label: "Tidy merchant names (\(merchantsBefore.count))", before: [],
                                     merchantsBefore: merchantsBefore)))
        return delta
    }

    /// Accepts the suggestions on these transactions as they are.
    public mutating func approveSuggestions(_ ids: [UUID], remember: Bool) -> LedgerDelta {
        var delta = LedgerDelta()
        let groups = Dictionary(grouping: ids.compactMap { transactions[$0] }.filter { $0.suggestion != nil }) { transaction in
            let suggestion = transaction.suggestion
            return "\(suggestion?.merchantName ?? "")|\(suggestion?.kind.rawValue ?? "")|\(suggestion?.categoryID?.uuidString ?? "")"
        }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let suggestion = group.first?.suggestion else { continue }
            delta.merge(classify(group.map(\.id), merchantName: suggestion.merchantName, kind: suggestion.kind,
                                 categoryID: suggestion.categoryID, remember: remember, label: "Approve suggestion"))
        }
        return delta
    }

    /// Stores an Apple Intelligence (or other) suggestion on transactions still needing review.
    public mutating func setSuggestion(_ suggestion: Suggestion, evidence: String, for ids: [UUID]) -> LedgerDelta {
        var delta = LedgerDelta()
        for id in ids {
            guard var transaction = transactions[id], transaction.needsReview else { continue }
            transaction.suggestion = suggestion
            transaction.method = suggestion.source
            transaction.review = .suggested
            transaction.evidence = evidence
            transactions[id] = transaction
            delta.change(.transaction, id)
        }
        return delta
    }

    public mutating func setNote(_ note: String, for id: UUID) -> LedgerDelta {
        var delta = LedgerDelta()
        guard var transaction = transactions[id] else { return delta }
        transaction.note = note
        transactions[id] = transaction
        delta.change(.transaction, id)
        return delta
    }

    /// Removes transactions from your records without deleting them (for example a pending
    /// charge that never posted). Undoable.
    public mutating func setVoided(_ voided: Bool, ids: [UUID], label: String) -> LedgerDelta {
        var delta = LedgerDelta()
        var before: [LedgerTransaction] = []
        for id in ids {
            guard var transaction = transactions[id], transaction.voided != voided else { continue }
            before.append(transaction)
            transaction.voided = voided
            transactions[id] = transaction
            delta.change(.transaction, id)
            if voided, let partnerID = transaction.transferPairID {
                if let partner = transactions[partnerID] { before.append(partner) }
                unpair(partnerID, delta: &delta)
            }
        }
        guard !before.isEmpty else { return delta }
        delta.merge(pairTransfers())
        delta.merge(record(ChangeSet(label: label, before: before)))
        return delta
    }

    /// Puts transactions back to automatic matching (forgetting your manual setting). Undoable.
    public mutating func resetToAutomatic(_ ids: [UUID]) -> LedgerDelta {
        var delta = LedgerDelta()
        var before: [LedgerTransaction] = []
        for id in ids {
            guard var transaction = transactions[id] else { continue }
            before.append(transaction)
            transaction.review = .unresolved
            transaction.method = .none
            transaction.suggestion = nil
            transactions[id] = transaction
            delta.change(.transaction, id)
        }
        delta.merge(rematch(ids: Set(ids)))
        delta.merge(record(ChangeSet(label: "Reset to automatic", before: before)))
        return delta
    }

    mutating func record(_ change: ChangeSet) -> LedgerDelta {
        var delta = LedgerDelta()
        changes.append(change)
        delta.change(.change, change.id)
        while changes.count > Ledger.maximumUndoSteps {
            let dropped = changes.removeFirst()
            delta.delete(.change, dropped.id)
        }
        return delta
    }

    public var undoLabel: String? { changes.last?.label }

    /// Reverses your most recent correction.
    public mutating func undoLastChange() -> LedgerDelta? {
        guard let change = changes.popLast() else { return nil }
        var delta = LedgerDelta()
        delta.delete(.change, change.id)
        for transaction in change.before where transactions[transaction.id] != nil {
            transactions[transaction.id] = transaction
            delta.change(.transaction, transaction.id)
        }
        for merchant in change.merchantsBefore {
            merchants[merchant.id] = merchant
            delta.change(.merchant, merchant.id)
        }
        let referenced = Set(transactions.values.compactMap(\.merchantID))
        for id in change.createdMerchantIDs where !referenced.contains(id) {
            merchants[id] = nil
            delta.delete(.merchant, id)
        }
        for key in change.createdAIFilingKeys {
            aiFilings[key] = nil
            delta.delete(.aiFiling, key)
        }
        for filing in change.aiFilingsBefore {
            aiFilings[filing.key] = filing
            delta.change(.aiFiling, filing.key)
        }
        for id in change.createdRuleIDs {
            rules.removeAll { $0.id == id }
            settings.ruleOrder.removeAll { $0 == id }
            delta.delete(.rule, id)
            delta.change(.settings, "settings")
        }
        delta.merge(pairTransfers())
        return delta
    }

    // MARK: Rules

    /// Adds a rule at the top (or bottom) of your list and applies it to open transactions.
    public mutating func addRule(_ rule: Rule, atTop: Bool = true, applyNow: Bool = true) -> LedgerDelta {
        var delta = LedgerDelta()
        rules.append(rule)
        var order = orderedRules.map(\.id).filter { $0 != rule.id }
        if atTop { order.insert(rule.id, at: 0) } else { order.append(rule.id) }
        settings.ruleOrder = order
        delta.change(.rule, rule.id)
        delta.change(.settings, "settings")
        if applyNow { delta.merge(rematch()) }
        return delta
    }

    public mutating func updateRule(_ rule: Rule, applyNow: Bool = true) -> LedgerDelta {
        var delta = LedgerDelta()
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return delta }
        rules[index] = rule
        delta.change(.rule, rule.id)
        if applyNow { delta.merge(rematch()) }
        return delta
    }

    public mutating func deleteRule(_ id: UUID, applyNow: Bool = true) -> LedgerDelta {
        var delta = LedgerDelta()
        rules.removeAll { $0.id == id }
        settings.ruleOrder.removeAll { $0 == id }
        delta.delete(.rule, id)
        delta.change(.settings, "settings")
        if applyNow { delta.merge(rematch()) }
        return delta
    }

    public mutating func setRuleOrder(_ ids: [UUID], applyNow: Bool = true) -> LedgerDelta {
        var delta = LedgerDelta()
        settings.ruleOrder = ids
        delta.change(.settings, "settings")
        if applyNow { delta.merge(rematch()) }
        return delta
    }

    public mutating func setBuiltInRule(_ id: String, enabled: Bool) -> LedgerDelta {
        var delta = LedgerDelta()
        settings.disabledBuiltInRules.removeAll { $0 == id }
        if !enabled { settings.disabledBuiltInRules.append(id) }
        delta.change(.settings, "settings")
        delta.merge(rematch())
        return delta
    }

    // MARK: Merchants

    public mutating func renameMerchant(_ id: UUID, to name: String) -> LedgerDelta {
        var delta = LedgerDelta()
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, var merchant = merchants[id] else { return delta }
        if let other = self.merchant(named: clean), other.id != id {
            return mergeMerchants(id, into: other.id)
        }
        merchant.name = clean
        merchant.nameLocked = true
        merchants[id] = merchant
        delta.change(.merchant, id)
        return delta
    }

    /// Moves every transaction and learned key from one merchant to another.
    public mutating func mergeMerchants(_ sourceID: UUID, into targetID: UUID) -> LedgerDelta {
        var delta = LedgerDelta()
        guard sourceID != targetID, let source = merchants[sourceID], var target = merchants[targetID] else { return delta }
        for key in source.keys where !target.keys.contains(key) { target.keys.append(key) }
        if target.categoryID == nil, target.kind == nil {
            target.categoryID = source.categoryID
            target.kind = source.kind
        }
        merchants[targetID] = target
        merchants[sourceID] = nil
        delta.change(.merchant, targetID)
        delta.delete(.merchant, sourceID)
        for (id, transaction) in transactions where transaction.merchantID == sourceID {
            var copy = transaction
            copy.merchantID = targetID
            transactions[id] = copy
            delta.change(.transaction, id)
        }
        return delta
    }

    public mutating func updateMerchant(_ merchant: Merchant, applyNow: Bool = true) -> LedgerDelta {
        var delta = LedgerDelta()
        merchants[merchant.id] = merchant
        delta.change(.merchant, merchant.id)
        if applyNow { delta.merge(rematch()) }
        return delta
    }

    /// Deletes merchants no transaction uses any more and that hold nothing you taught.
    public mutating func pruneUnusedMerchants() -> LedgerDelta {
        var delta = LedgerDelta()
        let used = Set(transactions.values.compactMap(\.merchantID))
        for (id, merchant) in merchants where !used.contains(id) && merchant.keys.isEmpty
            && merchant.categoryID == nil && merchant.kind == nil {
            merchants[id] = nil
            delta.delete(.merchant, id)
        }
        return delta
    }

    // MARK: People, accounts, categories, budgets, layouts

    public mutating func upsertPerson(_ person: Person) -> LedgerDelta {
        var delta = LedgerDelta()
        if let index = people.firstIndex(where: { $0.id == person.id }) { people[index] = person } else { people.append(person) }
        delta.change(.person, person.id)
        delta.merge(rematch())
        return delta
    }

    public mutating func deletePerson(_ id: UUID) -> LedgerDelta {
        var delta = LedgerDelta()
        people.removeAll { $0.id == id }
        delta.delete(.person, id)
        for index in accounts.indices {
            var account = accounts[index]
            if account.userIDs == [id] {
                account.defaultAssignment = .unassigned
            } else if account.userIDs.contains(id) {
                account.userIDs.removeAll { $0 == id }
            }
            for key in Array(account.cardAssignments.keys) where account.cardAssignments[key] == .person(id) {
                account.cardAssignments[key] = .unassigned
            }
            if account != accounts[index] { accounts[index] = account; delta.change(.account, account.id) }
        }
        for key in Array(transactions.keys) {
            guard var transaction = transactions[key] else { continue }
            var changed = false
            if transaction.spendingAssignment == .person(id) { transaction.spendingAssignment = .unassigned; changed = true }
            if transaction.inheritedAssignment == .person(id) { transaction.inheritedAssignment = .unassigned; changed = true }
            if changed { transactions[key] = transaction; delta.change(.transaction, key) }
        }
        delta.merge(rematch())
        return delta
    }

    public mutating func upsertAccount(_ account: Account) -> LedgerDelta {
        var delta = LedgerDelta()
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            let old = accounts[index]
            if old.defaultAssignment != account.defaultAssignment || old.cardAssignments != account.cardAssignments {
                // Freeze legacy defaults before changing them. Past reports change only via the explicit action.
                for id in Array(transactions.keys) {
                    guard var transaction = transactions[id], transaction.accountID == account.id,
                          transaction.inheritedAssignment == nil else { continue }
                    transaction.inheritedAssignment = defaultAssignment(accountID: account.id, cardIdentifier: transaction.cardIdentifier)
                    transactions[id] = transaction
                    delta.change(.transaction, id)
                }
            }
            accounts[index] = account
        } else { accounts.append(account) }
        delta.change(.account, account.id)
        return delta
    }

    /// Records that report notes aren't problems: an account is up to date, its history starts
    /// on a date, it's rarely used, or a note was seen. Undo with `showAllReportNotes()` or the
    /// account's settings.
    public mutating func acknowledge(_ acknowledgements: [DataNote.Acknowledgement]) -> LedgerDelta {
        var delta = LedgerDelta()
        for acknowledgement in acknowledgements {
            switch acknowledgement {
            case .upToDate(let id, let through):
                guard let index = accounts.firstIndex(where: { $0.id == id }) else { continue }
                accounts[index].upToDateThrough = max(through, accounts[index].upToDateThrough ?? through)
                delta.change(.account, id)
            case .historyStart(let id, let date):
                guard let index = accounts.firstIndex(where: { $0.id == id }) else { continue }
                accounts[index].historyStartsOn = date
                delta.change(.account, id)
            case .rarelyUsed(let id):
                guard let index = accounts.firstIndex(where: { $0.id == id }) else { continue }
                accounts[index].rarelyUsed = true
                delta.change(.account, id)
            case .dismiss(let key):
                guard !settings.dismissedNotes.contains(key) else { continue }
                settings.dismissedNotes.append(key)
                delta.change(.settings, "settings")
            }
        }
        return delta
    }

    /// Brings back every report note you marked as not a problem.
    public mutating func showAllReportNotes() -> LedgerDelta {
        var delta = LedgerDelta()
        for index in accounts.indices
        where accounts[index].rarelyUsed || accounts[index].upToDateThrough != nil || accounts[index].historyStartsOn != nil {
            accounts[index].rarelyUsed = false
            accounts[index].upToDateThrough = nil
            accounts[index].historyStartsOn = nil
            delta.change(.account, accounts[index].id)
        }
        if !settings.dismissedNotes.isEmpty {
            settings.dismissedNotes = []
            delta.change(.settings, "settings")
        }
        return delta
    }

    /// The number of report notes currently marked as not a problem.
    public var acknowledgedNoteCount: Int {
        accounts.filter { $0.rarelyUsed || $0.upToDateThrough != nil || $0.historyStartsOn != nil }.count + settings.dismissedNotes.count
    }

    /// Deletes an account only when it has no transactions; otherwise archive it.
    public mutating func deleteAccount(_ id: UUID) -> LedgerDelta? {
        guard !transactions.values.contains(where: { $0.accountID == id }) else { return nil }
        var delta = LedgerDelta()
        accounts.removeAll { $0.id == id }
        delta.delete(.account, id)
        return delta
    }

    public mutating func upsertCategory(_ category: LedgerCategory) -> LedgerDelta {
        var delta = LedgerDelta()
        if let index = categories.firstIndex(where: { $0.id == category.id }) { categories[index] = category } else { categories.append(category) }
        delta.change(.category, category.id)
        return delta
    }

    /// Deletes a category, moving its transactions, rules, merchants and budget to `replacement`
    /// (or back to Needs review when nil).
    public mutating func deleteCategory(_ id: UUID, replacement: UUID?) -> LedgerDelta {
        var delta = LedgerDelta()
        let replacementCategory = category(replacement)
        for (transactionID, transaction) in transactions where transaction.categoryID == id {
            var copy = transaction
            copy.categoryID = replacementCategory?.id
            if replacementCategory == nil {
                copy.kind = .unknown
                copy.review = .unresolved
                copy.method = .none
            } else if let replacementCategory {
                copy.kind = replacementCategory.group == .income ? .income : .expense
            }
            transactions[transactionID] = copy
            delta.change(.transaction, transactionID)
        }
        for index in rules.indices where rules[index].categoryID == id {
            rules[index].categoryID = replacementCategory?.id
            delta.change(.rule, rules[index].id)
        }
        for (merchantID, merchant) in merchants where merchant.categoryID == id {
            var copy = merchant
            copy.categoryID = replacementCategory?.id
            merchants[merchantID] = copy
            delta.change(.merchant, merchantID)
        }
        for budget in budgets where budget.categoryID == id {
            delta.delete(.budget, budget.id)
        }
        budgets.removeAll { $0.categoryID == id }
        categories.removeAll { $0.id == id }
        delta.delete(.category, id)
        delta.merge(rematch())
        return delta
    }

    public mutating func setBudget(categoryID: UUID, monthlyAmount: Cents?) -> LedgerDelta {
        var delta = LedgerDelta()
        if let index = budgets.firstIndex(where: { $0.categoryID == categoryID }) {
            if let monthlyAmount, monthlyAmount > 0 {
                budgets[index].monthlyAmount = monthlyAmount
                delta.change(.budget, budgets[index].id)
            } else {
                delta.delete(.budget, budgets[index].id)
                budgets.remove(at: index)
            }
        } else if let monthlyAmount, monthlyAmount > 0 {
            let budget = Budget(categoryID: categoryID, monthlyAmount: monthlyAmount)
            budgets.append(budget)
            delta.change(.budget, budget.id)
        }
        return delta
    }

    public mutating func upsertProfile(_ profile: ImportProfile) -> LedgerDelta {
        var delta = LedgerDelta()
        var saved = profile
        saved.isBuiltIn = false
        if let index = profiles.firstIndex(where: { $0.id == saved.id }) { profiles[index] = saved } else { profiles.insert(saved, at: 0) }
        delta.change(.profile, saved.id)
        return delta
    }

    public mutating func updateSettings(_ change: (inout LedgerSettings) -> Void) -> LedgerDelta {
        var delta = LedgerDelta()
        change(&settings)
        delta.change(.settings, "settings")
        return delta
    }
}
