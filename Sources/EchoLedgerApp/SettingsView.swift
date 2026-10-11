import AppKit
import EchoLedgerCore
import SwiftUI

struct SettingsView: View {
    @Environment(LedgerRuntime.self) private var runtime
    @AppStorage(IntelligenceController.enabledKey) private var aiEnabled = true
    @AppStorage(IntelligenceController.autoSuggestKey) private var aiAutoSuggest = true
    @AppStorage(IntelligenceController.autoFileKey) private var aiAutoFile = true
    @AppStorage(IntelligenceController.tidyNamesKey) private var aiTidyNames = true
    @AppStorage(IntelligenceController.setUpLayoutsKey) private var aiSetUpLayouts = true
    @AppStorage("EchoLedger.archiveFolder") private var archiveFolder = ""
    @State private var backupToRestore: BackupManager.Info?
    @State private var categoryToDelete: LedgerCategory?

    var body: some View {
        Page(title: "Settings", subtitle: "Your household, accounts and categories, plus where your data lives.") {
            PeopleSection()
            AccountsSection()
            CategoriesSection(categoryToDelete: $categoryToDelete)
            timeZoneSection
            intelligenceSection
            reportNotesSection
            dataSection
        }
        .confirmationDialog("Restore this backup?", isPresented: restoreBinding, presenting: backupToRestore) { backup in
            Button("Restore", role: .destructive) { runtime.restore(backup) }
        } message: { backup in
            Text("Your data goes back to how it was on \(backup.date.formatted(date: .abbreviated, time: .shortened)). A backup of the current data is made first, so you can switch back.")
        }
        .sheet(item: $categoryToDelete) { category in
            DeleteCategorySheet(category: category)
        }
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { backupToRestore != nil }, set: { if !$0 { backupToRestore = nil } })
    }

    private var timeZoneSection: some View {
        GroupBox("Time zone") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Time zone", selection: Binding(
                    get: { runtime.ledger.settings.timeZoneID },
                    set: { value in runtime.commit { ledger in ledger.updateSettings { $0.timeZoneID = value } } })) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                        Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                    }
                }
                .frame(maxWidth: 360)
                Caption("Used for “today”, “this month” and so on. Dates from your bank files are kept exactly as the bank wrote them and never shifted.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var intelligenceSection: some View {
        GroupBox("Apple Intelligence") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use Apple Intelligence on this Mac", isOn: $aiEnabled)
                Group {
                    Toggle("Look at new transactions EchoLedger doesn't know after each import", isOn: $aiAutoSuggest)
                    Picker("When it knows what something is", selection: $aiAutoFile) {
                        Text("File it, marked for you to check").tag(true)
                        Text("Only suggest; I approve each one").tag(false)
                    }
                    .padding(.leading, 20)
                    .frame(maxWidth: 520)
                    Toggle("Tidy merchant names that look like bank text (never names you set)", isOn: $aiTidyNames)
                    Toggle("Work out the columns of files from banks EchoLedger doesn't recognize", isOn: $aiSetUpLayouts)
                    Button("Tidy Merchant Names Now") {
                        Task { await runtime.intelligence.tidyMerchantNames(runtime: runtime) }
                    }
                    .disabled(!runtime.intelligence.isReady || runtime.intelligence.isTidying)
                }
                .disabled(!aiEnabled)
                if let reason = OnDeviceModel.unavailableReason {
                    Label(reason, systemImage: "sparkles.slash")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Ready. It runs on this Mac only, using Apple's on-device model.", systemImage: "sparkles")
                        .foregroundStyle(Theme.accent)
                }
                Caption("EchoLedger never sends your data to Apple's cloud models or any other service, even as a backup. Every answer is checked before it's used: categories must be yours, new bank layouts must read the whole file, summaries must match EchoLedger's own numbers. Anything Apple Intelligence files is marked, counted in a note on your reports until you check it, and undoable. When you correct one, it stops filing that bank text. Everything works with this turned off.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var reportNotesSection: some View {
        let count = runtime.ledger.acknowledgedNoteCount
        return GroupBox("Report notes") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(count == 0 ? "Every report note is showing." : "\(count) report note\(count == 1 ? " is" : "s are") marked as fine.")
                    Caption("Notes such as \"has nothing after Sep 24\" are hidden once you mark them as fine on a report. Accounts marked \"Rarely used\" below never get them.")
                }
                Spacer()
                Button("Show All Notes Again") {
                    runtime.commit { $0.showAllReportNotes() }
                }
                .disabled(count == 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var dataSection: some View {
        let backups = runtime.backups.list()
        return GroupBox("Data and backups") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Data file") {
                    Text(runtime.databaseURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Caption("Stored in your Library's Application Support folder, which iCloud doesn't sync. Turn on FileVault to encrypt your disk.")
                HStack {
                    Button("Show in Finder") { runtime.revealDataFolder() }
                    Button("Back Up Now") { runtime.backUpNow() }
                }
                Toggle("Keep the original bank text of each row", isOn: Binding(
                    get: { runtime.ledger.settings.keepSourceText },
                    set: { runtime.setKeepSourceText($0) }))
                Caption("Lets you see exactly which file line a transaction came from. Turning it off deletes the saved lines (descriptions stay).")
                Divider()
                Text("After importing, move the CSV files to")
                HStack {
                    Text(archiveFolder.isEmpty ? "Leave files where they are" : archiveFolder)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Folder…") { chooseArchiveFolder() }
                    if !archiveFolder.isEmpty {
                        Button("Don't Move") { archiveFolder = "" }
                    }
                }
                Caption("Optional. Files go into a folder per month, for example 2026-09.")
                Divider()
                Text("Backups (made automatically each day and before every import)")
                    .font(.callout.weight(.medium))
                if backups.isEmpty {
                    Caption("No backups yet.")
                }
                ForEach(backups.prefix(12)) { backup in
                    HStack {
                        Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                        Text(backup.reason)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(backup.bytes), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Restore…") { backupToRestore = backup }
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func chooseArchiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            archiveFolder = url.path
        }
    }
}

struct PeopleSection: View {
    @Environment(LedgerRuntime.self) private var runtime
    @State private var newName = ""

    var body: some View {
        GroupBox("Household") {
            VStack(alignment: .leading, spacing: 10) {
                Caption("Add each person, and how their name appears in bank text (for example on Zelle transfers). Money moving between people in your household counts as a transfer, not spending or income.")
                ForEach(runtime.ledger.people) { person in
                    PersonRow(person: person)
                    Divider()
                }
                HStack {
                    TextField("Name", text: $newName)
                        .frame(maxWidth: 220)
                        .onSubmit(add)
                    Button("Add Person", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        runtime.commit { $0.upsertPerson(Person(name: name)) }
        newName = ""
    }
}

struct PersonRow: View {
    @Environment(LedgerRuntime.self) private var runtime
    let person: Person
    @State private var name = ""
    @State private var bankNames = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TextField("Name", text: $name)
                .frame(width: 160)
                .onSubmit(save)
            TextField("Names in bank text, separated by commas", text: $bankNames)
                .onSubmit(save)
            Button("Save", action: save)
            Button("Remove") {
                let id = person.id
                runtime.commit { $0.deletePerson(id) }
            }
        }
        .onAppear {
            name = person.name
            bankNames = person.bankNames.joined(separator: ", ")
        }
    }

    private func save() {
        var updated = person
        updated.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? person.name : name.trimmingCharacters(in: .whitespaces)
        updated.bankNames = bankNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        runtime.commit { $0.upsertPerson(updated) }
    }
}

struct AccountsSection: View {
    @Environment(LedgerRuntime.self) private var runtime

    var body: some View {
        GroupBox("Accounts") {
            VStack(alignment: .leading, spacing: 10) {
                if runtime.ledger.accounts.isEmpty {
                    Caption("Accounts are created when you import their first file.")
                }
                ForEach(runtime.ledger.accounts) { account in
                    AccountRow(account: account)
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

struct AccountRow: View {
    @Environment(LedgerRuntime.self) private var runtime
    let account: Account
    @State private var name = ""
    @State private var last4 = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: account.type.symbol)
                    .foregroundStyle(Theme.accent)
                TextField("Name", text: $name)
                    .frame(maxWidth: 260)
                    .onSubmit(saveName)
                Picker("Owner", selection: Binding(get: { account.personID }, set: { value in update { $0.personID = value } })) {
                    Text("Shared").tag(UUID?.none)
                    ForEach(runtime.ledger.people) { person in
                        Text(person.name).tag(UUID?.some(person.id))
                    }
                }
                .frame(width: 170)
                Picker("Type", selection: Binding(get: { account.type }, set: { value in update { $0.type = value } })) {
                    ForEach(AccountType.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            HStack(spacing: 10) {
                TextField("Last 4", text: $last4)
                    .frame(width: 70)
                    .onSubmit(saveName)
                Text(layoutName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Amounts reversed", isOn: Binding(get: { account.flipSigns }, set: { value in update { $0.flipSigns = value } }))
                    .controlSize(.small)
                Toggle("Archived", isOn: Binding(get: { account.isArchived }, set: { value in update { $0.isArchived = value } }))
                    .controlSize(.small)
                Toggle("Rarely used", isOn: Binding(get: { account.rarelyUsed }, set: { value in update { $0.rarelyUsed = value } }))
                    .controlSize(.small)
                    .help("Reports don't warn when this account has gaps or no recent transactions.")
                Spacer()
                Button("Delete") {
                    let id = account.id
                    let deleted = runtime.commitOptional { $0.deleteAccount(id) }
                    if !deleted {
                        runtime.errorMessage = "\(account.name) has transactions, so it can't be deleted. Undo its imports first, or archive it."
                    }
                }
            }
            .padding(.leading, 28)
        }
        .onAppear {
            name = account.name
            last4 = account.last4 ?? ""
        }
    }

    private var layoutName: String {
        let profile = runtime.ledger.allProfiles.first { $0.id == account.profileID }
        return "Layout: \(profile?.name ?? "not set yet")"
    }

    private func update(_ change: (inout Account) -> Void) {
        var copy = account
        change(&copy)
        let updated = copy
        runtime.commit { $0.upsertAccount(updated) }
    }

    private func saveName() {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let digits = last4.filter { $0 >= "0" && $0 <= "9" }
        update { account in
            if !cleanName.isEmpty { account.name = cleanName }
            account.last4 = digits.count == 4 ? digits : nil
        }
    }
}

struct CategoriesSection: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Binding var categoryToDelete: LedgerCategory?
    @State private var newName = ""
    @State private var newGroup: CategoryGroup = .expense

    var body: some View {
        GroupBox("Categories") {
            VStack(alignment: .leading, spacing: 10) {
                categoryList(.expense, title: "Spending")
                categoryList(.income, title: "Income")
                HStack {
                    TextField("New category", text: $newName)
                        .frame(maxWidth: 220)
                        .onSubmit(add)
                    Picker("Group", selection: $newGroup) {
                        Text("Spending").tag(CategoryGroup.expense)
                        Text("Income").tag(CategoryGroup.income)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Button("Add", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func categoryList(_ group: CategoryGroup, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(runtime.ledger.categories.filter { $0.group == group }) { category in
                    CategoryChip(category: category) { categoryToDelete = category }
                }
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, runtime.ledger.category(named: name) == nil else { return }
        let color = runtime.ledger.categories.filter { $0.group == newGroup }.count
        let group = newGroup
        runtime.commit { $0.upsertCategory(LedgerCategory(name: name, group: group, colorIndex: color)) }
        newName = ""
    }
}

struct CategoryChip: View {
    @Environment(LedgerRuntime.self) private var runtime
    let category: LedgerCategory
    let delete: () -> Void
    @State private var name = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(0..<Theme.palette.count, id: \.self) { index in
                    Button("Color \(index + 1)") {
                        var copy = category
                        copy.colorIndex = index
                        runtime.commit { $0.upsertCategory(copy) }
                    }
                }
            } label: {
                CategoryDot(colorIndex: category.colorIndex)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            if editing {
                TextField("Name", text: $name)
                    .onSubmit(rename)
                    .frame(width: 140)
            } else {
                Text(category.name)
            }
            Spacer()
            Button(editing ? "Done" : "Rename") {
                if editing { rename() } else {
                    name = category.name
                    editing = true
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Button {
                delete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete category")
        }
    }

    private func rename() {
        editing = false
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != category.name else { return }
        var copy = category
        copy.name = clean
        runtime.commit { $0.upsertCategory(copy) }
    }
}

struct DeleteCategorySheet: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let category: LedgerCategory
    @State private var replacement: UUID?

    var body: some View {
        let count = runtime.ledger.transactions.values.filter { $0.categoryID == category.id }.count
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete “\(category.name)”?")
                .font(.title2.weight(.semibold))
            Text(count == 0 ? "No transactions use this category." : "\(count) transactions use it. Choose where they go.")
                .foregroundStyle(.secondary)
            Picker("Move them to", selection: $replacement) {
                Text("Needs review").tag(UUID?.none)
                ForEach(runtime.ledger.categories.filter { $0.id != category.id && $0.group == category.group }) { other in
                    Text(other.name).tag(UUID?.some(other.id))
                }
            }
            Caption("Rules, merchants and budgets that use it move too.")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete", role: .destructive) {
                    let id = category.id
                    let target = replacement
                    runtime.commit { $0.deleteCategory(id, replacement: target) }
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
