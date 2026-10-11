import Foundation

/// A numbered statement computed by EchoLedger, given to Apple Intelligence as the only facts it
/// may use. Narrative bullets must cite these ids.
public struct ReportFact: Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    /// Transactions behind this fact, for drill-down.
    public var transactionIDs: [UUID]
}

/// A narrative bullet that passed checking.
public struct GroundedBullet: Identifiable, Hashable, Sendable {
    public var id: Int
    public var text: String
    public var facts: [ReportFact]
}

public enum ReportFacts {
    /// Facts for a period compared with the one before it.
    public static func build(comparison: ReportComparison, recurring: [RecurringCharge], unusual: [UnusualCharge]) -> [ReportFact] {
        var facts: [ReportFact] = []
        func add(_ text: String, _ ids: [UUID] = []) {
            facts.append(ReportFact(id: "F\(facts.count + 1)", text: text, transactionIDs: ids))
        }
        let current = comparison.current
        let previous = comparison.previous
        let label = current.filter.span.label
        let previousLabel = previous.filter.span.label
        add("Spending in \(label) was \(Money.format(current.spending)), compared with \(Money.format(previous.spending)) in \(previousLabel)"
            + changeText(from: previous.spending, to: current.spending) + ".", current.includedIDs)
        add("Income in \(label) was \(Money.format(current.income)), compared with \(Money.format(previous.income)) in \(previousLabel)"
            + changeText(from: previous.income, to: current.income) + ".")
        if let rate = current.savingsRateTenths {
            add("Savings in \(label) were \(Money.format(current.savings)), \(Money.percentText(tenths: rate)) of income.")
        } else {
            add("Savings in \(label) were \(Money.format(current.savings)) (no income recorded, so no savings rate).")
        }
        for line in current.categories.prefix(5) {
            add("Spending on \(line.name) in \(label) was \(Money.format(line.amount)) across \(line.count) transactions.",
                line.transactionIDs)
        }
        let increases = comparison.categoryChanges.filter { $0.change > 0 }.prefix(3)
        for change in increases {
            add("\(change.name) rose by \(Money.format(change.change)) (from \(Money.format(change.previous)) to \(Money.format(change.current)))"
                + percentSuffix(change) + ".",
                current.categories.first { $0.id == change.id }?.transactionIDs ?? [])
        }
        let decreases = comparison.categoryChanges.filter { $0.change < 0 }.prefix(3)
        for change in decreases {
            add("\(change.name) fell by \(Money.format(-change.change)) (from \(Money.format(change.previous)) to \(Money.format(change.current)))"
                + percentSuffix(change) + ".",
                current.categories.first { $0.id == change.id }?.transactionIDs ?? [])
        }
        for merchant in current.topMerchants.prefix(3) {
            add("\(merchant.name) received \(Money.format(merchant.amount)) over \(merchant.count) transactions.", merchant.transactionIDs)
        }
        for charge in recurring.filter({ $0.isActive && $0.priceChanged }).prefix(3) {
            add("The \(charge.cadence.label.lowercased()) charge from \(charge.merchantName) changed from \(Money.format(charge.previousAmount)) to \(Money.format(charge.lastAmount)).",
                Array(charge.transactionIDs.suffix(2)))
        }
        let activeRecurring = recurring.filter(\.isActive)
        if !activeRecurring.isEmpty {
            let monthly = activeRecurring.reduce(Cents(0)) { total, charge in
                switch charge.cadence {
                case .monthly: return total + charge.typicalAmount
                case .weekly: return total + charge.typicalAmount * 52 / 12
                case .yearly: return total + charge.typicalAmount / 12
                }
            }
            add("There are \(activeRecurring.count) active recurring charges, about \(Money.format(monthly)) a month in total.")
        }
        for item in unusual.prefix(3) {
            add("On \(DateText.medium(item.date)), \(item.merchantName) charged \(Money.format(item.amount)). \(item.reason)", [item.transactionID])
        }
        if current.unknownCount > 0 {
            add("\(current.unknownCount) transactions still need review and are not included in these totals.", current.unknownIDs)
        }
        return facts
    }

    static func changeText(from old: Cents, to new: Cents) -> String {
        guard let tenths = Money.changeTenthsOfPercent(from: old, to: new) else { return "" }
        return tenths == 0 ? " (no change)" : " (\(Money.percentText(tenths: tenths, showPlus: true)))"
    }

    static func percentSuffix(_ change: CategoryChange) -> String {
        guard let tenths = change.changeTenths else { return "" }
        return ", \(Money.percentText(tenths: tenths, showPlus: true))"
    }
}

/// Checks that numbers in AI-written text come from EchoLedger's own calculations.
public enum Grounding {
    public enum Number: Hashable, Sendable {
        /// Cents, and whether the text gave cents (false for "$1,235").
        case money(Cents, hadCents: Bool)
        /// Tenths of a percent, and whether a decimal was given.
        case percent(Int, hadDecimal: Bool)
    }

    /// Money ("$1,234.56", "$1,235", "-$3.10") and percentages ("12.3%", "12%") in text.
    public static func numbers(in text: String) -> [Number] {
        var result: [Number] = []
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 48 && scalar.value <= 57 }
        func isNumberPart(_ scalar: Unicode.Scalar) -> Bool {
            isDigit(scalar) || scalar.value == 46 || scalar.value == 44 || scalar.value == 36   // . , $
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "$" {
                var cursor = index + 1
                var digits = ""
                var fraction = ""
                var sawDot = false
                while cursor < scalars.count {
                    let next = scalars[cursor]
                    if isDigit(next) {
                        if sawDot { fraction.unicodeScalars.append(next) } else { digits.unicodeScalars.append(next) }
                    } else if next == ",", !sawDot, cursor + 1 < scalars.count, isDigit(scalars[cursor + 1]) {
                        // thousands separator
                    } else if next == ".", !sawDot, cursor + 1 < scalars.count, isDigit(scalars[cursor + 1]) {
                        sawDot = true
                    } else {
                        break
                    }
                    cursor += 1
                }
                if let whole = Int64(digits) {
                    var cents: Int64 = 0
                    if fraction.count >= 2 {
                        cents = Int64(String(fraction.prefix(2))) ?? 0
                    } else if fraction.count == 1 {
                        cents = (Int64(fraction) ?? 0) * 10
                    }
                    result.append(.money(whole * 100 + cents, hadCents: !fraction.isEmpty))
                }
                index = max(cursor, index + 1)
                continue
            }
            if isDigit(scalar), index == 0 || !isNumberPart(scalars[index - 1]) {
                var cursor = index
                var digits = ""
                var fraction = ""
                var sawDot = false
                while cursor < scalars.count {
                    let next = scalars[cursor]
                    if isDigit(next) {
                        if sawDot { fraction.unicodeScalars.append(next) } else { digits.unicodeScalars.append(next) }
                    } else if next == ".", !sawDot, cursor + 1 < scalars.count, isDigit(scalars[cursor + 1]) {
                        sawDot = true
                    } else {
                        break
                    }
                    cursor += 1
                }
                if cursor < scalars.count, scalars[cursor] == "%", let whole = Int(digits) {
                    let tenths = whole * 10 + (fraction.isEmpty ? 0 : Int(String(fraction.prefix(1))) ?? 0)
                    result.append(.percent(tenths, hadDecimal: !fraction.isEmpty))
                    index = cursor + 1
                    continue
                }
                index = max(cursor, index + 1)
                continue
            }
            index += 1
        }
        return result
    }

    /// True when every money amount and percentage in `text` matches one in `sources` (signs are
    /// ignored; "$1,235" may round "$1,234.56"; "12%" may round "12.3%").
    public static func isGrounded(_ text: String, sources: [String]) -> Bool {
        let allowed = sources.flatMap { numbers(in: $0) }
        for number in numbers(in: text) {
            switch number {
            case .money(let cents, let hadCents):
                let ok = allowed.contains { candidate in
                    guard case .money(let other, _) = candidate else { return false }
                    if hadCents { return other == cents }
                    return abs(other - cents) <= 50 || other == cents
                }
                if !ok { return false }
            case .percent(let tenths, let hadDecimal):
                let ok = allowed.contains { candidate in
                    guard case .percent(let other, _) = candidate else { return false }
                    if hadDecimal { return other == tenths }
                    return abs(other - tenths) <= 5
                }
                if !ok { return false }
            }
        }
        return true
    }

    /// Keeps only bullets that cite real facts and whose numbers all come from those facts.
    public static func checkBullets(_ bullets: [(text: String, factIDs: [String])], facts: [ReportFact]) -> [GroundedBullet] {
        let byID = Dictionary(facts.map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var result: [GroundedBullet] = []
        for bullet in bullets {
            let text = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 400 else { continue }
            let cited = bullet.factIDs.compactMap { byID[$0.trimmingCharacters(in: .whitespaces).uppercased()] }
            guard !cited.isEmpty, isGrounded(text, sources: cited.map(\.text)) else { continue }
            result.append(GroundedBullet(id: result.count, text: text, facts: cited))
        }
        return result
    }
}

/// Checks an Apple Intelligence merchant/category suggestion before it is shown. Invalid answers
/// are dropped. Valid ones are filed (marked, undoable) or stored as suggestions, as you choose.
public enum SuggestionCheck {
    public static func validate(merchant: String, category: String, kind: String, ledger: Ledger, amount: Cents) -> Suggestion? {
        let cleanKind = kind.trimmingCharacters(in: .whitespaces).lowercased()
        let parsedKind: TransactionKind
        switch cleanKind {
        case "expense", "spending": parsedKind = .expense
        case "income": parsedKind = .income
        case "transfer": parsedKind = .transfer
        default: return nil
        }
        var name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased() == "unknown" || name.lowercased() == "none" { name = "" }
        if name.count > 40 || name.contains("\n") || name.lowercased().contains("http") { return nil }
        if !name.isEmpty, name.filter({ $0.isLetter }).count < 2 { return nil }
        var categoryID: UUID?
        if parsedKind != .transfer {
            guard let match = ledger.category(named: category.trimmingCharacters(in: .whitespaces)) else { return nil }
            let expectedGroup: CategoryGroup = parsedKind == .income ? .income : .expense
            guard match.group == expectedGroup else { return nil }
            categoryID = match.id
        }
        // Income must be money in; spending money out is normal, money in would be a refund.
        if parsedKind == .income, amount < 0 { return nil }
        return Suggestion(merchantName: name.isEmpty ? nil : name, categoryID: categoryID, kind: parsedKind, source: .ai,
                          reason: "Apple Intelligence suggestion")
    }

    /// The text given to the model for one transaction. Long digit runs (card numbers,
    /// references) are hidden; the description is data, never instructions.
    public static func describe(_ transaction: LedgerTransaction, ledger: Ledger) -> String {
        let text = MerchantText(transaction.rawDescription)
        let account = ledger.account(transaction.accountID)
        var lines = [
            "Bank text: \(redactDigits(text.normalized))",
            "Cleaned: \(text.key)",
            "Direction: \(transaction.amount < 0 ? "money out" : "money in")",
            "Amount: \(Money.format(Cents(transaction.amount.magnitude)))",
            "Account type: \(account?.type.label ?? "unknown")"
        ]
        if let via = text.via { lines.append("Paid through: \(via)") }
        if let bankMerchant = transaction.bankMerchant { lines.append("Bank's merchant name: \(bankMerchant)") }
        if let bankCategory = transaction.bankCategory { lines.append("Bank's category: \(bankCategory)") }
        return lines.joined(separator: "\n")
    }

    static func redactDigits(_ text: String) -> String {
        var result = ""
        var run = ""
        for character in text + " " {
            if character >= "0" && character <= "9" {
                run.append(character)
            } else {
                result += run.count >= 5 ? String(repeating: "#", count: run.count) : run
                run = ""
                result.append(character)
            }
        }
        return String(result.dropLast())
    }
}
