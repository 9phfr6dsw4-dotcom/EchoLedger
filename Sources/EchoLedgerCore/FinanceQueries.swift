import Foundation

/// Read-only lookups used by "Ask EchoLedger". Apple Intelligence picks which lookup to run and
/// with what dates; this code does all the arithmetic, with the same report engine as the
/// Reports screen. Nothing here can change your data.
public enum FinanceQueries {
    public static let maximumDays = 366 * 5

    /// "2026-09-01"…"2026-09-30", or "2026-09" for a whole month.
    public static func period(start: String, end: String) -> DateSpan? {
        let startText = start.trimmingCharacters(in: .whitespaces)
        let endText = end.trimmingCharacters(in: .whitespaces)
        guard let first = parseDay(startText, end: false), let last = parseDay(endText, end: true), first <= last else {
            return nil
        }
        let span = DateSpan(start: first, end: last)
        return span.dayCount <= maximumDays ? span : nil
    }

    static func parseDay(_ text: String, end: Bool) -> LocalDate? {
        if let date = LocalDate(iso: text) { return date }
        let parts = text.split(separator: "-")
        if parts.count == 2, parts[0].count == 4, let year = Int(parts[0]), let month = Int(parts[1]),
           let first = LocalDate(year: year, month: month, day: 1) {
            return end ? first.lastOfMonth : first
        }
        return nil
    }

    static let badDates = "Error: dates must look like 2026-09-01 (or 2026-09 for a whole month), the start must not be after the end, and a period can be at most five years."

    /// Turns a person's name ("Alex", "everyone", "") into a filter; nil when unknown.
    public static func peopleFilter(_ name: String?, ledger: Ledger) -> Set<UUID>? {
        let clean = (name ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if clean.isEmpty || ["everyone", "all", "household", "whole household", "both", "us", "shared", "shared household", "unassigned"].contains(clean) { return [] }
        if let person = ledger.people.first(where: { $0.name.lowercased() == clean || $0.name.lowercased().hasPrefix(clean + " ") }) {
            return [person.id]
        }
        let names = clean.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if names.count > 1 {
            var ids: Set<UUID> = []
            for name in names {
                guard let match = ledger.people.first(where: { $0.name.lowercased() == name }) else { return nil }
                ids.insert(match.id)
            }
            return ids
        }
        return nil
    }

    private static func queryFilter(_ span: DateSpan, people: Set<UUID>, person: String?, ledger: Ledger) -> ReportFilter {
        let name = (person ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let shared = ["shared", "shared household"].contains(name)
        let unassigned = name == "unassigned"
        return ReportFilter(span: span, personIDs: people, currency: ledger.settings.reportCurrency,
                            wholeHousehold: people.isEmpty && !shared && !unassigned,
                            includeShared: shared, includeUnassigned: unassigned)
    }

    static func unknownPerson(_ name: String?, ledger: Ledger) -> String {
        let names = ledger.people.map(\.name).joined(separator: ", ")
        return "Error: no person named \(name ?? ""). People: \(names.isEmpty ? "none set up" : names), or everyone."
    }

    static func header(_ span: DateSpan, people: Set<UUID>, ledger: Ledger) -> String {
        let who = people.isEmpty ? "everyone" : people.compactMap { ledger.person($0)?.name }.sorted().joined(separator: ", ")
        return "Period: \(DateText.medium(span.start)) to \(DateText.medium(span.end)) (\(who))"
    }

    static func reviewLine(_ report: Report) -> String? {
        guard report.unknownCount > 0 else { return nil }
        return "Not included yet: \(report.unknownCount) transactions need review (\(Money.format(-report.unknownOut)) out, \(Money.format(report.unknownIn)) in)."
    }

    public static func summary(_ ledger: Ledger, start: String, end: String, person: String?, today: LocalDate) -> String {
        guard let span = period(start: start, end: end) else { return badDates }
        guard let people = peopleFilter(person, ledger: ledger) else { return unknownPerson(person, ledger: ledger) }
        let report = ReportEngine.build(ledger, filter: queryFilter(span, people: people, person: person, ledger: ledger), today: today)
        var lines = ["Period: \(DateText.medium(span.start)) to \(DateText.medium(span.end)) (\(queryFilter(span, people: people, person: person, ledger: ledger).scopeLabel(in: ledger)))"]
        lines.append("Income: \(Money.format(report.income))")
        lines.append("Spending: \(Money.format(report.spending)) (after \(Money.format(report.refunds)) in refunds)")
        if let rate = report.savingsRateTenths {
            lines.append("Savings: \(Money.format(report.savings)) (\(Money.percentText(tenths: rate)) of income)")
        } else {
            lines.append("Savings: \(Money.format(report.savings))")
        }
        let top = report.categories.prefix(6).map { "\($0.name) \(Money.format($0.amount))" }
        if !top.isEmpty { lines.append("Top categories: " + top.joined(separator: "; ")) }
        if let review = reviewLine(report) { lines.append(review) }
        if report.pendingCount > 0 { lines.append("Pending (not counted): \(report.pendingCount) charges, \(Money.format(report.pendingTotal)).") }
        return lines.joined(separator: "\n")
    }

    public static func category(_ ledger: Ledger, name: String, start: String, end: String, person: String?, today: LocalDate) -> String {
        guard let span = period(start: start, end: end) else { return badDates }
        guard let people = peopleFilter(person, ledger: ledger) else { return unknownPerson(person, ledger: ledger) }
        let clean = name.trimmingCharacters(in: .whitespaces)
        let category = ledger.category(named: clean)
            ?? ledger.categories.first { $0.name.lowercased().contains(clean.lowercased()) && clean.count >= 3 }
        guard let category else {
            return "Error: no category named \(clean). Categories: " + ledger.categories.map(\.name).joined(separator: ", ")
        }
        let report = ReportEngine.build(ledger, filter: queryFilter(span, people: people, person: person, ledger: ledger), today: today)
        var lines = ["Period: \(DateText.medium(span.start)) to \(DateText.medium(span.end)) (\(queryFilter(span, people: people, person: person, ledger: ledger).scopeLabel(in: ledger)))"]
        if category.group == .income {
            let total = report.includedIDs.compactMap { ledger.transactions[$0] }
                .filter { $0.kind == .income && $0.categoryID == category.id }
            let sum = total.reduce(Cents(0)) { $0 + $1.amount }
            lines.append("\(category.name): \(Money.format(sum)) received in \(total.count) transactions.")
        } else if let line = report.categories.first(where: { $0.categoryID == category.id }) {
            lines.append("\(category.name): \(Money.format(line.amount)) spent in \(line.count) transactions"
                         + (line.refunds > 0 ? " (after \(Money.format(line.refunds)) in refunds)." : "."))
            let merchants = line.merchants.prefix(6).map { "\($0.name) \(Money.format($0.amount))" }
            if !merchants.isEmpty { lines.append("Top merchants: " + merchants.joined(separator: "; ")) }
        } else {
            lines.append("\(category.name): \(Money.format(0)) spent (no transactions).")
        }
        if let review = reviewLine(report) { lines.append(review) }
        return lines.joined(separator: "\n")
    }

    public static func merchant(_ ledger: Ledger, name: String, start: String, end: String, person: String?, today: LocalDate) -> String {
        guard let span = period(start: start, end: end) else { return badDates }
        guard let people = peopleFilter(person, ledger: ledger) else { return unknownPerson(person, ledger: ledger) }
        let clean = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard clean.count >= 2 else { return "Error: give at least two letters of the merchant's name." }
        let report = ReportEngine.build(ledger, filter: queryFilter(span, people: people, person: person, ledger: ledger), today: today)
        var total: Cents = 0
        var count = 0
        var names: Set<String> = []
        for category in report.categories {
            for line in category.merchants where line.name.lowercased().contains(clean) {
                total += line.amount
                count += line.count
                names.insert(line.name)
            }
        }
        var lines = ["Period: \(DateText.medium(span.start)) to \(DateText.medium(span.end)) (\(queryFilter(span, people: people, person: person, ledger: ledger).scopeLabel(in: ledger)))"]
        if count == 0 {
            lines.append("No spending found at a merchant matching “\(name)”.")
        } else {
            lines.append("Spending at \(names.sorted().joined(separator: ", ")): \(Money.format(total)) in \(count) transactions.")
        }
        return lines.joined(separator: "\n")
    }

    public static func compare(_ ledger: Ledger, firstStart: String, firstEnd: String, secondStart: String, secondEnd: String,
                               person: String?, today: LocalDate) -> String {
        guard let first = period(start: firstStart, end: firstEnd), let second = period(start: secondStart, end: secondEnd) else {
            return badDates
        }
        guard let people = peopleFilter(person, ledger: ledger) else { return unknownPerson(person, ledger: ledger) }
        let a = ReportEngine.build(ledger, filter: queryFilter(first, people: people, person: person, ledger: ledger), today: today)
        let b = ReportEngine.build(ledger, filter: queryFilter(second, people: people, person: person, ledger: ledger), today: today)
        var lines = [
            "First: \(DateText.medium(first.start)) to \(DateText.medium(first.end)). Second: \(DateText.medium(second.start)) to \(DateText.medium(second.end)).",
            "Spending: \(Money.format(a.spending)) then \(Money.format(b.spending)) (change \(Money.format(b.spending - a.spending, showPlus: true)))",
            "Income: \(Money.format(a.income)) then \(Money.format(b.income)) (change \(Money.format(b.income - a.income, showPlus: true)))"
        ]
        var changes: [String: (name: String, first: Cents, second: Cents)] = [:]
        for line in a.categories { changes[line.id] = (name: line.name, first: line.amount, second: 0) }
        for line in b.categories {
            var entry = changes[line.id] ?? (name: line.name, first: 0, second: 0)
            entry.second = line.amount
            changes[line.id] = entry
        }
        let biggest = changes.values.sorted { (abs($0.second - $0.first), $1.name) > (abs($1.second - $1.first), $0.name) }.prefix(5)
        if !biggest.isEmpty {
            lines.append("Biggest category changes: " + biggest.map {
                "\($0.name) \(Money.format($0.first)) → \(Money.format($0.second)) (\(Money.format($0.second - $0.first, showPlus: true)))"
            }.joined(separator: "; "))
        }
        if let review = reviewLine(a) { lines.append("First period — " + review) }
        if let review = reviewLine(b) { lines.append("Second period — " + review) }
        return lines.joined(separator: "\n")
    }

    public static func transactions(_ ledger: Ledger, start: String, end: String, text: String?, category: String?,
                                    minimumDollars: Int?, person: String?, today: LocalDate, limit: Int = 15) -> String {
        guard let span = period(start: start, end: end) else { return badDates }
        guard let people = peopleFilter(person, ledger: ledger) else { return unknownPerson(person, ledger: ledger) }
        let filter = queryFilter(span, people: people, person: person, ledger: ledger)
        let needle = (text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let categoryNeedle = (category ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let minimum = Cents(max(0, minimumDollars ?? 0)) * 100
        let matches = ledger.transactions.values.filter { transaction in
            guard transaction.isActive, transaction.status == .posted, filter.includes(transaction, ledger: ledger),
                  span.contains(transaction.date), transaction.amount.magnitude >= minimum.magnitude else { return false }
            let merchant = ReportEngine.merchantIdentity(transaction, ledger: ledger).name.lowercased()
            if !needle.isEmpty, !merchant.contains(needle), !transaction.rawDescription.lowercased().contains(needle) { return false }
            if !categoryNeedle.isEmpty {
                let name = ledger.category(transaction.categoryID)?.name.lowercased() ?? ""
                if !name.contains(categoryNeedle) { return false }
            }
            return true
        }
        .sorted { (transaction1, transaction2) in
            (transaction1.amount.magnitude, transaction2.date) > (transaction2.amount.magnitude, transaction1.date)
        }
        var lines = ["Period: \(DateText.medium(span.start)) to \(DateText.medium(span.end)) (\(queryFilter(span, people: people, person: person, ledger: ledger).scopeLabel(in: ledger)))"]
        if matches.isEmpty {
            lines.append("No matching transactions.")
            return lines.joined(separator: "\n")
        }
        let total = matches.reduce(Cents(0)) { $0 + $1.amount }
        lines.append("\(matches.count) matching transactions, net \(Money.format(total)). Largest first:")
        for transaction in matches.prefix(max(1, min(limit, 25))) {
            let merchant = ReportEngine.merchantIdentity(transaction, ledger: ledger).name
            let categoryName = ledger.category(transaction.categoryID)?.name ?? transaction.kind.label
            lines.append("\(DateText.medium(transaction.date)) · \(merchant) · \(categoryName) · \(Money.format(transaction.amount))")
        }
        return lines.joined(separator: "\n")
    }

    public static func recurring(_ ledger: Ledger, person: String?, today: LocalDate) -> String {
        guard let people = peopleFilter(person, ledger: ledger) else { return unknownPerson(person, ledger: ledger) }
        let filter = queryFilter(DateSpan(start: today.adding(days: -400), end: today), people: people, person: person, ledger: ledger)
        let charges = Insights.recurring(ledger, filter: filter, asOf: today).filter(\.isActive)
        guard !charges.isEmpty else { return "No active recurring charges found." }
        var lines = ["Active recurring charges (\(charges.count)):"]
        for charge in charges.prefix(20) {
            lines.append("\(charge.merchantName): \(charge.cadence.label.lowercased()), about \(Money.format(charge.typicalAmount)), last \(DateText.medium(charge.lastDate))"
                         + (charge.priceChanged ? " (changed from \(Money.format(charge.previousAmount)) to \(Money.format(charge.lastAmount)))" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// Context given to the model with every question: today, the data range and the names it
    /// may use.
    public static func context(_ ledger: Ledger, today: LocalDate) -> String {
        let dates = ledger.transactions.values.filter(\.isActive).map(\.date)
        let range: String
        if let first = dates.min(), let last = dates.max() {
            range = "Data runs from \(first.iso) to \(last.iso)."
        } else {
            range = "There are no transactions yet."
        }
        let people = ledger.people.map(\.name)
        let categories = ledger.categories.map(\.name)
        return "Today is \(today.iso). \(range) People: \(people.isEmpty ? "none set up (use everyone)" : people.joined(separator: ", ")). Categories: \(categories.joined(separator: ", "))."
    }
}
