import Foundation

/// What a report covers. Every screen, chart, PDF, CSV export and AI answer uses the same filter
/// and the same calculations, so their numbers always agree.
public struct ReportFilter: Hashable, Sendable {
    public var span: DateSpan
    /// Empty = everyone. Accounts with no owner (shared accounts) are included for everyone.
    public var personIDs: Set<UUID>
    /// Empty = all accounts.
    public var accountIDs: Set<UUID>
    public var currency: String

    public init(span: DateSpan, personIDs: Set<UUID> = [], accountIDs: Set<UUID> = [], currency: String = "USD") {
        self.span = span
        self.personIDs = personIDs
        self.accountIDs = accountIDs
        self.currency = currency
    }

    public func includes(_ account: Account) -> Bool {
        guard account.currency == currency else { return false }
        if !accountIDs.isEmpty, !accountIDs.contains(account.id) { return false }
        if !personIDs.isEmpty, let owner = account.personID, !personIDs.contains(owner) { return false }
        return true
    }

    public func withSpan(_ span: DateSpan) -> ReportFilter {
        var copy = self
        copy.span = span
        return copy
    }
}

public struct MerchantLine: Identifiable, Hashable, Sendable {
    /// Merchant id, or "key:<grouping key>" for transactions without a merchant.
    public var id: String
    public var name: String
    /// Positive = money spent (for spending lines) or received (for income lines).
    public var amount: Cents
    public var count: Int
    public var transactionIDs: [UUID]
}

public struct CategoryLine: Identifiable, Hashable, Sendable {
    /// Category id string, or "uncategorized".
    public var id: String
    public var categoryID: UUID?
    public var name: String
    public var colorIndex: Int
    /// Positive = money spent (net of refunds).
    public var amount: Cents
    public var refunds: Cents
    public var count: Int
    public var merchants: [MerchantLine]
    public var transactionIDs: [UUID]
}

public struct MonthLine: Identifiable, Hashable, Sendable {
    public var monthKey: String
    public var income: Cents
    public var spending: Cents
    public var id: String { monthKey }
    public var net: Cents { income - spending }
}

public struct DataNote: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable { case info, warning }
    public var id: String
    public var severity: Severity
    public var text: String
}

public struct Report: Sendable {
    public var filter: ReportFilter
    public var income: Cents
    /// Net spending: purchases minus refunds.
    public var spending: Cents
    public var refunds: Cents
    public var categories: [CategoryLine]
    public var incomeSources: [MerchantLine]
    public var topMerchants: [MerchantLine]
    public var months: [MonthLine]
    public var transferCount: Int
    /// Money moved between your accounts (sum of the outgoing sides). Not spending.
    public var transferVolume: Cents
    public var unknownCount: Int
    public var unknownIn: Cents
    public var unknownOut: Cents
    public var unknownIDs: [UUID]
    public var pendingCount: Int
    public var pendingTotal: Cents
    /// Every posted transaction counted in the totals.
    public var includedIDs: [UUID]
    /// Counted transactions that Apple Intelligence filed and you haven't checked yet.
    public var aiFiledIDs: [UUID]
    public var notes: [DataNote]
    public var accountNames: [String]

    public var savings: Cents { income - spending }

    /// Savings ÷ income in tenths of a percent; nil when there's no income.
    public var savingsRateTenths: Int? { Money.shareTenths(savings, of: income) }

    /// True when nothing is waiting for review or still pending in this period.
    public var isComplete: Bool { unknownCount == 0 && pendingCount == 0 }
}

public enum ReportEngine {
    typealias Bucket = (name: String, amount: Cents, count: Int, ids: [UUID])
    typealias CategoryBucket = (amount: Cents, refunds: Cents, count: Int, ids: [UUID])

    /// Builds a report. Rules:
    /// - Only posted, active transactions count. Pending charges are listed separately.
    /// - Income = money in marked as income. Spending = money out marked as spending, minus
    ///   refunds (money in marked as spending lowers its category).
    /// - Transfers and card payments are never income or spending.
    /// - Transactions still needing review are shown separately, never hidden or guessed.
    public static func build(_ ledger: Ledger, filter: ReportFilter, today: LocalDate) -> Report {
        let accounts = ledger.accounts.filter { filter.includes($0) }
        let accountIDs = Set(accounts.map(\.id))
        let categoriesByID = Dictionary(ledger.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var income: Cents = 0
        var spending: Cents = 0
        var refunds: Cents = 0
        var categoryTotals: [String: CategoryBucket] = [:]
        var merchantTotals: [String: [String: Bucket]] = [:]
        var allMerchants: [String: Bucket] = [:]
        var incomeTotals: [String: Bucket] = [:]
        var monthIncome: [String: Cents] = [:]
        var monthSpending: [String: Cents] = [:]
        var transferCount = 0
        var transferVolume: Cents = 0
        var unknownCount = 0
        var unknownIn: Cents = 0
        var unknownOut: Cents = 0
        var unknownIDs: [UUID] = []
        var pendingCount = 0
        var pendingTotal: Cents = 0
        var included: [UUID] = []
        var aiFiled: [UUID] = []

        let inSpan = ledger.transactions.values
            .filter { $0.isActive && accountIDs.contains($0.accountID) && filter.span.contains($0.date) }
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }

        for transaction in inSpan {
            if transaction.status == .pending {
                pendingCount += 1
                pendingTotal += transaction.amount
                continue
            }
            let month = transaction.date.monthKey
            if transaction.method == .ai, transaction.review == .automatic,
               transaction.kind == .income || transaction.kind == .expense {
                aiFiled.append(transaction.id)
            }
            switch transaction.kind {
            case .income:
                included.append(transaction.id)
                income += transaction.amount
                monthIncome[month, default: 0] += transaction.amount
                let (id, name) = merchantIdentity(transaction, ledger: ledger)
                var line: Bucket = incomeTotals[id] ?? (name: name, amount: 0, count: 0, ids: [])
                line.amount += transaction.amount
                line.count += 1
                line.ids.append(transaction.id)
                incomeTotals[id] = line
            case .expense:
                included.append(transaction.id)
                let spent = -transaction.amount
                spending += spent
                if transaction.amount > 0 { refunds += transaction.amount }
                monthSpending[month, default: 0] += spent
                let categoryKey = transaction.categoryID.flatMap { categoriesByID[$0] != nil ? $0.uuidString : nil } ?? "uncategorized"
                var category: CategoryBucket = categoryTotals[categoryKey] ?? (amount: 0, refunds: 0, count: 0, ids: [])
                category.amount += spent
                if transaction.amount > 0 { category.refunds += transaction.amount }
                category.count += 1
                category.ids.append(transaction.id)
                categoryTotals[categoryKey] = category
                let (id, name) = merchantIdentity(transaction, ledger: ledger)
                var line: Bucket = merchantTotals[categoryKey]?[id] ?? (name: name, amount: 0, count: 0, ids: [])
                line.amount += spent
                line.count += 1
                line.ids.append(transaction.id)
                merchantTotals[categoryKey, default: [:]][id] = line
                var overall: Bucket = allMerchants[id] ?? (name: name, amount: 0, count: 0, ids: [])
                overall.amount += spent
                overall.count += 1
                overall.ids.append(transaction.id)
                allMerchants[id] = overall
            case .transfer:
                transferCount += 1
                if transaction.amount < 0 { transferVolume += -transaction.amount }
            case .unknown:
                unknownCount += 1
                unknownIDs.append(transaction.id)
                if transaction.amount > 0 { unknownIn += transaction.amount } else { unknownOut += transaction.amount }
            }
        }

        func merchantLines(_ values: [String: Bucket]) -> [MerchantLine] {
            values.map { MerchantLine(id: $0.key, name: $0.value.name, amount: $0.value.amount, count: $0.value.count,
                                      transactionIDs: $0.value.ids) }
                .sorted { ($0.amount, $1.name) > ($1.amount, $0.name) }
        }

        var categoryLines: [CategoryLine] = categoryTotals.map { entry in
            let key = entry.key
            let value = entry.value
            let category = UUID(uuidString: key).flatMap { categoriesByID[$0] }
            return CategoryLine(id: key, categoryID: category?.id, name: category?.name ?? "Uncategorized",
                                colorIndex: category?.colorIndex ?? -1, amount: value.amount, refunds: value.refunds,
                                count: value.count, merchants: merchantLines(merchantTotals[key] ?? [:]),
                                transactionIDs: value.ids)
        }
        categoryLines.sort { ($0.amount, $1.name) > ($1.amount, $0.name) }

        let months = filter.span.monthKeys.map {
            MonthLine(monthKey: $0, income: monthIncome[$0] ?? 0, spending: monthSpending[$0] ?? 0)
        }

        var notes = dataNotes(ledger: ledger, filter: filter, accounts: accounts, today: today, unknownCount: unknownCount,
                              unknownIn: unknownIn, unknownOut: unknownOut, pendingCount: pendingCount,
                              pendingTotal: pendingTotal)
        if !aiFiled.isEmpty {
            let total = aiFiled.compactMap { ledger.transactions[$0]?.amount }.reduce(Cents(0)) { $0 + $1.magnitudeCents }
            let noun = aiFiled.count == 1 ? "transaction was" : "transactions were"
            notes.insert(DataNote(id: "ai-filed", severity: .info,
                                  text: "\(aiFiled.count) \(noun) filed by Apple Intelligence (\(Money.format(total)) in all) and you haven't checked them yet. They're counted; check them in Review."),
                         at: notes.firstIndex { $0.id == "pending" } ?? min(1, notes.count))
        }

        return Report(filter: filter, income: income, spending: spending, refunds: refunds, categories: categoryLines,
                      incomeSources: merchantLines(incomeTotals), topMerchants: Array(merchantLines(allMerchants).prefix(15)),
                      months: months, transferCount: transferCount, transferVolume: transferVolume,
                      unknownCount: unknownCount, unknownIn: unknownIn, unknownOut: unknownOut, unknownIDs: unknownIDs,
                      pendingCount: pendingCount, pendingTotal: pendingTotal, includedIDs: included, aiFiledIDs: aiFiled, notes: notes,
                      accountNames: accounts.map(\.name).sorted())
    }

    /// The merchant a transaction is grouped under: your merchant, else a cleaned-up name.
    public static func merchantIdentity(_ transaction: LedgerTransaction, ledger: Ledger) -> (id: String, name: String) {
        if let id = transaction.merchantID, let merchant = ledger.merchants[id] {
            return (id.uuidString, merchant.name)
        }
        let text = MerchantText(transaction.rawDescription)
        return ("key:" + text.key, text.displayName)
    }

    static func dataNotes(ledger: Ledger, filter: ReportFilter, accounts: [Account], today: LocalDate, unknownCount: Int,
                          unknownIn: Cents, unknownOut: Cents, pendingCount: Int, pendingTotal: Cents) -> [DataNote] {
        var notes: [DataNote] = []
        if unknownCount > 0 {
            let noun = unknownCount == 1 ? "transaction still needs" : "transactions still need"
            notes.append(DataNote(id: "unknown", severity: .warning,
                                  text: "\(unknownCount) \(noun) review (\(Money.format(-unknownOut)) out, \(Money.format(unknownIn)) in). They aren't in the income or spending totals yet."))
        }
        if pendingCount > 0 {
            let noun = pendingCount == 1 ? "pending charge" : "pending charges"
            notes.append(DataNote(id: "pending", severity: .info,
                                  text: "\(pendingCount) \(noun) (\(Money.format(pendingTotal))) will count once they post."))
        }
        let effectiveEnd = min(filter.span.end, today)
        for account in accounts.sorted(by: { $0.name < $1.name }) {
            let dates = ledger.transactions.values.filter { $0.accountID == account.id && $0.isActive }.map(\.date)
            guard let latest = dates.max(), let earliest = dates.min() else { continue }
            if latest < filter.span.start || earliest > filter.span.end {
                if latest >= filter.span.start.adding(days: -62) || earliest <= filter.span.end.adding(days: 62) {
                    notes.append(DataNote(id: "nodata-\(account.id)", severity: .warning,
                                          text: "\(account.name) has no transactions in this period. Import its file if it should be included."))
                }
                continue
            }
            if latest < effectiveEnd.adding(days: -6) {
                notes.append(DataNote(id: "late-\(account.id)", severity: .warning,
                                      text: "\(account.name) has nothing after \(DateText.medium(latest)). Import a newer file if this report should run to \(DateText.medium(effectiveEnd))."))
            }
            if earliest > filter.span.start.adding(days: 6) {
                notes.append(DataNote(id: "early-\(account.id)", severity: .info,
                                      text: "\(account.name) starts on \(DateText.medium(earliest)), after this period begins."))
            }
        }
        let otherCurrency = ledger.accounts.filter { $0.currency != filter.currency && !$0.isArchived }
        if !otherCurrency.isEmpty {
            notes.append(DataNote(id: "currency", severity: .info,
                                  text: "Accounts in other currencies aren't added in: \(otherCurrency.map(\.name).sorted().joined(separator: ", "))."))
        }
        if !filter.personIDs.isEmpty, accounts.contains(where: { $0.personID == nil }) {
            notes.append(DataNote(id: "shared", severity: .info, text: "Shared accounts (no owner) are included."))
        }
        if filter.span.end > today {
            notes.append(DataNote(id: "partial", severity: .info, text: "This period isn't over yet (it runs to \(DateText.medium(filter.span.end)))."))
        }
        return notes
    }
}

// MARK: - Comparison

public struct CategoryChange: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var current: Cents
    public var previous: Cents
    public var change: Cents { current - previous }
    public var changeTenths: Int? { Money.changeTenthsOfPercent(from: previous, to: current) }
}

public struct ReportComparison: Sendable {
    public var current: Report
    public var previous: Report
    public var categoryChanges: [CategoryChange]

    public var spendingChange: Cents { current.spending - previous.spending }
    public var incomeChange: Cents { current.income - previous.income }

    public static func build(_ ledger: Ledger, filter: ReportFilter, today: LocalDate) -> ReportComparison {
        let current = ReportEngine.build(ledger, filter: filter, today: today)
        let previous = ReportEngine.build(ledger, filter: filter.withSpan(filter.span.previous), today: today)
        var byID: [String: CategoryChange] = [:]
        for line in current.categories {
            byID[line.id] = CategoryChange(id: line.id, name: line.name, current: line.amount, previous: 0)
        }
        for line in previous.categories {
            var change = byID[line.id] ?? CategoryChange(id: line.id, name: line.name, current: 0, previous: 0)
            change.previous = line.amount
            byID[line.id] = change
        }
        let changes = byID.values.sorted { (abs($0.change), $1.name) > (abs($1.change), $0.name) }
        return ReportComparison(current: current, previous: previous, categoryChanges: changes)
    }
}

// MARK: - Budgets

public struct BudgetLine: Identifiable, Hashable, Sendable {
    public var id: UUID { categoryID }
    public var categoryID: UUID
    public var name: String
    public var colorIndex: Int
    public var budgeted: Cents
    public var spent: Cents
    public var remaining: Cents { budgeted - spent }
    /// Spent ÷ budgeted in tenths of a percent.
    public var usedTenths: Int? { Money.shareTenths(spent, of: budgeted) }
    public var isOver: Bool { spent > budgeted }
}

public enum BudgetReport {
    /// Monthly budgets times the number of calendar months the period touches.
    public static func lines(_ ledger: Ledger, report: Report) -> [BudgetLine] {
        let months = Int64(max(1, report.filter.span.monthKeys.count))
        return ledger.budgets.compactMap { budget in
            guard let category = ledger.category(budget.categoryID) else { return nil }
            let spent = report.categories.first { $0.categoryID == budget.categoryID }?.amount ?? 0
            return BudgetLine(categoryID: category.id, name: category.name, colorIndex: category.colorIndex,
                              budgeted: budget.monthlyAmount * months, spent: spent)
        }
        .sorted { $0.name < $1.name }
    }

    public static func coversWholeMonths(_ span: DateSpan) -> Bool {
        span.start.day == 1 && span.end == span.end.lastOfMonth
    }
}

extension Cents {
    /// The size of an amount, ignoring direction.
    var magnitudeCents: Cents { Cents(magnitude) }
}
