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
            if let personID { return .person(personID) }
            return isUnassigned ? .unassigned : .shared
        }
        set {
            if case .person(let id) = newValue { personID = id } else { personID = nil }
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
