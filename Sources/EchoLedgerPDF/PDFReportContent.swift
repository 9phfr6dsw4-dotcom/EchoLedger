import EchoLedgerCore
import Foundation

public enum PDFReportStyle: String, CaseIterable, Identifiable, Sendable {
    case signature, everyday, precision

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
    public var detail: String {
        switch self {
        case .signature: "Elegant headings, open spacing, and understated green accents."
        case .everyday: "Friendly summary panels, visual charts, and soft sage accents."
        case .precision: "Crisp tables, numbered sections, and a formal statement layout."
        }
    }
}

/// A snapshot of the exact report being exported. Style never changes its scope or arithmetic.
public struct PDFReportContent: Sendable {
    public struct Allocation: Sendable {
        public let name: String
        public let amount: Cents
    }

    public let report: Report
    public let summary: [String]
    public let summaryIsAI: Bool
    public let recurring: [RecurringCharge]
    public let allocation: [Allocation]
    public let generatedAt: Date
    private let merchantIcons: [UUID: MerchantIconDescriptor]

    public func merchantIcon(name: String, transactionIDs: [UUID]) -> MerchantIconDescriptor {
        transactionIDs.lazy.compactMap { merchantIcons[$0] }.first
            ?? MerchantIconCatalog.descriptor(name: name)
    }

    public init(report: Report, ledger: Ledger, summary: [String], summaryIsAI: Bool = false,
                recurring: [RecurringCharge] = [], generatedAt: Date = Date()) {
        self.report = report
        self.summary = summary
        self.summaryIsAI = summaryIsAI
        self.recurring = recurring.filter(\.isActive)
        self.generatedAt = generatedAt
        var icons: [UUID: MerchantIconDescriptor] = [:]
        let iconIDs = Set(report.includedIDs).union(self.recurring.flatMap(\.transactionIDs))
        for id in iconIDs {
            if let transaction = ledger.transactions[id] {
                icons[id] = MerchantIconCatalog.descriptor(for: transaction, ledger: ledger)
            }
        }
        merchantIcons = icons
        // Attribute only included spending, once per transaction, even when several people use a card.
        var totals: [SpendingAssignment: Cents] = [:]
        for id in report.includedIDs {
            guard let transaction = ledger.transactions[id], transaction.kind == .expense else { continue }
            totals[ledger.assignment(for: transaction), default: 0] -= transaction.amount
        }
        var lines: [Allocation] = ledger.people.compactMap { person in
            guard let amount = totals.removeValue(forKey: .person(person.id)) else { return nil }
            return Allocation(name: person.name, amount: amount)
        }
        if let shared = totals.removeValue(forKey: .shared) {
            lines.append(Allocation(name: "Shared household", amount: shared))
        }
        let unassigned = totals.values.reduce(0, +)
        if !totals.isEmpty { lines.append(Allocation(name: "Unassigned", amount: unassigned)) }
        allocation = lines
    }
}
