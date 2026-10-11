import Foundation

/// CSV files for your own records. Amounts use the same numbers as the screen and the PDF.
public enum CSVExport {
    static func quote(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.hasPrefix(" ") || value.hasSuffix(" ") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        // Keep spreadsheet apps from treating text as a formula.
        if let first = value.first, "=+-@".contains(first), Money.parseCents(value) == nil {
            return "\"'" + value + "\""
        }
        return value
    }

    static func row(_ values: [String]) -> String {
        values.map(quote).joined(separator: ",")
    }

    /// The transactions behind a report (or any list), oldest first.
    public static func transactions(_ ids: [UUID], ledger: Ledger) -> String {
        var lines = [row(["Date", "Posted", "Account", "Owner", "Description", "Merchant", "Kind", "Category", "Amount",
                          "Currency", "Status", "Matched by", "Note"])]
        let items = ids.compactMap { ledger.transactions[$0] }
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        for transaction in items {
            let account = ledger.account(transaction.accountID)
            let owner = ledger.person(account?.personID)?.name ?? (account == nil ? "" : "Shared")
            lines.append(row([
                transaction.date.iso,
                transaction.postedDate?.iso ?? "",
                account?.name ?? "",
                owner,
                transaction.rawDescription,
                ReportEngine.merchantIdentity(transaction, ledger: ledger).name,
                transaction.kind.label,
                ledger.category(transaction.categoryID)?.name ?? "",
                Money.decimalString(transaction.amount),
                transaction.currency,
                transaction.status.rawValue,
                transaction.method.label,
                transaction.note
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Report totals: summary, categories with merchants, and income sources.
    public static func reportSummary(_ report: Report) -> String {
        var lines: [String] = []
        lines.append(row(["EchoLedger report", report.filter.span.label]))
        lines.append(row(["From", report.filter.span.start.iso, "To", report.filter.span.end.iso]))
        lines.append(row(["Accounts", report.accountNames.joined(separator: "; ")]))
        lines.append(row(["Currency", report.filter.currency]))
        lines.append("")
        lines.append(row(["Summary", "Amount"]))
        lines.append(row(["Income", Money.decimalString(report.income)]))
        lines.append(row(["Spending (after refunds)", Money.decimalString(report.spending)]))
        lines.append(row(["Refunds", Money.decimalString(report.refunds)]))
        lines.append(row(["Savings", Money.decimalString(report.savings)]))
        lines.append(row(["Transfers between accounts (not counted)", Money.decimalString(report.transferVolume)]))
        lines.append(row(["Needs review: money in (not counted)", Money.decimalString(report.unknownIn)]))
        lines.append(row(["Needs review: money out (not counted)", Money.decimalString(report.unknownOut)]))
        lines.append(row(["Pending (not counted)", Money.decimalString(report.pendingTotal)]))
        lines.append("")
        lines.append(row(["Category", "Merchant", "Spent", "Transactions"]))
        for category in report.categories {
            lines.append(row([category.name, "", Money.decimalString(category.amount), String(category.count)]))
            for merchant in category.merchants {
                lines.append(row([category.name, merchant.name, Money.decimalString(merchant.amount), String(merchant.count)]))
            }
        }
        lines.append("")
        lines.append(row(["Income source", "Received", "Transactions"]))
        for source in report.incomeSources {
            lines.append(row([source.name, Money.decimalString(source.amount), String(source.count)]))
        }
        if !report.notes.isEmpty {
            lines.append("")
            lines.append(row(["Notes"]))
            for note in report.notes { lines.append(row([note.text])) }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
