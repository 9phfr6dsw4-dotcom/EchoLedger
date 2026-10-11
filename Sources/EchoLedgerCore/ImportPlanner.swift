import Foundation

/// What will happen to one row when you import.
public enum RowDisposition: Sendable, Hashable {
    /// A new transaction.
    case new
    /// Already saved from an earlier file; skipped.
    case duplicate(UUID)
    /// The posted version of a pending charge you already have; replaces it.
    case replacesPending(UUID)
    /// Looks like a transaction you already have but isn't an exact match. Held back unless you
    /// choose to import it.
    case possibleDuplicate(UUID)
}

public struct PlannedRow: Sendable, Hashable, Identifiable {
    public var row: ParsedRow
    public var disposition: RowDisposition
    public var id: Int { row.line }
}

/// The preview for one file and one account. Every line of the file is accounted for.
public struct ImportPlan: Sendable {
    public var analysisID: UUID
    public var accountID: UUID
    public var rows: [PlannedRow]
    public var issues: [RowIssue]
    public var blankLines: Int
    public var skippedLines: Int
    /// The same file (byte for byte) was imported before.
    public var previousImport: ImportBatch?

    public var newRows: [PlannedRow] { rows.filter { $0.disposition == .new } }

    public var newCount: Int { rows.filter { $0.disposition == .new }.count }

    public var duplicateCount: Int {
        rows.filter { if case .duplicate = $0.disposition { return true } else { return false } }.count
    }

    public var replacesPendingCount: Int {
        rows.filter { if case .replacesPending = $0.disposition { return true } else { return false } }.count
    }

    public var possibleDuplicates: [PlannedRow] {
        rows.filter { if case .possibleDuplicate = $0.disposition { return true } else { return false } }
    }

    /// Money in and out of the rows that would be saved (new and replacing pending).
    public var totals: (moneyIn: Cents, moneyOut: Cents) {
        var moneyIn: Cents = 0
        var moneyOut: Cents = 0
        for planned in rows {
            switch planned.disposition {
            case .new, .replacesPending:
                if planned.row.amount > 0 { moneyIn += planned.row.amount } else { moneyOut += planned.row.amount }
            case .duplicate, .possibleDuplicate:
                break
            }
        }
        return (moneyIn, moneyOut)
    }

    public var firstDate: LocalDate? { rows.map(\.row.date).min() }
    public var lastDate: LocalDate? { rows.map(\.row.date).max() }
}

public enum ImportPlanner {
    /// Compares a file's rows with what's already saved for the account.
    ///
    /// - Exact repeats (same date, amount and description, and the same position among identical
    ///   rows in the file) are duplicates. Two identical coffees on one day stay two coffees.
    /// - A posted row replaces a pending charge with the same amount (or up to 30% more, for
    ///   tips) from up to 7 days earlier, when the descriptions are similar and the match is unique.
    /// - A posted row that only resembles a saved one (same amount within 3 days, inside the
    ///   dates this file covers) is held back as a possible duplicate for you to decide.
    public static func plan(_ analysis: FileAnalysis, accountID: UUID, ledger: Ledger) -> ImportPlan {
        let existing = ledger.transactions.values.filter { $0.accountID == accountID && $0.isActive }
        var byKey: [String: LedgerTransaction] = [:]
        for transaction in existing {
            byKey["\(transaction.fingerprint)#\(transaction.occurrence)"] = transaction
        }
        var claimed: Set<UUID> = []
        var dispositions: [Int: RowDisposition] = [:]
        var unmatched: [ParsedRow] = []

        for row in analysis.rows {
            if let match = byKey["\(row.fingerprint)#\(row.occurrence)"] {
                claimed.insert(match.id)
                if match.status == .pending, row.status == .posted {
                    dispositions[row.line] = .replacesPending(match.id)
                } else {
                    dispositions[row.line] = .duplicate(match.id)
                }
            } else {
                unmatched.append(row)
            }
        }

        let first = analysis.firstDate
        let last = analysis.lastDate
        let sortedExisting = existing.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        for row in unmatched {
            let rowKey = MerchantText(row.description).key
            // Posted row replacing a pending charge.
            if row.status == .posted {
                let pending = sortedExisting.filter { candidate in
                    guard candidate.status == .pending, !claimed.contains(candidate.id) else { return false }
                    let days = candidate.date.days(until: row.date)
                    guard days >= -1, days <= 7 else { return false }
                    guard amountsCompatible(pending: candidate.amount, posted: row.amount) else { return false }
                    return KeySimilarity.score(MerchantText(candidate.rawDescription).key, rowKey) >= 60
                }
                if pending.count == 1 {
                    claimed.insert(pending[0].id)
                    dispositions[row.line] = .replacesPending(pending[0].id)
                    continue
                }
            }
            // Something that resembles a saved transaction inside the dates this file covers.
            if let first, let last {
                let lookalikes = sortedExisting.filter { candidate in
                    guard !claimed.contains(candidate.id), candidate.amount == row.amount,
                          candidate.date >= first, candidate.date <= last else { return false }
                    let days = abs(candidate.date.days(until: row.date))
                    guard days <= 3 else { return false }
                    if candidate.status == .posted, row.status == .pending { return true }
                    return days == 0 || KeySimilarity.score(MerchantText(candidate.rawDescription).key, rowKey) >= 50
                }
                if let match = lookalikes.first {
                    claimed.insert(match.id)
                    if match.status == .posted, row.status == .pending {
                        // An old pending line for something already posted: nothing new.
                        dispositions[row.line] = .duplicate(match.id)
                    } else {
                        dispositions[row.line] = .possibleDuplicate(match.id)
                    }
                    continue
                }
            }
            dispositions[row.line] = .new
        }

        let rows = analysis.rows.map { PlannedRow(row: $0, disposition: dispositions[$0.line] ?? .new) }
        let previous = ledger.batches.first { $0.fileHash == analysis.fileHash && $0.accountID == accountID }
        return ImportPlan(analysisID: analysis.id, accountID: accountID, rows: rows, issues: analysis.issues,
                          blankLines: analysis.blankLines, skippedLines: analysis.skippedLines, previousImport: previous)
    }

    /// Same amount, or a posted charge up to 30% larger than the pending one (a tip added).
    static func amountsCompatible(pending: Cents, posted: Cents) -> Bool {
        if pending == posted { return true }
        guard pending < 0, posted < 0 else { return false }
        let pendingSize = pending.magnitude
        let postedSize = posted.magnitude
        return postedSize > pendingSize && postedSize * 10 <= pendingSize * 13
    }
}
