import EchoLedgerCore
import Foundation

/// Synthetic data only. Demo runtimes always use a new temporary database.
enum DemoLedger {
    static func make(today: LocalDate) -> Ledger {
        var ledger = Ledger.starter()
        let alex = Person(name: "Alex")
        let sam = Person(name: "Sam")
        let riley = Person(name: "Riley", monthlyAllowance: 30_000)
        ledger.people = [alex, sam, riley]
        let checking = Account(name: "Everyday checking", personID: alex.id, type: .checking, rarelyUsed: true)
        let card = Account(name: "Travel credit card", personID: sam.id, type: .creditCard, rarelyUsed: true,
                           cardAssignments: ["Cardholder: Riley": .person(riley.id)])
        let debit = Account(name: "Riley debit card", personID: riley.id, type: .checking, rarelyUsed: true)
        let joint = Account(name: "Joint checking", personID: nil, type: .checking, rarelyUsed: true,
                            userIDs: [alex.id, sam.id])
        let savings = Account(name: "New savings", personID: nil, type: .savings, rarelyUsed: true, isUnassigned: true)
        ledger.accounts = [checking, card, debit, joint, savings]
        let lastMonth = today.firstOfMonth.adding(months: -1)
        for offset in -5...0 {
            let month = lastMonth.adding(months: offset)
            let multiplier = Cents(100 + offset * 3)
            let entries: [(Account, String, String, Cents, Int)] = [
                (checking, "Salary", "Example Studio Payroll", 360_000, 1),
                (card, "Salary", "Example Workshop Payroll", 280_000, 1),
                (joint, "Housing", "Sample Property Rent", -140_000, 2),
                (checking, "Groceries", "Sample Market", -64_000 * multiplier / 100, 8),
                (checking, "Dining", "Example Kitchen", -25_000 * multiplier / 100, 12),
                (checking, "Shopping", "Sample Goods", -31_000 * multiplier / 100, 18),
                (card, "Dining", "Example Cafe", -17_000 * multiplier / 100, 9),
                (card, "Transportation", "Sample Transit", -26_000 * multiplier / 100, 15),
                (card, "Other Spending", "Example Services", -55_000 * multiplier / 100, 20),
                (card, "Dining", "Sample Lunch", -9_000 * multiplier / 100, 10),
                (debit, "Transportation", "Example Bus", -6_000 * multiplier / 100, 16),
                (debit, "Shopping", "Sample Books", -5_000 * multiplier / 100, 21),
                (debit, "Other Spending", "Example Activities", -4_000 * multiplier / 100, 24)
            ]
            for (account, categoryName, merchant, amount, day) in entries {
                let date = month.adding(days: day - 1)
                var transaction = LedgerTransaction(accountID: account.id, batchID: nil, sourceLine: 0,
                    date: date, postedDate: date, amount: amount, currency: "USD", rawDescription: merchant,
                    status: .posted, fingerprint: "demo|\(date.iso)|\(merchant)", occurrence: 1)
                transaction.kind = amount > 0 ? .income : .expense
                transaction.categoryID = ledger.category(named: categoryName)?.id
                transaction.review = .confirmed
                transaction.method = .manual
                if merchant == "Sample Lunch" { transaction.cardIdentifier = "Cardholder: Riley" }
                transaction.inheritedAssignment = ledger.defaultAssignment(accountID: account.id, cardIdentifier: transaction.cardIdentifier)
                ledger.transactions[transaction.id] = transaction
            }
        }
        for (name, amount) in [("Housing", Cents(180_000)), ("Groceries", 75_000), ("Dining", 60_000),
                               ("Transportation", 40_000), ("Shopping", 45_000), ("Other Spending", 90_000)] {
            if let category = ledger.category(named: name) { _ = ledger.setBudget(categoryID: category.id, monthlyAmount: amount) }
        }
        return ledger
    }
}
