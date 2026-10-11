import AppKit
import EchoLedgerCore
import SwiftUI
import UniformTypeIdentifiers

/// A row in the transactions table (strings computed once, so the table stays fast).
struct TransactionRow: Identifiable, Hashable {
    let id: UUID
    let date: LocalDate
    let merchant: String
    let detail: String
    let categoryName: String
    let colorIndex: Int
    let kind: TransactionKind
    let accountName: String
    let amount: Cents
    let isPending: Bool
    let needsReview: Bool
    let isVoided: Bool
    let isManual: Bool
}

enum TransactionFilter: Hashable {
    case all, needsReview, aiFiled, spending, income, transfers, pending, removed
    case category(UUID)

    var label: String {
        switch self {
        case .all: return "All transactions"
        case .needsReview: return "Needs review"
        case .aiFiled: return "Filed by Apple Intelligence"
        case .spending: return "Spending"
        case .income: return "Income"
        case .transfers: return "Transfers"
        case .pending: return "Pending"
        case .removed: return "Removed"
        case .category: return "Category"
        }
    }
}

struct TransactionsView: View {
    @Environment(LedgerRuntime.self) private var runtime
    @State private var search = ""
    @State private var period: PeriodChoice = .last3Months
    @State private var customStart = LocalDate(year: 2026, month: 1, day: 1) ?? LocalDate(dayNumber: 0)
    @State private var customEnd = LocalDate(year: 2026, month: 12, day: 31) ?? LocalDate(dayNumber: 0)
    @State private var personID: UUID?
    @State private var accountID: UUID?
    @State private var filter: TransactionFilter = .all
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\TransactionRow.date, order: .reverse)]
    @State private var showDetails = true

    // The details panel is part of this screen's own layout rather than a window inspector or
    // toolbar item, so the window's toolbar and safe area stay the same on every screen.
    // (Adding and removing an inspector, toolbar button and toolbar search field while
    // switching screens made AppKit's layout loop until it crashed.)
    var body: some View {
        let rows = filteredRows()
        HStack(spacing: 0) {
            transactionList(rows)
            if showDetails {
                Divider()
                TransactionInspector(ids: Array(selection))
                    .frame(width: 330)
            }
        }
        .onAppear {
            if runtime.transactionsFocus != nil { period = .allTime }
        }
        .onChange(of: runtime.transactionsFocus) { _, focus in
            if focus != nil {
                period = .allTime
                filter = .all
            }
        }
    }

    private func transactionList(_ rows: [TransactionRow]) -> some View {
        VStack(spacing: 0) {
            filterBar
            if let focus = runtime.transactionsFocus {
                focusBanner(focus)
            }
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Date", value: \.date) { row in
                    Text(DateText.medium(row.date))
                        .monospacedDigit()
                        .foregroundStyle(row.isVoided ? Color.secondary : Color.primary)
                }
                .width(min: 84, ideal: 100, max: 120)
                TableColumn("Merchant", value: \.merchant) { row in
                    MerchantCell(row: row)
                }
                .width(min: 150, ideal: 280)
                TableColumn("Category", value: \.categoryName) { row in
                    HStack(spacing: 6) {
                        if row.kind == .expense || row.kind == .income {
                            CategoryDot(colorIndex: row.colorIndex)
                        }
                        Text(row.categoryName)
                            .foregroundStyle(row.needsReview ? Color.orange : Color.primary)
                    }
                }
                .width(min: 100, ideal: 160)
                TableColumn("Account", value: \.accountName) { row in
                    Text(row.accountName)
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 160)
                TableColumn("Amount", value: \.amount) { row in
                    MoneyText(cents: row.amount)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .strikethrough(row.isVoided)
                }
                .width(min: 84, ideal: 110)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                TransactionActions(ids: Array(ids))
            } primaryAction: { ids in
                selection = ids
                showDetails = true
            }
            footer(rows)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search merchants, bank text, notes", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .frame(minWidth: 160, maxWidth: 360)
                Spacer(minLength: 0)
                Button {
                    showDetails.toggle()
                } label: {
                    Label(showDetails ? "Hide Details" : "Show Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide transaction details")
            }
            // Scrolls sideways instead of forcing the window wider when space is tight.
            ScrollView(.horizontal, showsIndicators: false) {
                filterPickers
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var filterPickers: some View {
        HStack(spacing: 10) {
            PeriodPicker(choice: $period, customStart: $customStart, customEnd: $customEnd)
            PersonPicker(personID: $personID)
            Picker("Account", selection: $accountID) {
                Text("All accounts").tag(UUID?.none)
                ForEach(runtime.ledger.accounts) { account in
                    Text(account.name).tag(UUID?.some(account.id))
                }
            }
            .frame(width: 210)
            Picker("Show", selection: $filter) {
                Text("All transactions").tag(TransactionFilter.all)
                Text("Needs review").tag(TransactionFilter.needsReview)
                Text("Filed by Apple Intelligence").tag(TransactionFilter.aiFiled)
                Text("Spending").tag(TransactionFilter.spending)
                Text("Income").tag(TransactionFilter.income)
                Text("Transfers").tag(TransactionFilter.transfers)
                Text("Pending").tag(TransactionFilter.pending)
                Text("Removed").tag(TransactionFilter.removed)
                Divider()
                ForEach(runtime.ledger.categories) { category in
                    Text(category.name).tag(TransactionFilter.category(category.id))
                }
            }
            .frame(width: 210)
        }
    }

    private func focusBanner(_ focus: TransactionsFocus) -> some View {
        HStack {
            Label("Showing \(focus.ids.count) transactions: \(focus.title)", systemImage: "line.3.horizontal.decrease.circle")
            Spacer()
            Button("Show All") { runtime.transactionsFocus = nil }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.08))
    }

    private func footer(_ rows: [TransactionRow]) -> some View {
        let counted = rows.filter { !$0.isVoided && !$0.isPending }
        let moneyIn = counted.filter { $0.amount > 0 }.reduce(Cents(0)) { $0 + $1.amount }
        let moneyOut = counted.filter { $0.amount < 0 }.reduce(Cents(0)) { $0 + $1.amount }
        let summary = "\(rows.count) transactions · money in \(Money.format(moneyIn)) · money out \(Money.format(moneyOut))"
        return HStack {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Export CSV…") { exportCSV(rows) }
                .disabled(rows.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func exportCSV(_ rows: [TransactionRow]) {
        let text = CSVExport.transactions(rows.map(\.id), ledger: runtime.ledger)
        SavePanel.save(text: text, suggestedName: "EchoLedger transactions.csv", type: .commaSeparatedText, runtime: runtime)
    }

    private func filteredRows() -> [TransactionRow] {
        let ledger = runtime.ledger
        let span = period.span(today: runtime.today, earliest: ledger.transactions.values.map(\.date).min(),
                               customStart: customStart, customEnd: customEnd)
        let focusIDs = runtime.transactionsFocus?.ids
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var accounts: [UUID: Account] = [:]
        for account in ledger.accounts { accounts[account.id] = account }
        var categories: [UUID: LedgerCategory] = [:]
        for category in ledger.categories { categories[category.id] = category }

        var rows: [TransactionRow] = []
        for transaction in ledger.transactions.values {
            if transaction.supersededBy != nil { continue }
            if let focusIDs {
                guard focusIDs.contains(transaction.id) else { continue }
            } else {
                guard span.contains(transaction.date) else { continue }
            }
            let account = accounts[transaction.accountID]
            if let accountID, transaction.accountID != accountID { continue }
            if let personID, let owner = account?.personID, owner != personID { continue }
            switch filter {
            case .all: if transaction.voided { continue }
            case .needsReview: if !transaction.needsReview { continue }
            case .aiFiled: if transaction.method != .ai || transaction.review != .automatic || transaction.voided { continue }
            case .spending: if transaction.kind != .expense || transaction.voided { continue }
            case .income: if transaction.kind != .income || transaction.voided { continue }
            case .transfers: if transaction.kind != .transfer || transaction.voided { continue }
            case .pending: if transaction.status != .pending || transaction.voided { continue }
            case .removed: if !transaction.voided { continue }
            case .category(let id): if transaction.categoryID != id || transaction.voided { continue }
            }
            let merchant = ReportEngine.merchantIdentity(transaction, ledger: ledger).name
            if !needle.isEmpty {
                let haystack = (merchant + " " + transaction.rawDescription + " " + transaction.note).lowercased()
                if !haystack.contains(needle) { continue }
            }
            let category = transaction.categoryID.flatMap { categories[$0] }
            let categoryName: String
            switch transaction.kind {
            case .transfer: categoryName = "Transfer"
            case .unknown:
                if let suggestion = transaction.suggestion {
                    categoryName = suggestion.source == .ai ? "Apple Intelligence suggests" : "Suggested"
                } else {
                    categoryName = "Needs review"
                }
            default: categoryName = category?.name ?? "Uncategorized"
            }
            rows.append(TransactionRow(id: transaction.id, date: transaction.date, merchant: merchant,
                                       detail: transaction.rawDescription, categoryName: categoryName,
                                       colorIndex: category?.colorIndex ?? -1, kind: transaction.kind,
                                       accountName: account?.name ?? "", amount: transaction.amount,
                                       isPending: transaction.status == .pending, needsReview: transaction.needsReview,
                                       isVoided: transaction.voided, isManual: transaction.method == .manual))
        }
        return rows.sorted(using: sortOrder)
    }
}

struct MerchantCell: View {
    let row: TransactionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(row.merchant)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if row.isPending { Badge(text: "Pending", color: .orange) }
                if row.kind == .expense && row.amount > 0 { Badge(text: "Refund", color: Theme.income) }
                if row.isVoided { Badge(text: "Removed", color: .secondary) }
            }
            Text(row.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Bulk actions for one or more transactions (context menu and inspector).
struct TransactionActions: View {
    @Environment(LedgerRuntime.self) private var runtime
    let ids: [UUID]

    var body: some View {
        if !ids.isEmpty {
            Menu("Set Spending Category") {
                ForEach(runtime.ledger.categories.filter { $0.group == .expense }) { category in
                    Button(category.name) { set(.expense, category.id) }
                }
            }
            Menu("Set Income Category") {
                ForEach(runtime.ledger.categories.filter { $0.group == .income }) { category in
                    Button(category.name) { set(.income, category.id) }
                }
            }
            Button("Mark as Transfer") { set(.transfer, nil) }
            Divider()
            Button("Back to Automatic Matching") {
                let selected = ids
                runtime.commit { $0.resetToAutomatic(selected) }
            }
            if ids.allSatisfy({ runtime.ledger.transactions[$0]?.voided == true }) {
                Button("Restore") {
                    let selected = ids
                    runtime.commit { $0.setVoided(false, ids: selected, label: "Restore") }
                }
            } else {
                Button("Remove from Records") {
                    let selected = ids
                    runtime.commit { $0.setVoided(true, ids: selected, label: "Remove") }
                }
            }
        }
    }

    private func set(_ kind: TransactionKind, _ categoryID: UUID?) {
        let selected = ids
        let label = kind == .transfer ? "Mark as transfer" : "Set category"
        runtime.commit { $0.classify(selected, merchantName: nil, kind: kind, categoryID: categoryID, remember: false, label: label) }
    }
}

/// Details and editing for the selected transaction(s).
struct TransactionInspector: View {
    @Environment(LedgerRuntime.self) private var runtime
    let ids: [UUID]

    var body: some View {
        let transactions = ids.compactMap { runtime.ledger.transactions[$0] }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if transactions.count == 1, let transaction = transactions.first {
                    SingleTransactionDetail(transaction: transaction)
                        .id(transaction.id.uuidString + "\(runtime.revision)")
                } else if transactions.count > 1 {
                    let total = transactions.reduce(Cents(0)) { $0 + $1.amount }
                    Text("\(transactions.count) selected")
                        .font(.title2.weight(.semibold))
                    LabeledContent("Total") { MoneyText(cents: total) }
                    Caption("Use the actions below, or right-click in the table.")
                    VStack(alignment: .leading, spacing: 8) {
                        TransactionActions(ids: ids)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.link)
                } else {
                    ContentUnavailableView("No selection", systemImage: "list.bullet.rectangle",
                                           description: Text("Select a transaction to see where it came from and why it was filed that way."))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SingleTransactionDetail: View {
    @Environment(LedgerRuntime.self) private var runtime
    let transaction: LedgerTransaction

    @State private var merchantName = ""
    @State private var kind: TransactionKind = .expense
    @State private var categoryID: UUID?
    @State private var remember = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ReportEngine.merchantIdentity(transaction, ledger: runtime.ledger).name)
                    .font(.title2.weight(.semibold))
                MoneyText(cents: transaction.amount)
                    .font(.title3)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let suggestion = transaction.suggestion {
                suggestionBox(suggestion)
            }
            editBox
            whyBox
            explainBox
            sourceBox
            noteBox
            if transaction.method == .manual {
                Button("Back to Automatic Matching") {
                    let id = transaction.id
                    runtime.commit { $0.resetToAutomatic([id]) }
                }
            }
            Button(transaction.voided ? "Restore" : "Remove from Records") {
                let id = transaction.id
                let voided = !transaction.voided
                runtime.commit { $0.setVoided(voided, ids: [id], label: voided ? "Remove" : "Restore") }
            }
            .foregroundStyle(transaction.voided ? Color.primary : Color.red)
        }
        .onAppear(perform: load)
    }

    private var kindGroup: CategoryGroup {
        kind == .income ? CategoryGroup.income : CategoryGroup.expense
    }

    private var subtitle: String {
        var parts = [DateText.medium(transaction.date)]
        if let posted = transaction.postedDate, posted != transaction.date { parts.append("posted \(DateText.medium(posted))") }
        parts.append(runtime.ledger.account(transaction.accountID)?.name ?? "")
        if transaction.status == .pending { parts.append("pending, not counted yet") }
        return parts.joined(separator: " · ")
    }

    private func suggestionBox(_ suggestion: Suggestion) -> some View {
        let category = runtime.ledger.category(suggestion.categoryID)?.name ?? suggestion.kind.label
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(suggestion.source == .ai ? "Apple Intelligence suggests" : "Suggested", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text("\(suggestion.merchantName.map { "\($0) · " } ?? "")\(category)")
                    .font(.callout.weight(.medium))
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Approve") {
                    let id = transaction.id
                    let keep = remember
                    runtime.commit { $0.approveSuggestions([id], remember: keep) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editBox: some View {
        GroupBox("Merchant and category") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Merchant", text: $merchantName)
                Picker("Kind", selection: $kind) {
                    Text("Spending").tag(TransactionKind.expense)
                    Text("Income").tag(TransactionKind.income)
                    Text("Transfer").tag(TransactionKind.transfer)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if kind != .transfer {
                    Picker("Category", selection: $categoryID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(runtime.ledger.categories.filter { $0.group == kindGroup }) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                }
                Toggle("Remember for similar transactions", isOn: $remember)
                HStack {
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(kind != .transfer && categoryID == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private var whyBox: some View {
        GroupBox("Why it's filed this way") {
            VStack(alignment: .leading, spacing: 6) {
                Label(transaction.method.label, systemImage: "info.circle")
                    .font(.callout.weight(.medium))
                Text(transaction.evidence.isEmpty ? "Not matched yet." : transaction.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if transaction.method == .ai, transaction.review == .automatic {
                    HStack {
                        Button("Looks Right") {
                            let id = transaction.id
                            runtime.commit { $0.confirmAIFiled([id]) }
                        }
                        Caption("Keeps this filing and teaches EchoLedger. To change it, edit above.")
                    }
                }
                if let partnerID = transaction.transferPairID, let partner = runtime.ledger.transactions[partnerID] {
                    Text("Other side: \(partner.rawDescription) in \(runtime.ledger.account(partner.accountID)?.name ?? "") on \(DateText.medium(partner.date)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var explainBox: some View {
        let intelligence = runtime.intelligence
        let explanation = intelligence.explanations[transaction.id]
        return GroupBox("What is this charge?") {
            VStack(alignment: .leading, spacing: 8) {
                if let explanation {
                    Text(explanation.text)
                        .font(.callout)
                        .foregroundStyle(explanation.failed ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if !explanation.failed {
                        if !explanation.isGrounded {
                            Label("It mentions a number that isn't on this charge, so treat it with care.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if !explanation.isConfident {
                            Caption("Apple Intelligence isn't sure about this one. Check a receipt or your bank's app.")
                        }
                    }
                }
                HStack {
                    Button {
                        let current = transaction
                        Task { await intelligence.explain(current, runtime: runtime) }
                    } label: {
                        Label(explanation == nil ? "Ask Apple Intelligence" : "Ask Again", systemImage: "sparkles")
                    }
                    .disabled(!intelligence.isReady || intelligence.explaining.contains(transaction.id))
                    if intelligence.explaining.contains(transaction.id) {
                        ProgressView().controlSize(.small)
                    }
                }
                Caption(intelligence.unavailableReason ?? "Answered on this Mac from the bank's text. Nothing is sent anywhere.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceBox: some View {
        GroupBox("From your bank") {
            VStack(alignment: .leading, spacing: 6) {
                Text(transaction.rawDescription)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let batch = runtime.ledger.batches.first(where: { $0.id == transaction.batchID }) {
                    Caption("\(batch.fileName), line \(transaction.sourceLine), imported \(batch.importedAt.formatted(date: .abbreviated, time: .omitted))")
                }
                if let line = runtime.sourceLine(for: transaction) {
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let bankCategory = transaction.bankCategory {
                    Caption("Bank's category: \(bankCategory)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noteBox: some View {
        GroupBox("Note") {
            TextField("Add a note", text: $note, axis: .vertical)
                .lineLimit(1...4)
                .onSubmit(saveNote)
            HStack {
                Spacer()
                Button("Save Note", action: saveNote)
                    .disabled(note == transaction.note)
            }
        }
    }

    private func load() {
        merchantName = transaction.merchantID.flatMap { runtime.ledger.merchants[$0]?.name }
            ?? transaction.suggestion?.merchantName ?? MerchantText(transaction.rawDescription).displayName
        switch transaction.kind {
        case .unknown:
            kind = transaction.suggestion?.kind ?? (transaction.amount > 0 ? .income : .expense)
            if kind == .unknown { kind = .expense }
        default:
            kind = transaction.kind
        }
        categoryID = transaction.categoryID ?? transaction.suggestion?.categoryID
        note = transaction.note
    }

    private func save() {
        let id = transaction.id
        let name = merchantName
        let chosenKind = kind
        let chosenCategory = kind == .transfer ? nil : categoryID
        let keep = remember
        runtime.commit { $0.classify([id], merchantName: name, kind: chosenKind, categoryID: chosenCategory, remember: keep, label: "Edit \(name)") }
    }

    private func saveNote() {
        let id = transaction.id
        let text = note
        runtime.commit { $0.setNote(text, for: id) }
    }
}

/// Native save panels for exports.
@MainActor
enum SavePanel {
    static func choose(suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func save(text: String, suggestedName: String, type: UTType, runtime: LedgerRuntime) {
        guard let url = choose(suggestedName: suggestedName, type: type) else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            runtime.statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            runtime.errorMessage = "Couldn't save the file: \(error.localizedDescription)"
        }
    }
}
