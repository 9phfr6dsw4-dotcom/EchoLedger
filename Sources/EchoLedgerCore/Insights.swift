import Foundation

public enum Cadence: String, Sendable, Hashable {
    case weekly, monthly, yearly

    public var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    var typicalDays: Int {
        switch self {
        case .weekly: return 7
        case .monthly: return 30
        case .yearly: return 365
        }
    }
}

/// A charge that repeats on a schedule, found by plain arithmetic (no AI).
public struct RecurringCharge: Identifiable, Hashable, Sendable {
    public var id: String
    public var merchantName: String
    public var cadence: Cadence
    /// Typical size of one charge (positive).
    public var typicalAmount: Cents
    public var lastAmount: Cents
    public var previousAmount: Cents
    public var lastDate: LocalDate
    public var nextExpected: LocalDate
    public var count: Int
    /// Still happening as of the report's end date.
    public var isActive: Bool
    public var transactionIDs: [UUID]

    public var priceChanged: Bool { lastAmount != previousAmount }

    /// Rough yearly cost from the typical amount.
    public var yearlyCost: Cents {
        switch cadence {
        case .weekly: return typicalAmount * 52
        case .monthly: return typicalAmount * 12
        case .yearly: return typicalAmount
        }
    }
}

/// A charge much larger than usual for its merchant, or a large first-time merchant.
public struct UnusualCharge: Identifiable, Hashable, Sendable {
    public var id: UUID { transactionID }
    public var transactionID: UUID
    public var merchantName: String
    public var date: LocalDate
    public var amount: Cents
    /// The usual charge at this merchant (median), or nil for a first-time merchant.
    public var usualAmount: Cents?
    public var reason: String
}

public enum Insights {
    /// Finds recurring charges among spending (money out) up to `asOf`, using every transaction in
    /// the filter's accounts (not only the report period), because a pattern needs history.
    /// A merchant qualifies with at least 3 charges whose gaps fit one cadence (most of them),
    /// and amounts that stay close (within 25% or $3 of the typical amount).
    public static func recurring(_ ledger: Ledger, filter: ReportFilter, asOf: LocalDate) -> [RecurringCharge] {
        let spending = ledger.transactions.values.filter {
            $0.isActive && $0.status == .posted && $0.kind == .expense && $0.amount < 0
                && filter.includes($0, ledger: ledger) && $0.date <= asOf
        }
        let groups = Dictionary(grouping: spending) { ReportEngine.merchantIdentity($0, ledger: ledger).id }
        var result: [RecurringCharge] = []
        for (groupID, items) in groups {
            let sorted = items.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            guard sorted.count >= 3 else { continue }
            let recent = Array(sorted.suffix(12))
            var gaps: [Int] = []
            for index in 1..<recent.count {
                gaps.append(recent[index - 1].date.days(until: recent[index].date))
            }
            guard let cadence = cadenceFor(gaps: gaps) else { continue }
            let amounts = recent.map { -$0.amount }
            let typical = median(Array(amounts.suffix(3)))
            let stable = amounts.suffix(6).allSatisfy { amount in
                let difference = abs(amount - typical)
                return difference <= 300 || difference * 4 <= typical
            }
            guard stable, let last = recent.last else { continue }
            let previous = recent[recent.count - 2]
            let nextExpected = cadence == .monthly ? last.date.adding(months: 1) : last.date.adding(days: cadence.typicalDays)
            let active = last.date.days(until: asOf) <= cadence.typicalDays * 3 / 2 + 3
            result.append(RecurringCharge(id: groupID, merchantName: ReportEngine.merchantIdentity(last, ledger: ledger).name,
                                          cadence: cadence, typicalAmount: typical, lastAmount: -last.amount,
                                          previousAmount: -previous.amount, lastDate: last.date, nextExpected: nextExpected,
                                          count: sorted.count, isActive: active, transactionIDs: sorted.map(\.id)))
        }
        return result.sorted { left, right in
            if left.isActive != right.isActive { return left.isActive }
            if left.yearlyCost != right.yearlyCost { return left.yearlyCost > right.yearlyCost }
            return left.merchantName < right.merchantName
        }
    }

    static func cadenceFor(gaps: [Int]) -> Cadence? {
        guard !gaps.isEmpty else { return nil }
        let needed = max(2, (gaps.count * 2 + 2) / 3)
        let monthly = gaps.filter { (26...35).contains($0) }.count
        let weekly = gaps.filter { (6...8).contains($0) }.count
        let yearly = gaps.filter { (350...380).contains($0) }.count
        if monthly >= needed { return .monthly }
        if weekly >= needed { return .weekly }
        if yearly >= max(2, needed) { return .yearly }
        return nil
    }

    static func median(_ values: [Cents]) -> Cents {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        let upper = sorted[sorted.count / 2]
        let lower = sorted[sorted.count / 2 - 1]
        return (lower + upper) / 2
    }

    /// Spending in the report period that stands out: at least 3× the merchant's usual charge
    /// (from the 180 days before, with at least 3 earlier charges) and $25 more than usual, or a
    /// first charge of $200 or more at a merchant you've never paid before.
    public static func unusual(_ ledger: Ledger, filter: ReportFilter) -> [UnusualCharge] {
        let spending = ledger.transactions.values.filter {
            $0.isActive && $0.status == .posted && $0.kind == .expense && $0.amount < 0 && filter.includes($0, ledger: ledger)
        }
        let groups = Dictionary(grouping: spending) { ReportEngine.merchantIdentity($0, ledger: ledger).id }
        var result: [UnusualCharge] = []
        for (_, items) in groups {
            let sorted = items.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            for transaction in sorted where filter.span.contains(transaction.date) {
                let size = -transaction.amount
                let history = sorted.filter {
                    $0.date < transaction.date && $0.date >= transaction.date.adding(days: -180)
                }.map { -$0.amount }
                let earlierAtAll = sorted.contains { $0.date < transaction.date }
                let name = ReportEngine.merchantIdentity(transaction, ledger: ledger).name
                if history.count >= 3 {
                    let usual = median(history)
                    if size >= usual * 3, size - usual >= 2500 {
                        result.append(UnusualCharge(transactionID: transaction.id, merchantName: name, date: transaction.date,
                                                    amount: size, usualAmount: usual,
                                                    reason: "About \(size / max(usual, 1))× your usual \(Money.format(usual)) at \(name)."))
                    }
                } else if !earlierAtAll, size >= 20_000 {
                    result.append(UnusualCharge(transactionID: transaction.id, merchantName: name, date: transaction.date,
                                                amount: size, usualAmount: nil,
                                                reason: "First charge at \(name), and a large one."))
                }
            }
        }
        return result.sorted { ($0.amount, $0.transactionID.uuidString) > ($1.amount, $1.transactionID.uuidString) }
    }
}
