import Foundation

/// A reporting assignment, independent of legal account ownership.
public enum SpendingAssignment: Codable, Hashable, Sendable {
    case person(UUID)
    case shared
    case unassigned
}

extension Account {
    public var defaultAssignment: SpendingAssignment {
        get {
            if userIDs.count == 1, let only = userIDs.first { return .person(only) }
            // No users: a plain household account, or one not decided yet. Several users: shared.
            if userIDs.isEmpty && isUnassigned { return .unassigned }
            return .shared
        }
        set {
            if case .person(let id) = newValue { userIDs = [id] } else { userIDs = [] }
            isUnassigned = newValue == .unassigned
        }
    }
}

extension Ledger {
    public func assignmentName(_ assignment: SpendingAssignment) -> String {
        switch assignment {
        case .person(let id): return person(id)?.name ?? "Unassigned"
        case .shared: return "Shared household"
        case .unassigned: return "Unassigned"
        }
    }

    public func defaultAssignment(accountID: UUID, cardIdentifier: String? = nil) -> SpendingAssignment {
        guard let account = account(accountID) else { return .unassigned }
        if let cardIdentifier {
            if let assignment = account.cardAssignments[cardIdentifier] { return assignment }
            if let match = account.cardAssignments.first(where: { $0.key.caseInsensitiveCompare(cardIdentifier) == .orderedSame }) { return match.value }
        }
        return account.defaultAssignment
    }

    /// Who an account or card is used by, in words: names, "Household" or "Unassigned".
    public func usersLabel(_ account: Account) -> String {
        let names = account.userIDs.compactMap { person($0)?.name }
        if !names.isEmpty { return names.joined(separator: ", ") }
        return account.isUnassigned ? "Unassigned" : "Household"
    }

    /// A single card's own setting (from its cardholder or card-number label), if you made one.
    private func cardOverride(_ account: Account, _ identifier: String?) -> SpendingAssignment? {
        guard let identifier else { return nil }
        if let exact = account.cardAssignments[identifier] { return exact }
        return account.cardAssignments.first { $0.key.caseInsensitiveCompare(identifier) == .orderedSame }?.value
    }

    /// The people who use the card a transaction was made on. This follows the card, not any
    /// correction made to the single transaction.
    public func cardUsers(for transaction: LedgerTransaction) -> [UUID] {
        guard let account = account(transaction.accountID) else { return [] }
        var ids = account.userIDs
        if let custom = cardOverride(account, transaction.cardIdentifier) {
            if case .person(let id) = custom { ids = [id] } else { ids = [] }
        }
        return ids.filter { person($0) != nil }
    }

    public func cardUserNames(for transaction: LedgerTransaction) -> [String] {
        cardUsers(for: transaction).compactMap { person($0)?.name }
    }

    /// For a card nobody in particular uses: true when it is still undecided (unassigned),
    /// false when it is a plain household card.
    public func cardIsUndecided(for transaction: LedgerTransaction) -> Bool {
        guard let account = account(transaction.accountID) else { return true }
        if let custom = cardOverride(account, transaction.cardIdentifier) { return custom == .unassigned }
        return account.isUnassigned
    }

    public func assignment(for transaction: LedgerTransaction) -> SpendingAssignment {
        let value = transaction.spendingAssignment ?? transaction.inheritedAssignment
            ?? defaultAssignment(accountID: transaction.accountID, cardIdentifier: transaction.cardIdentifier)
        if case .person(let id) = value, person(id) == nil { return .unassigned }
        return value
    }

    /// Assign one or many transactions, preserving classification, amounts and transfer pairs.
    /// nil removes the manual correction and returns to the saved import default.
    public mutating func assignSpending(_ assignment: SpendingAssignment?, ids: [UUID]) -> LedgerDelta {
        var delta = LedgerDelta()
        var before: [LedgerTransaction] = []
        for id in Set(ids) {
            guard var transaction = transactions[id], transaction.spendingAssignment != assignment else { continue }
            before.append(transaction)
            transaction.spendingAssignment = assignment
            transactions[id] = transaction
            delta.change(.transaction, id)
        }
        if !before.isEmpty { delta.merge(record(ChangeSet(label: "Assign household spending", before: before))) }
        return delta
    }

    /// Deliberately reapplies a default to earlier imports without replacing manual corrections.
    public mutating func applySpendingDefault(accountID: UUID, cardIdentifier: String? = nil) -> LedgerDelta {
        var delta = LedgerDelta()
        var before: [LedgerTransaction] = []
        for id in Array(transactions.keys) {
            guard var transaction = transactions[id], transaction.accountID == accountID,
                  cardIdentifier == nil || transaction.cardIdentifier == cardIdentifier,
                  transaction.spendingAssignment == nil else { continue }
            let value = defaultAssignment(accountID: accountID, cardIdentifier: transaction.cardIdentifier)
            guard transaction.inheritedAssignment != value else { continue }
            before.append(transaction)
            transaction.inheritedAssignment = value
            transactions[id] = transaction
            delta.change(.transaction, id)
        }
        if !before.isEmpty { delta.merge(record(ChangeSet(label: "Apply account assignment", before: before))) }
        return delta
    }
}
