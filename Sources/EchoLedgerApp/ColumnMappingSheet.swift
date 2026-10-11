import EchoLedgerCore
import SwiftUI

/// Teach EchoLedger a new bank layout: say which column is which, once. The layout is saved and
/// recognized automatically next time.
struct ColumnMappingSheet: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let fileID: UUID

    @State private var name = ""
    @State private var dateColumn = ""
    @State private var descriptionColumn = ""
    @State private var usesTwoColumns = false
    @State private var amountColumn = ""
    @State private var debitColumn = ""
    @State private var creditColumn = ""
    @State private var postedColumn = ""
    @State private var statusColumn = ""
    @State private var sign: SignConvention = .positiveIsMoneyIn
    @State private var accountType: AccountType = .checking

    private var file: ImportFile? { runtime.importer.files.first { $0.id == fileID } }
    private var headers: [String] {
        (file?.analysis.headers ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Choose columns", subtitle: "Tell EchoLedger which column holds what. It remembers this layout for next time.")
            Form {
                TextField("Layout name", text: $name, prompt: Text("e.g. Credit union checking"))
                Picker("Account type", selection: $accountType) {
                    ForEach(AccountType.allCases) { Text($0.label).tag($0) }
                }
                columnPicker("Date", selection: $dateColumn, optional: false)
                columnPicker("Description", selection: $descriptionColumn, optional: false)
                Toggle("Money in and out are in separate columns", isOn: $usesTwoColumns)
                if usesTwoColumns {
                    columnPicker("Money out (debit)", selection: $debitColumn, optional: false)
                    columnPicker("Money in (credit)", selection: $creditColumn, optional: false)
                } else {
                    columnPicker("Amount", selection: $amountColumn, optional: false)
                    Picker("In this file", selection: $sign) {
                        ForEach(SignConvention.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                columnPicker("Posting date (optional)", selection: $postedColumn, optional: true)
                columnPicker("Status, pending/posted (optional)", selection: $statusColumn, optional: true)
            }
            .formStyle(.grouped)
            preview
            HStack {
                Caption("The first row of the file must be the column names.")
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Layout") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isComplete)
            }
        }
        .padding(24)
        .frame(width: 620, height: 680)
        .onAppear(perform: guessColumns)
    }

    private var isComplete: Bool {
        !dateColumn.isEmpty && !descriptionColumn.isEmpty
            && (usesTwoColumns ? (!debitColumn.isEmpty && !creditColumn.isEmpty) : !amountColumn.isEmpty)
    }

    private func columnPicker(_ title: String, selection: Binding<String>, optional: Bool) -> some View {
        Picker(title, selection: selection) {
            Text(optional ? "None" : "Choose…").tag("")
            ForEach(headers, id: \.self) { header in
                Text(header).tag(header)
            }
        }
    }

    private var draftProfile: ImportProfile {
        ImportProfile(id: "custom-" + String(UUID().uuidString.prefix(8)).lowercased(),
                      name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "My bank" : name,
                      accountType: accountType, requiredHeaders: headers,
                      dateColumn: dateColumn, postedDateColumn: postedColumn.isEmpty ? nil : postedColumn,
                      descriptionColumn: descriptionColumn,
                      amountColumn: usesTwoColumns ? nil : amountColumn,
                      debitColumn: usesTwoColumns ? debitColumn : nil, creditColumn: usesTwoColumns ? creditColumn : nil,
                      signConvention: sign, statusColumn: statusColumn.isEmpty ? nil : statusColumn,
                      pendingValues: statusColumn.isEmpty ? [] : ["Pending", "Pend", "P"], isBuiltIn: false)
    }

    @ViewBuilder
    private var preview: some View {
        if isComplete, let file {
            let analysis = ImportAnalyzer.analyze(fileName: file.analysis.fileName, data: file.data, profile: draftProfile)
            GroupBox("Preview") {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = analysis.problem {
                        ErrorLabel(message: problem)
                    }
                    ForEach(analysis.rows.prefix(4)) { row in
                        HStack {
                            Text(DateText.medium(row.date)).frame(width: 110, alignment: .leading)
                            Text(row.description).lineLimit(1)
                            Spacer()
                            MoneyText(cents: row.amount)
                        }
                        .font(.callout)
                    }
                    Caption("\(analysis.rows.count) rows read, \(analysis.issues.count) couldn't be read. Purchases should show as money out.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func guessColumns() {
        if let proposed = file?.proposedProfile ?? file?.analysis.profile, proposed.hasHeader, !proposed.isBuiltIn, prefill(from: proposed) {
            return
        }
        func find(_ words: [String]) -> String {
            headers.first { header in words.contains { header.lowercased().contains($0) } } ?? ""
        }
        dateColumn = find(["date"])
        descriptionColumn = find(["description", "memo", "payee", "merchant", "name"])
        amountColumn = find(["amount"])
        debitColumn = find(["debit", "withdrawal"])
        creditColumn = find(["credit", "deposit"])
        usesTwoColumns = amountColumn.isEmpty && !debitColumn.isEmpty && !creditColumn.isEmpty
        statusColumn = find(["status"])
        if name.isEmpty { name = file?.analysis.fileName.components(separatedBy: ".").first ?? "" }
    }

    /// Starts from Apple Intelligence's layout when its columns are in this file.
    private func prefill(from profile: ImportProfile) -> Bool {
        let known = Set(headers)
        guard known.contains(profile.dateColumn), known.contains(profile.descriptionColumn) else { return false }
        name = profile.name
        accountType = profile.accountType ?? .checking
        dateColumn = profile.dateColumn
        descriptionColumn = profile.descriptionColumn
        usesTwoColumns = profile.usesDebitCredit
        amountColumn = profile.amountColumn ?? ""
        debitColumn = profile.debitColumn ?? ""
        creditColumn = profile.creditColumn ?? ""
        postedColumn = profile.postedDateColumn ?? ""
        statusColumn = profile.statusColumn ?? ""
        sign = profile.signConvention
        return true
    }

    private func save() {
        runtime.importer.applyMapping(draftProfile, for: fileID, runtime: runtime)
        dismiss()
    }
}
