import EchoLedgerCore
import SwiftUI

struct ReviewView: View {
    @Environment(LedgerRuntime.self) private var runtime
    @State private var ruleDraft: RuleDraft?

    var body: some View {
        let groups = ReviewQueue.groups(runtime.ledger)
        let filed = ReviewQueue.aiFiledGroups(runtime.ledger)
        let stale = ReviewQueue.stalePending(runtime.ledger, today: runtime.today)
        let suggestions = RuleSuggester.suggestions(runtime.ledger)
        Page(title: "Review", subtitle: "Decide what EchoLedger couldn't. Identical bank text is grouped, so one decision covers every matching transaction.") {
            if groups.isEmpty && filed.isEmpty && stale.isEmpty && suggestions.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(Theme.accent)
                    Text("All caught up").font(Theme.heading(28))
                    Text("Your transactions are ready to explore. New imports that need you will appear here.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("View Reports") { runtime.section = .reports }.buttonStyle(.borderedProminent)
                        Button("Import Files") { runtime.section = .importFiles }
                    }.controlSize(.large)
                }.frame(maxWidth: .infinity, minHeight: 300)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if !groups.isEmpty {
                intelligenceBar(groups)
                ForEach(groups) { group in
                    ReviewGroupCard(group: group)
                        .id(group.id + "|" + (group.suggestion?.reason ?? ""))
                }
            }
            if !filed.isEmpty {
                AIFiledSection(groups: filed)
            }
            if !stale.isEmpty {
                StalePendingSection(transactions: stale)
            }
            if !suggestions.isEmpty {
                RuleSuggestionsSection(suggestions: suggestions) { suggestion in
                    let categoryName = runtime.ledger.category(suggestion.categoryID)?.name
                    ruleDraft = RuleDraft(rule: suggestion.makeRule(categoryName: categoryName), isNew: true)
                }
            }
        }
        .sheet(item: $ruleDraft) { draft in
            RuleEditorSheet(draft: draft)
        }
    }

    private func intelligenceBar(_ groups: [ReviewGroup]) -> some View {
        let intelligence = runtime.intelligence
        let count = groups.reduce(0) { $0 + $1.count }
        return GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(count) transaction\(count == 1 ? "" : "s") in \(groups.count) group\(groups.count == 1 ? "" : "s") need you")
                        .font(.headline)
                    if intelligence.isSuggesting {
                        Caption(intelligence.suggestionProgress)
                    } else if let reason = intelligence.unavailableReason {
                        Caption(reason)
                    } else if intelligence.autoFile {
                        Caption("Apple Intelligence can file these on this Mac. Everything it files is marked so you can check it, and Undo reverses the whole run.")
                    } else {
                        Caption("Apple Intelligence can suggest a merchant and category for each group, on this Mac. You approve every one.")
                    }
                }
                Spacer()
                if intelligence.isSuggesting {
                    ProgressView().controlSize(.small)
                    Button("Stop") { intelligence.stop() }
                } else {
                    Button {
                        let open = groups.filter { $0.suggestion?.source != .ai }
                        intelligence.start(open, runtime: runtime)
                    } label: {
                        Label(intelligence.autoFile ? "File with Apple Intelligence" : "Suggest with Apple Intelligence", systemImage: "sparkles")
                    }
                    .disabled(!intelligence.isReady)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// One group of transactions that share bank text.
struct ReviewGroupCard: View {
    @Environment(LedgerRuntime.self) private var runtime
    let group: ReviewGroup
    /// False when the group's suggestion only fills in the editor (Apple Intelligence's filing
    /// being changed).
    var showsSuggestion = true
    var onSave: (() -> Void)?

    @State private var merchantName = ""
    @State private var kind: TransactionKind = .expense
    @State private var categoryID: UUID?
    @State private var zelleChoice: ZelleChoice?
    @State private var remember = true
    @State private var loaded = false

    /// Zelle never gets a guess: the bank text doesn't say why the money moved, so you choose.
    private var isZelle: Bool { ZelleActivity.isZelle(group.example) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                header
                if showsSuggestion, let suggestion = group.suggestion {
                    suggestionBanner(suggestion)
                }
                editor
                HStack {
                    Toggle("Remember for similar transactions", isOn: $remember)
                    Spacer()
                    Button("Show Transactions") {
                        runtime.showTransactions(TransactionsFocus(title: group.displayName, ids: Set(group.transactionIDs)))
                    }
                    if showsSuggestion, runtime.intelligence.isReady, group.suggestion?.source != .ai {
                        Button {
                            runtime.intelligence.start([group], runtime: runtime)
                        } label: {
                            Label("Ask", systemImage: "sparkles")
                        }
                        .disabled(runtime.intelligence.isSuggesting)
                        .help("Ask Apple Intelligence about this group")
                    }
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
                Caption(rememberExplanation)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.headline)
                Text(group.example)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(cents: group.total)
                .font(.title3.weight(.semibold))
        }
    }

    private var detailText: String {
        let count = "\(group.count) transaction\(group.count == 1 ? "" : "s")"
        let dates = group.firstDate == group.lastDate ? DateText.medium(group.firstDate)
            : "\(DateText.medium(group.firstDate)) – \(DateText.medium(group.lastDate))"
        return "\(count) · \(dates) · \(group.accountNames.joined(separator: ", "))"
    }

    private func suggestionBanner(_ suggestion: Suggestion) -> some View {
        let categoryName = runtime.ledger.category(suggestion.categoryID)?.name ?? suggestion.kind.label
        let source = suggestion.source == .ai ? "Apple Intelligence suggests" : "Suggested"
        let merchant = suggestion.merchantName.map { "\($0) · " } ?? ""
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.source == .ai ? "sparkles" : "lightbulb")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(source): \(merchant)\(categoryName)")
                    .font(.callout.weight(.medium))
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Approve") {
                let ids = group.transactionIDs
                let keep = remember
                runtime.commit { $0.approveSuggestions(ids, remember: keep) }
            }
        }
        .padding(10)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var editor: some View {
        if isZelle { zelleEditor } else { standardEditor }
    }

    private var zelleEditor: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Name", text: $merchantName)
                    .frame(minWidth: 160, maxWidth: 220)
                Picker("What was this for?", selection: $zelleChoice) {
                    Text("What was this for?").tag(ZelleChoice?.none)
                    ForEach(ZelleChoice.choices(moneyIn: group.isMoneyIn)) { choice in
                        Text(choice.label).tag(ZelleChoice?.some(choice))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                if let choice = zelleChoice, choice.needsCategory {
                    Picker("Category", selection: $categoryID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(zelleCategoryChoices(choice)) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
        }
        .onChange(of: zelleChoice) { _, _ in categoryID = nil }
    }

    private func zelleCategoryChoices(_ choice: ZelleChoice) -> [LedgerCategory] {
        runtime.ledger.categories.filter { $0.group == choice.categoryGroup }
    }

    private var standardEditor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("Merchant", text: $merchantName)
                .frame(minWidth: 180, maxWidth: 260)
            Picker("Kind", selection: $kind) {
                Text("Spending").tag(TransactionKind.expense)
                Text("Income").tag(TransactionKind.income)
                Text("Transfer").tag(TransactionKind.transfer)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            if kind != .transfer {
                Picker("Category", selection: $categoryID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(categoryChoices) { category in
                        Text(category.name).tag(UUID?.some(category.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }
        .onChange(of: kind) { _, newKind in
            if let current = runtime.ledger.category(categoryID), current.group != categoryGroup(for: newKind) {
                categoryID = nil
            }
        }
    }

    private func categoryGroup(for kind: TransactionKind) -> CategoryGroup {
        kind == .income ? .income : .expense
    }

    private var categoryChoices: [LedgerCategory] {
        runtime.ledger.categories.filter { $0.group == categoryGroup(for: kind) }
    }

    private var canSave: Bool {
        if isZelle {
            guard let choice = zelleChoice else { return false }
            return !choice.needsCategory || categoryID != nil
        }
        return kind == .transfer || categoryID != nil
    }

    private var rememberExplanation: String {
        if remember {
            return "EchoLedger will file this bank text the same way from now on, including in future imports. You can change it under Rules & Merchants."
        }
        return "Only these transactions change."
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if isZelle {
            // Nothing is preselected for a Zelle.
            merchantName = group.suggestion?.merchantName ?? group.displayName
            return
        }
        if let suggestion = group.suggestion {
            merchantName = suggestion.merchantName ?? group.displayName
            kind = suggestion.kind == .unknown ? (group.isMoneyIn ? .income : .expense) : suggestion.kind
            categoryID = suggestion.categoryID
        } else {
            merchantName = group.displayName
            kind = group.isMoneyIn ? .income : .expense
            categoryID = nil
        }
    }

    private func save() {
        let ids = group.transactionIDs
        let name = merchantName
        if isZelle {
            guard let choice = zelleChoice else { return }
            let chosenCategory = choice.needsCategory ? categoryID : nil
            let keep = remember
            runtime.commit {
                $0.classifyZelle(ids, merchantName: name, choice: choice, categoryID: chosenCategory, remember: keep,
                                 label: "Review \(name)")
            }
            onSave?()
            return
        }
        let chosenKind = kind
        let chosenCategory = kind == .transfer ? nil : categoryID
        let keep = remember
        runtime.commit {
            $0.classify(ids, merchantName: name, kind: chosenKind, categoryID: chosenCategory, remember: keep, label: "Review \(name)")
        }
        onSave?()
    }
}

/// What Apple Intelligence filed on its own, for you to check. It's already counted in reports.
struct AIFiledSection: View {
    @Environment(LedgerRuntime.self) private var runtime
    let groups: [ReviewGroup]
    @State private var editingID: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Filed by Apple Intelligence", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Button("All Look Right") {
                        let ids = groups.flatMap(\.transactionIDs)
                        runtime.commit { $0.confirmAIFiled(ids) }
                    }
                }
                Caption("Apple Intelligence filed these on this Mac and they're counted in your reports. Looks Right keeps the filing and teaches EchoLedger; Change lets you file it yourself, and Apple Intelligence won't file that bank text again.")
                ForEach(groups) { group in
                    Divider()
                    if editingID == group.id {
                        ReviewGroupCard(group: editable(group), showsSuggestion: false, onSave: { editingID = nil })
                        Button("Cancel") { editingID = nil }
                    } else {
                        row(group)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func filedTransaction(_ group: ReviewGroup) -> LedgerTransaction? {
        group.transactionIDs.first.flatMap { runtime.ledger.transactions[$0] }
    }

    private func row(_ group: ReviewGroup) -> some View {
        let transaction = filedTransaction(group)
        let category = runtime.ledger.category(transaction?.categoryID)?.name ?? transaction?.kind.label ?? ""
        let reason = transaction.flatMap { runtime.ledger.aiFilingKey(for: MerchantText($0.rawDescription).key) }
            .flatMap { runtime.ledger.aiFilings[$0]?.reason } ?? ""
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(group.displayName) → \(category)")
                    .font(.callout.weight(.medium))
                Text(group.example)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                MoneyText(cents: group.total)
                Text("\(group.count) transaction\(group.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Looks Right") {
                let ids = group.transactionIDs
                runtime.commit { $0.confirmAIFiled(ids) }
            }
            .buttonStyle(.borderedProminent)
            Button("Change…") { editingID = group.id }
        }
    }

    /// The group with its current filing as the starting point for the editor.
    private func editable(_ group: ReviewGroup) -> ReviewGroup {
        var copy = group
        if let transaction = filedTransaction(group) {
            copy.suggestion = Suggestion(merchantName: runtime.ledger.merchant(transaction.merchantID)?.name,
                                         categoryID: transaction.categoryID, kind: transaction.kind, source: .ai,
                                         reason: "Filed by Apple Intelligence")
        }
        return copy
    }
}

/// Pending charges that probably never posted.
struct StalePendingSection: View {
    @Environment(LedgerRuntime.self) private var runtime
    let transactions: [LedgerTransaction]

    var body: some View {
        GroupBox("Pending charges that may never have posted") {
            VStack(alignment: .leading, spacing: 10) {
                Caption("These are still pending, but newer files for the same account don't include them (or they're over two weeks old). Pending charges never count in totals. Remove the ones that disappeared.")
                ForEach(transactions) { transaction in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.rawDescription)
                            Text("\(DateText.medium(transaction.date)) · \(runtime.ledger.account(transaction.accountID)?.name ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        MoneyText(cents: transaction.amount)
                        Button("Remove") {
                            runtime.commit { $0.setVoided(true, ids: [transaction.id], label: "Remove pending charge") }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// Rules proposed from corrections you keep making.
struct RuleSuggestionsSection: View {
    @Environment(LedgerRuntime.self) private var runtime
    let suggestions: [RuleSuggestion]
    let create: (RuleSuggestion) -> Void

    var body: some View {
        GroupBox("Suggested rules") {
            VStack(alignment: .leading, spacing: 12) {
                Caption("You've corrected these the same way more than once. A rule would do it for you, including in future imports.")
                ForEach(suggestions) { suggestion in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(suggestion))
                                .font(.callout.weight(.medium))
                            Text(detail(suggestion))
                                .font(.caption)
                                .foregroundStyle(suggestion.conflictIDs.isEmpty ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Button("Review Rule…") { create(suggestion) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func title(_ suggestion: RuleSuggestion) -> String {
        let category = runtime.ledger.category(suggestion.categoryID)?.name ?? suggestion.kind.label
        let merchant = suggestion.merchantName.map { "\($0), " } ?? ""
        return "Text contains “\(suggestion.pattern)” → \(merchant)\(category)"
    }

    private func detail(_ suggestion: RuleSuggestion) -> String {
        var text = "Based on \(suggestion.exampleIDs.count) corrections · would match \(suggestion.matchCount) transactions"
        if !suggestion.conflictIDs.isEmpty {
            text += " · \(suggestion.conflictIDs.count) you filed differently (they won't change)"
        }
        return text
    }
}
