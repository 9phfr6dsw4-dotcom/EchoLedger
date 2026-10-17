import EchoLedgerCore
import SwiftUI

struct RuleDraft: Identifiable {
    let id = UUID()
    var rule: Rule
    var isNew: Bool
}

struct MerchantDraft: Identifiable {
    let id: UUID
}

struct RulesView: View {
    @Environment(LedgerRuntime.self) private var runtime
    @State private var ruleDraft: RuleDraft?
    @State private var merchantDraft: MerchantDraft?
    @State private var merchantSearch = ""

    var body: some View {
        Page(title: "Rules & Merchants", subtitle: "Your rules run first, top to bottom, and the first match wins. Then merchants you've taught EchoLedger, then the built-in rules and merchant list.") {
            yourRules
            builtInRules
            merchants
        }
        .sheet(item: $ruleDraft) { draft in
            RuleEditorSheet(draft: draft)
        }
        .sheet(item: $merchantDraft) { draft in
            MerchantEditorSheet(merchantID: draft.id)
        }
    }

    private var yourRules: some View {
        let rules = runtime.ledger.orderedRules
        return GroupBox("Your rules") {
            VStack(alignment: .leading, spacing: 10) {
                if rules.isEmpty {
                    Caption("No rules yet. Make one here, or approve a suggested rule in Review. Corrections with “Remember” also teach EchoLedger without a rule.")
                }
                ForEach(rules.indices, id: \.self) { index in
                    RuleRow(rule: rules[index], index: index, count: rules.count) {
                        ruleDraft = RuleDraft(rule: rules[index], isNew: false)
                    }
                    Divider()
                }
                HStack {
                    Button("New Rule…") {
                        ruleDraft = RuleDraft(rule: Rule(name: "", match: .contains, pattern: ""), isNew: true)
                    }
                    Spacer()
                    Caption("Rules never change transactions you set by hand.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var builtInRules: some View {
        GroupBox("Built-in rules") {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Generic bank wording EchoLedger understands. Turn one off if it doesn't fit how you bank.")
                ForEach(BuiltInKnowledge.rules) { rule in
                    let disabled = runtime.ledger.settings.disabledBuiltInRules.contains(rule.id)
                    Toggle(isOn: Binding(get: { !disabled }, set: { enabled in
                        runtime.commit { $0.setBuiltInRule(rule.id, enabled: enabled) }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name)
                            Text(builtInSummary(rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Caption("Plus \(BuiltInKnowledge.merchants.count) well-known merchants (Starbucks, Amazon, Safeway, Netflix…) with a default category. Your own choices always win.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func builtInSummary(_ rule: BuiltInRule) -> String {
        let outcome: String
        if let category = rule.categoryName {
            outcome = "\(rule.kind.label): \(category)"
        } else {
            outcome = rule.kind.label
        }
        let direction = rule.direction == .any ? "" : " · \(rule.direction.label.lowercased())"
        let accounts = rule.accountTypes.isEmpty ? "" : " · " + rule.accountTypes.map { $0.label.lowercased() }.joined(separator: ", ") + " accounts"
        return outcome + direction + accounts
    }

    private var merchants: some View {
        let used = Dictionary(grouping: runtime.ledger.transactions.values.filter { $0.isActive && $0.merchantID != nil }) { $0.merchantID! }
        let needle = merchantSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let list = runtime.ledger.merchants.values
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return GroupBox("Merchants") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search merchants", text: $merchantSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                if list.isEmpty {
                    Caption("Merchants appear here as you import and review transactions.")
                }
                ForEach(list.prefix(300)) { merchant in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(merchant.name)
                            Text(merchantDetail(merchant, count: used[merchant.id]?.count ?? 0))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { merchantDraft = MerchantDraft(id: merchant.id) }
                    }
                    Divider()
                }
                HStack {
                    Button("Remove Unused Merchants") { runtime.commit { $0.pruneUnusedMerchants() } }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func merchantDetail(_ merchant: Merchant, count: Int) -> String {
        var parts = ["\(count) transaction\(count == 1 ? "" : "s")"]
        if merchant.kind == .transfer {
            parts.append("always a transfer")
        } else if let category = runtime.ledger.category(merchant.categoryID) {
            parts.append("always \(category.name)")
        }
        if !merchant.keys.isEmpty {
            parts.append("recognizes \(merchant.keys.count) bank text\(merchant.keys.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

struct RuleRow: View {
    @Environment(LedgerRuntime.self) private var runtime
    let rule: Rule
    let index: Int
    let count: Int
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { value in
                var copy = rule
                copy.isEnabled = value
                runtime.commit { $0.updateRule(copy) }
            }))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                    .foregroundStyle(rule.isEnabled ? Color.primary : Color.secondary)
                Text(RuleText.summary(rule, ledger: runtime.ledger))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                move(by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .help("Move up (checked earlier)")
            Button {
                move(by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index == count - 1)
            .help("Move down")
            Button("Edit…", action: edit)
        }
        .buttonStyle(.borderless)
    }

    private func move(by offset: Int) {
        var order = runtime.ledger.orderedRules.map(\.id)
        guard let position = order.firstIndex(of: rule.id) else { return }
        let target = position + offset
        guard target >= 0, target < order.count else { return }
        order.swapAt(position, target)
        let newOrder = order
        runtime.commit { $0.setRuleOrder(newOrder) }
    }
}

enum RuleText {
    static func summary(_ rule: Rule, ledger: Ledger) -> String {
        var condition = "Text \(rule.match.label) “\(rule.pattern)”"
        if !rule.accountIDs.isEmpty {
            let names = rule.accountIDs.compactMap { ledger.account($0)?.name }
            condition += " in \(names.joined(separator: ", "))"
        }
        if rule.direction != .any { condition += ", \(rule.direction.label.lowercased())" }
        if let minimum = rule.minimumAmount { condition += ", at least \(Money.format(minimum))" }
        if let maximum = rule.maximumAmount { condition += ", at most \(Money.format(maximum))" }
        var outcome: [String] = []
        if let merchant = rule.merchantName, !merchant.isEmpty { outcome.append(merchant) }
        if let category = ledger.category(rule.categoryID) {
            outcome.append(category.name)
        } else if let kind = rule.kind {
            outcome.append(kind.label)
        }
        return condition + " → " + (outcome.isEmpty ? "nothing" : outcome.joined(separator: " · "))
    }
}

/// Create or change a rule, seeing exactly what it would do before saving.
struct RuleEditorSheet: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let draft: RuleDraft

    enum Outcome: String, CaseIterable, Identifiable {
        case keep, expense, income, transfer
        var id: String { rawValue }
        var label: String {
            switch self {
            case .keep: return "Merchant only"
            case .expense: return "Spending"
            case .income: return "Income"
            case .transfer: return "Transfer"
            }
        }
    }

    @State private var name = ""
    @State private var match: TextMatch = .contains
    @State private var pattern = ""
    @State private var accountID: UUID?
    @State private var direction: AmountDirection = .any
    @State private var minimumText = ""
    @State private var maximumText = ""
    @State private var merchantName = ""
    @State private var outcome: Outcome = .expense
    @State private var categoryID: UUID?
    @State private var loaded = false

    var body: some View {
        let rule = builtRule
        let preview = rule.pattern.isEmpty ? nil : RulePreview.compute(rule, ledger: runtime.ledger, position: position)
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: draft.isNew ? "New rule" : "Edit rule",
                       subtitle: "When a transaction matches, EchoLedger files it this way. Rules apply to imports from now on and to everything you haven't set by hand.")
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Car payment"))
                Section("When") {
                    Picker("Bank text", selection: $match) {
                        ForEach(TextMatch.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Text", text: $pattern, prompt: Text("e.g. AUTOLOAN PAYMENT"))
                    if let regexError {
                        ErrorLabel(message: regexError)
                    }
                    Picker("Account", selection: $accountID) {
                        Text("Any account").tag(UUID?.none)
                        ForEach(runtime.ledger.accounts) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                    Picker("Direction", selection: $direction) {
                        ForEach(AmountDirection.allCases) { Text($0.label).tag($0) }
                    }
                    HStack {
                        TextField("At least (optional)", text: $minimumText)
                        TextField("At most (optional)", text: $maximumText)
                    }
                }
                Section("Then") {
                    TextField("Merchant (optional)", text: $merchantName)
                    Picker("File as", selection: $outcome) {
                        ForEach(Outcome.allCases) { Text($0.label).tag($0) }
                    }
                    if outcome == .expense || outcome == .income {
                        Picker("Category", selection: $categoryID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(runtime.ledger.categories.filter { $0.group == outcomeGroup }) { category in
                                Text(category.name).tag(UUID?.some(category.id))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let preview {
                RulePreviewBox(preview: preview)
            }
            HStack {
                if !draft.isNew {
                    Button("Delete Rule", role: .destructive) {
                        let id = draft.rule.id
                        runtime.commit { $0.deleteRule(id) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(draft.isNew ? "Add Rule" : "Save") { save(rule) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 640)
        .onAppear(perform: load)
    }

    private var outcomeGroup: CategoryGroup {
        outcome == .income ? CategoryGroup.income : CategoryGroup.expense
    }

    private var position: Int {
        if draft.isNew { return 0 }
        return runtime.ledger.orderedRules.firstIndex { $0.id == draft.rule.id } ?? 0
    }

    private var regexError: String? {
        guard match == .regex, !pattern.isEmpty else { return nil }
        return (try? NSRegularExpression(pattern: pattern)) == nil ? "That pattern isn't valid." : nil
    }

    private var canSave: Bool {
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty, regexError == nil else { return false }
        switch outcome {
        case .keep: return !merchantName.trimmingCharacters(in: .whitespaces).isEmpty
        case .transfer: return true
        case .expense, .income: return categoryID != nil
        }
    }

    private var builtRule: Rule {
        var rule = draft.rule
        rule.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? pattern : name
        rule.match = match
        rule.pattern = pattern.trimmingCharacters(in: .whitespaces)
        rule.accountIDs = accountID.map { [$0] } ?? []
        rule.direction = direction
        rule.minimumAmount = Money.parseCents(minimumText).map { Cents($0.magnitude) }
        rule.maximumAmount = Money.parseCents(maximumText).map { Cents($0.magnitude) }
        let merchant = merchantName.trimmingCharacters(in: .whitespaces)
        rule.merchantName = merchant.isEmpty ? nil : merchant
        switch outcome {
        case .keep:
            rule.kind = nil
            rule.categoryID = nil
        case .transfer:
            rule.kind = .transfer
            rule.categoryID = nil
        case .expense, .income:
            rule.kind = outcome == .income ? .income : .expense
            rule.categoryID = categoryID
        }
        return rule
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let rule = draft.rule
        name = rule.name
        match = rule.match
        pattern = rule.pattern
        accountID = rule.accountIDs.first
        direction = rule.direction
        minimumText = rule.minimumAmount.map { Money.decimalString($0) } ?? ""
        maximumText = rule.maximumAmount.map { Money.decimalString($0) } ?? ""
        merchantName = rule.merchantName ?? ""
        categoryID = rule.categoryID
        if rule.kind == .transfer {
            outcome = .transfer
        } else if let category = runtime.ledger.category(rule.categoryID) {
            outcome = category.group == .income ? .income : .expense
        } else if rule.kind == .income {
            outcome = .income
        } else if rule.kind == nil, !(rule.merchantName ?? "").isEmpty {
            outcome = .keep
        } else {
            outcome = .expense
        }
    }

    private func save(_ rule: Rule) {
        if draft.isNew {
            runtime.commit { $0.addRule(rule) }
        } else {
            runtime.commit { $0.updateRule(rule) }
        }
        dismiss()
    }
}

struct RulePreviewBox: View {
    @Environment(LedgerRuntime.self) private var runtime
    let preview: RulePreview

    var body: some View {
        GroupBox("What this rule would do") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Matches \(preview.matchingIDs.count) transaction\(preview.matchingIDs.count == 1 ? "" : "s"); \(preview.changingIDs.count) would change.")
                    .font(.callout.weight(.medium))
                if !preview.confirmedIDs.isEmpty {
                    Caption("\(preview.confirmedIDs.count) you set by hand stay exactly as they are.")
                }
                ForEach(preview.shadowedBy.indices, id: \.self) { index in
                    Label("\(preview.shadowedBy[index].count) are caught first by your rule “\(preview.shadowedBy[index].name)” above this one.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(preview.matchingIDs.prefix(6), id: \.self) { id in
                    if let transaction = runtime.ledger.transactions[id] {
                        HStack {
                            Text(DateText.medium(transaction.date)).frame(width: 100, alignment: .leading)
                            Text(transaction.rawDescription).lineLimit(1)
                            Spacer()
                            MoneyText(cents: transaction.amount)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// Rename a merchant, set its default category, see the bank text it recognizes, or merge it.
struct MerchantEditorSheet: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let merchantID: UUID

    @State private var name = ""
    @State private var defaultChoice = "none"
    @State private var keys: [String] = []
    @State private var mergeTarget: UUID?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Edit merchant", subtitle: "Changes apply to every transaction from this merchant that you haven't set by hand.")
            Form {
                TextField("Name", text: $name)
                Picker("Always file as", selection: $defaultChoice) {
                    Text("No default").tag("none")
                    Text("Transfer").tag("transfer")
                    Section("Spending") {
                        ForEach(runtime.ledger.categories.filter { $0.group == .expense }) { category in
                            Text(category.name).tag(category.id.uuidString)
                        }
                    }
                    Section("Income") {
                        ForEach(runtime.ledger.categories.filter { $0.group == .income }) { category in
                            Text(category.name).tag(category.id.uuidString)
                        }
                    }
                }
                Section("Bank text it recognizes") {
                    if keys.isEmpty {
                        Caption("None yet. Choose “Remember” when you file one of its transactions.")
                    }
                    ForEach(keys, id: \.self) { key in
                        HStack {
                            Text(key).font(.callout.monospaced())
                            Spacer()
                            Button("Forget") { keys.removeAll { $0 == key } }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Section("Merge") {
                    Picker("Merge into", selection: $mergeTarget) {
                        Text("Choose a merchant…").tag(UUID?.none)
                        ForEach(otherMerchants) { merchant in
                            Text(merchant.name).tag(UUID?.some(merchant.id))
                        }
                    }
                    Button("Merge") {
                        guard let target = mergeTarget else { return }
                        let source = merchantID
                        runtime.commit { $0.mergeMerchants(source, into: target) }
                        dismiss()
                    }
                    .disabled(mergeTarget == nil)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 420, idealHeight: 580)
        .onAppear(perform: load)
    }

    private var otherMerchants: [Merchant] {
        runtime.ledger.merchants.values.filter { $0.id != merchantID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func load() {
        guard !loaded, let merchant = runtime.ledger.merchants[merchantID] else { return }
        loaded = true
        name = merchant.name
        keys = merchant.keys
        if merchant.kind == .transfer {
            defaultChoice = "transfer"
        } else if let category = merchant.categoryID {
            defaultChoice = category.uuidString
        }
    }

    private func save() {
        guard var merchant = runtime.ledger.merchants[merchantID] else { return dismiss() }
        merchant.keys = keys
        switch defaultChoice {
        case "none":
            merchant.kind = nil
            merchant.categoryID = nil
        case "transfer":
            merchant.kind = .transfer
            merchant.categoryID = nil
        default:
            merchant.kind = nil
            merchant.categoryID = UUID(uuidString: defaultChoice)
        }
        let updated = merchant
        let newName = name
        runtime.commit { ledger in
            var delta = ledger.updateMerchant(updated)
            if newName != updated.name { delta.merge(ledger.renameMerchant(updated.id, to: newName)) }
            return delta
        }
        dismiss()
    }
}
