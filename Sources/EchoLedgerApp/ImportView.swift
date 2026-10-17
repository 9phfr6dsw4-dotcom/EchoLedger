import EchoLedgerCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(LedgerRuntime.self) private var runtime
    @AppStorage("EchoLedger.archiveFolder") private var archiveFolder = ""
    @State private var isTargeted = false
    @State private var batchToUndo: ImportBatch?

    private var model: ImportModel { runtime.importer }

    var body: some View {
        @Bindable var model = runtime.importer
        Page(title: "Import", subtitle: "Add bank and card CSV files. EchoLedger shows exactly what it found, and nothing is saved until you choose Import.") {
            dropZone
            if let result = model.lastResult {
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.income)
            }
            ForEach(model.files) { file in
                ImportFileCard(fileID: file.id)
            }
            if !model.files.isEmpty {
                importBar
            }
            RecentImportsSection(batchToUndo: $batchToUndo)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls, runtime: runtime)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .fileImporter(isPresented: $model.requestFilePicker,
                      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.add(urls, runtime: runtime)
            }
        }
        .sheet(item: mappingBinding) { item in
            ColumnMappingSheet(fileID: item.id)
        }
        .confirmationDialog("Undo this import?", isPresented: undoBinding, presenting: batchToUndo) { batch in
            Button("Remove \(batch.counts.imported + batch.counts.replacedPending + batch.counts.forcedDuplicates) transactions", role: .destructive) {
                runtime.commit { $0.undoImport(batch.id) }
                runtime.statusMessage = "Removed the import of \(batch.fileName)."
            }
        } message: { batch in
            Text("Everything imported from \(batch.fileName) is removed, including any changes you made to those transactions. Pending charges it replaced come back.")
        }
    }

    private var mappingBinding: Binding<MappingItem?> {
        Binding(get: { model.mappingFileID.map { MappingItem(id: $0) } },
                set: { model.mappingFileID = $0?.id })
    }

    private var undoBinding: Binding<Bool> {
        Binding(get: { batchToUndo != nil }, set: { if !$0 { batchToUndo = nil } })
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text("Drop CSV files from your bank here")
                .font(.headline)
            Text("Chase, Apple Card, Citi, Capital One, Wells Fargo, Comenity, Discover, Amex and Bank of America are recognized automatically. For other banks, or when a bank changes its file, Apple Intelligence works out the columns on this Mac, or you choose them once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
            Button("Choose Files…") { model.requestFilePicker = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(isTargeted ? Theme.accent : Color.secondary.opacity(0.4))
        )
    }

    private var importBar: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    let ready = model.readyFiles.count
                    let waiting = model.files.count - ready
                    Text("\(model.totalToImport) transactions ready from \(ready) file\(ready == 1 ? "" : "s")")
                        .font(.headline)
                    if waiting > 0 {
                        Caption("\(waiting) file\(waiting == 1 ? " needs" : "s need") a decision first (see above), or turn \(waiting == 1 ? "it" : "them") off.")
                    } else {
                        Caption("A backup is made before anything is saved, and every import can be undone.")
                    }
                }
                Spacer()
                Button("Clear") { model.clear() }
                Button("Import") { model.commit(runtime: runtime, archiveFolder: archiveFolder) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.readyFiles.isEmpty)
            }
            .padding(.vertical, 4)
        }
    }
}

struct MappingItem: Identifiable {
    let id: UUID
}

/// One file's preview card.
struct ImportFileCard: View {
    @Environment(LedgerRuntime.self) private var runtime
    let fileID: UUID

    private var model: ImportModel { runtime.importer }
    private var file: ImportFile? { model.files.first { $0.id == fileID } }

    var body: some View {
        if let file {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    header(file)
                    layoutHelp(file)
                    if file.isReadingLayout {
                        EmptyView()
                    } else if let problem = file.analysis.problem {
                        ErrorLabel(message: problem)
                        if file.analysis.profile == nil {
                            HStack {
                                Button("Choose Columns…") { model.mappingFileID = file.id }
                                if runtime.intelligence.isReady {
                                    Button {
                                        model.setUpLayout(file.id, runtime: runtime)
                                    } label: {
                                        Label("Ask Apple Intelligence", systemImage: "sparkles")
                                    }
                                }
                            }
                        }
                    } else {
                        accountSection(file)
                        if let plan = file.plan {
                            ImportPlanSummary(file: file, plan: plan)
                        }
                        signToggle(file)
                        if let blocker = file.blocker {
                            Label(blocker, systemImage: "hand.raised")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .opacity(file.include ? 1 : 0.55)
            }
        }
    }

    @ViewBuilder
    private func layoutHelp(_ file: ImportFile) -> some View {
        switch file.layoutHelp {
        case .none:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Caption("Apple Intelligence is working out this file's columns, on this Mac…")
            }
        case .done(let note):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(note, systemImage: "sparkles")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Choose Columns Myself…") { model.mappingFileID = file.id }
            }
            .padding(10)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let note):
            Label(note, systemImage: "sparkles")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func header(_ file: ImportFile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.analysis.fileName)
                    .font(.headline)
                Text(file.analysis.profile.map { "Layout: \($0.name)" } ?? "Layout not recognized")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Include", isOn: Binding(
                get: { model.files.first { $0.id == fileID }?.include ?? false },
                set: { value in
                    if let index = model.index(of: fileID) { model.files[index].include = value }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
            Button {
                model.remove(fileID)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove this file from the list")
        }
    }

    private func accountSection(_ file: ImportFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Account", selection: Binding(
                get: { model.files.first { $0.id == fileID }?.choice ?? .undecided },
                set: { model.setChoice($0, for: fileID, runtime: runtime) })) {
                if file.choice == .undecided {
                    Text("Choose…").tag(ImportFile.AccountChoice.undecided)
                }
                ForEach(runtime.ledger.accounts.filter { !$0.isArchived }) { account in
                    Text(accountLabel(account)).tag(ImportFile.AccountChoice.existing(account.id))
                }
                Divider()
                Text("New account…").tag(ImportFile.AccountChoice.new)
            }
            .frame(maxWidth: 420)
            if let reason = file.suggestionReason {
                Caption(reason)
            }
            if file.choice == .new {
                NewAccountForm(fileID: fileID)
            }
        }
    }

    private func accountLabel(_ account: Account) -> String {
        let owner = runtime.ledger.usersLabel(account)
        return "\(account.name) — \(owner)"
    }

    private func signToggle(_ file: ImportFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("This bank shows purchases the other way around", isOn: Binding(
                get: { model.files.first { $0.id == fileID }?.flipSigns ?? false },
                set: { model.setFlip($0, for: fileID, runtime: runtime) }))
            Caption("Check the preview: purchases should be money out. If they show as money in, turn this on. It's remembered for this account.")
        }
    }
}

struct NewAccountForm: View {
    @Environment(LedgerRuntime.self) private var runtime
    let fileID: UUID

    private var model: ImportModel { runtime.importer }

    private var assignment: Binding<SpendingAssignment> {
        Binding(get: {
            guard let draft = model.files.first(where: { $0.id == fileID })?.draft else { return .unassigned }
            if let id = draft.personID { return .person(id) }
            return draft.isShared ? .shared : .unassigned
        }, set: { value in
            guard let index = model.index(of: fileID) else { return }
            if case .person(let id) = value { model.files[index].draft.personID = id }
            else { model.files[index].draft.personID = nil }
            model.files[index].draft.isShared = value == .shared
        })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ImportFile.NewAccountDraft, Value>, default value: Value) -> Binding<Value> {
        Binding(get: {
            model.files.first { $0.id == fileID }?.draft[keyPath: keyPath] ?? value
        }, set: { newValue in
            if let index = model.index(of: fileID) { model.files[index].draft[keyPath: keyPath] = newValue }
        })
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Name")
                TextField("Account name", text: binding(\.name, default: ""))
                    .frame(maxWidth: 320)
            }
            GridRow {
                Text("Assign spending to")
                AssignmentPicker(assignment: assignment)
                    .labelsHidden()
                    .frame(maxWidth: 220)
            }
            GridRow {
                Text("Type")
                Picker("Type", selection: binding(\.type, default: .checking)) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            GridRow {
                Text("Last 4 digits")
                TextField("Optional", text: binding(\.last4, default: ""))
                    .frame(maxWidth: 100)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        if runtime.ledger.people.isEmpty {
            Caption("Tip: add the people in your household in Settings to see reports for each person.")
        }
    }
}

/// What will happen to every row of one file.
struct ImportPlanSummary: View {
    @Environment(LedgerRuntime.self) private var runtime
    let file: ImportFile
    let plan: ImportPlan

    private var model: ImportModel { runtime.importer }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let previous = plan.previousImport {
                Label("You imported this exact file on \(previous.importedAt.formatted(date: .abbreviated, time: .shortened)). Rows already saved are skipped.",
                      systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
            statsGrid
            if !plan.possibleDuplicates.isEmpty {
                possibleDuplicatesSection
            }
            if !plan.issues.isEmpty {
                issuesSection
            }
            DisclosureGroup("Preview the first rows") {
                previewRows
            }
        }
    }

    private var statsGrid: some View {
        let totals = plan.totals
        let range: String
        if let first = plan.firstDate, let last = plan.lastDate {
            range = "\(DateText.medium(first)) – \(DateText.medium(last))"
        } else {
            range = "—"
        }
        return Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
            GridRow {
                stat("Rows in file", "\(plan.rows.count + plan.issues.count)")
                stat("New", "\(plan.newCount)")
                stat("Already saved", "\(plan.duplicateCount)")
                stat("Replace pending", "\(plan.replacesPendingCount)")
            }
            GridRow {
                stat("Held for you", "\(plan.possibleDuplicates.count)")
                stat("Couldn't read", "\(plan.issues.count)")
                stat("Money in", Money.format(totals.moneyIn))
                stat("Money out", Money.format(totals.moneyOut))
            }
            GridRow {
                stat("Dates", range)
                    .gridCellColumns(2)
                stat("Blank or summary lines", "\(plan.blankLines + plan.skippedLines)")
                    .gridCellColumns(2)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .monospacedDigit()
        }
    }

    private var possibleDuplicatesSection: some View {
        DisclosureGroup("Possible duplicates held back (\(plan.possibleDuplicates.count))") {
            VStack(alignment: .leading, spacing: 8) {
                Caption("These look like transactions you already have, but aren't exact matches (the bank may have reworded them). They're not imported unless you turn them on.")
                ForEach(plan.possibleDuplicates) { planned in
                    HStack(alignment: .top) {
                        Toggle(isOn: forcedBinding(planned.row.line)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(DateText.medium(planned.row.date)) · \(planned.row.description)")
                                Text(existingText(planned))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        MoneyText(cents: planned.row.amount)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func existingText(_ planned: PlannedRow) -> String {
        guard case .possibleDuplicate(let id) = planned.disposition, let existing = runtime.ledger.transactions[id] else { return "" }
        return "Already saved: \(DateText.medium(existing.date)) · \(existing.rawDescription)"
    }

    private func forcedBinding(_ line: Int) -> Binding<Bool> {
        Binding(get: {
            model.files.first { $0.id == file.id }?.forcedLines.contains(line) ?? false
        }, set: { value in
            guard let index = model.index(of: file.id) else { return }
            if value { model.files[index].forcedLines.insert(line) } else { model.files[index].forcedLines.remove(line) }
        })
    }

    private var issuesSection: some View {
        DisclosureGroup("Rows EchoLedger couldn't read (\(plan.issues.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.issues) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Line \(issue.line): \(issue.reason)")
                        Text(issue.rawText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Toggle("Import the other rows and skip these", isOn: Binding(
                    get: { model.files.first { $0.id == file.id }?.skipProblemRows ?? false },
                    set: { value in
                        if let index = model.index(of: file.id) { model.files[index].skipProblemRows = value }
                    }))
            }
            .padding(.top, 6)
        }
    }

    private var previewRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(plan.rows.prefix(8)) { planned in
                HStack {
                    Text(DateText.medium(planned.row.date))
                        .frame(width: 110, alignment: .leading)
                    Text(planned.row.description)
                        .lineLimit(1)
                    if planned.row.status == .pending {
                        Badge(text: "Pending", color: .orange)
                    }
                    Spacer()
                    MoneyText(cents: planned.row.amount)
                }
                .font(.callout)
            }
        }
        .padding(.top, 6)
    }
}

/// Past imports, newest first, each one undoable.
struct RecentImportsSection: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Binding var batchToUndo: ImportBatch?

    var body: some View {
        let batches = runtime.ledger.batches.sorted { $0.importedAt > $1.importedAt }
        if !batches.isEmpty {
            GroupBox("Import history") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(batches.prefix(30)) { batch in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(batch.fileName)
                                Text(batchDetail(batch))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Undo Import") { batchToUndo = batch }
                        }
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private func batchDetail(_ batch: ImportBatch) -> String {
        let account = runtime.ledger.account(batch.accountID)?.name ?? "Unknown account"
        let added = batch.counts.imported + batch.counts.replacedPending + batch.counts.forcedDuplicates
        var parts = ["\(account)", "\(added) added", "\(batch.counts.duplicates) already saved"]
        if batch.counts.heldDuplicates > 0 { parts.append("\(batch.counts.heldDuplicates) held back") }
        if batch.counts.errors > 0 { parts.append("\(batch.counts.errors) skipped rows") }
        parts.append(batch.importedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
