import EchoLedgerCore
import Foundation
import FoundationModels

/// Records every lookup Apple Intelligence makes, so each answer can show how it was worked out.
final class ToolCallLog: @unchecked Sendable {
    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let tool: String
        let arguments: String
        let result: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func record(_ tool: String, _ arguments: String, _ result: String) {
        lock.lock()
        storage.append(Entry(tool: tool, arguments: arguments, result: result))
        lock.unlock()
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// The lookups below are read-only. Each one runs EchoLedger's own report engine on a snapshot of
// your data and returns plain text; none of them can change anything.

struct SummaryTool: Tool {
    let name = "spendingSummary"
    let description = "Income, spending, savings and top categories for a period, for everyone or one person."
    let ledger: Ledger
    let today: LocalDate
    let log: ToolCallLog

    @Generable
    struct Arguments {
        @Guide(description: "First day, as YYYY-MM-DD, or YYYY-MM for a whole month")
        var start: String
        @Guide(description: "Last day, as YYYY-MM-DD, or YYYY-MM for a whole month")
        var end: String
        @Guide(description: "A person's name, or everyone")
        var person: String
    }

    func call(arguments: Arguments) async throws -> String {
        let result = FinanceQueries.summary(ledger, start: arguments.start, end: arguments.end, person: arguments.person, today: today)
        log.record("Summary", "\(arguments.start) to \(arguments.end), \(arguments.person)", result)
        return result
    }
}

struct CategoryTool: Tool {
    let name = "categorySpending"
    let description = "Spending in one category for a period, with its top merchants."
    let ledger: Ledger
    let today: LocalDate
    let log: ToolCallLog

    @Generable
    struct Arguments {
        @Guide(description: "A category name such as Dining or Groceries")
        var category: String
        @Guide(description: "First day, as YYYY-MM-DD, or YYYY-MM for a whole month")
        var start: String
        @Guide(description: "Last day, as YYYY-MM-DD, or YYYY-MM for a whole month")
        var end: String
        @Guide(description: "A person's name, or everyone")
        var person: String
    }

    func call(arguments: Arguments) async throws -> String {
        let result = FinanceQueries.category(ledger, name: arguments.category, start: arguments.start, end: arguments.end,
                                             person: arguments.person, today: today)
        log.record("Category", "\(arguments.category), \(arguments.start) to \(arguments.end), \(arguments.person)", result)
        return result
    }
}

struct MerchantTool: Tool {
    let name = "merchantSpending"
    let description = "How much was spent at a merchant in a period."
    let ledger: Ledger
    let today: LocalDate
    let log: ToolCallLog

    @Generable
    struct Arguments {
        @Guide(description: "Part of the merchant's name, such as Amazon")
        var merchant: String
        @Guide(description: "First day, as YYYY-MM-DD, or YYYY-MM for a whole month")
        var start: String
        @Guide(description: "Last day, as YYYY-MM-DD, or YYYY-MM for a whole month")
        var end: String
        @Guide(description: "A person's name, or everyone")
        var person: String
    }

    func call(arguments: Arguments) async throws -> String {
        let result = FinanceQueries.merchant(ledger, name: arguments.merchant, start: arguments.start, end: arguments.end,
                                             person: arguments.person, today: today)
        log.record("Merchant", "\(arguments.merchant), \(arguments.start) to \(arguments.end), \(arguments.person)", result)
        return result
    }
}

struct CompareTool: Tool {
    let name = "comparePeriods"
    let description = "Compares spending and income between two periods, with the biggest category changes."
    let ledger: Ledger
    let today: LocalDate
    let log: ToolCallLog

    @Generable
    struct Arguments {
        @Guide(description: "First period start, YYYY-MM-DD or YYYY-MM")
        var firstStart: String
        @Guide(description: "First period end, YYYY-MM-DD or YYYY-MM")
        var firstEnd: String
        @Guide(description: "Second period start, YYYY-MM-DD or YYYY-MM")
        var secondStart: String
        @Guide(description: "Second period end, YYYY-MM-DD or YYYY-MM")
        var secondEnd: String
        @Guide(description: "A person's name, or everyone")
        var person: String
    }

    func call(arguments: Arguments) async throws -> String {
        let result = FinanceQueries.compare(ledger, firstStart: arguments.firstStart, firstEnd: arguments.firstEnd,
                                            secondStart: arguments.secondStart, secondEnd: arguments.secondEnd,
                                            person: arguments.person, today: today)
        log.record("Compare", "\(arguments.firstStart)–\(arguments.firstEnd) vs \(arguments.secondStart)–\(arguments.secondEnd), \(arguments.person)", result)
        return result
    }
}

struct TransactionsTool: Tool {
    let name = "findTransactions"
    let description = "Lists the largest matching transactions in a period, optionally by text, category or minimum amount."
    let ledger: Ledger
    let today: LocalDate
    let log: ToolCallLog

    @Generable
    struct Arguments {
        @Guide(description: "First day, as YYYY-MM-DD, or YYYY-MM for a whole month")
        var start: String
        @Guide(description: "Last day, as YYYY-MM-DD, or YYYY-MM for a whole month")
        var end: String
        @Guide(description: "Text to look for in the merchant or description, or empty")
        var text: String
        @Guide(description: "A category name, or empty")
        var category: String
        @Guide(description: "Smallest amount in whole dollars, or 0")
        var minimumDollars: Int
        @Guide(description: "A person's name, or everyone")
        var person: String
    }

    func call(arguments: Arguments) async throws -> String {
        let result = FinanceQueries.transactions(ledger, start: arguments.start, end: arguments.end, text: arguments.text,
                                                 category: arguments.category, minimumDollars: arguments.minimumDollars,
                                                 person: arguments.person, today: today)
        log.record("Transactions", "\(arguments.start) to \(arguments.end), text “\(arguments.text)”, category “\(arguments.category)”, at least $\(arguments.minimumDollars)", result)
        return result
    }
}

struct RecurringTool: Tool {
    let name = "recurringCharges"
    let description = "Lists active recurring charges such as subscriptions, with their usual amounts."
    let ledger: Ledger
    let today: LocalDate
    let log: ToolCallLog

    @Generable
    struct Arguments {
        @Guide(description: "A person's name, or everyone")
        var person: String
    }

    func call(arguments: Arguments) async throws -> String {
        let result = FinanceQueries.recurring(ledger, person: arguments.person, today: today)
        log.record("Recurring", arguments.person, result)
        return result
    }
}

enum AskTools {
    static func all(ledger: Ledger, today: LocalDate, log: ToolCallLog) -> [any Tool] {
        [
            SummaryTool(ledger: ledger, today: today, log: log),
            CategoryTool(ledger: ledger, today: today, log: log),
            MerchantTool(ledger: ledger, today: today, log: log),
            CompareTool(ledger: ledger, today: today, log: log),
            TransactionsTool(ledger: ledger, today: today, log: log),
            RecurringTool(ledger: ledger, today: today, log: log)
        ]
    }
}
