import EchoLedgerCore
import Foundation
import Observation

/// One file in the import preview, with your choices for it.
struct ImportFile: Identifiable {
    enum AccountChoice: Hashable {
        case existing(UUID)
        case new
        case undecided
    }

    struct NewAccountDraft {
        var id = UUID()
        var name: String
        var personID: UUID?
        var type: AccountType
        var last4: String
        var profileID: String?
        var isShared = false
    }

    /// Apple Intelligence's work on a file EchoLedger didn't recognize.
    enum LayoutHelp {
        case none
        case working
        /// The layout was set up and checked against every row.
        case done(String)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    let data: Data
    var analysis: FileAnalysis
    var choice: AccountChoice = .undecided
    var draft: NewAccountDraft
    var suggestionReason: String?
    var plan: ImportPlan?
    var include = true
    var forcedLines: Set<Int> = []
    var skipProblemRows = false
    var flipSigns = false
    var layoutHelp: LayoutHelp = .none
    /// A layout Apple Intelligence proposed, saved with the import (or used to fill in
    /// "Choose Columns" when it didn't check out).
    var proposedProfile: ImportProfile?
    /// True when `proposedProfile` is in use and must be saved when this file is imported.
    var savesProposedProfile = false

    var isReadingLayout: Bool {
        if case .working = layoutHelp { return true }
        return false
    }

    var targetAccountID: UUID? {
        switch choice {
        case .existing(let id): return id
        case .new: return draft.id
        case .undecided: return nil
        }
    }

    /// Why this file can't be imported yet, if anything.
    var blocker: String? {
        if case .working = layoutHelp { return "Apple Intelligence is reading this file's columns." }
        if let problem = analysis.problem { return problem }
        if choice == .undecided { return "Choose which account this file belongs to." }
        if choice == .new, draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the new account a name." }
        if !analysis.issues.isEmpty, !skipProblemRows {
            return "Some rows couldn't be read. Fix the file, or choose to skip those rows."
        }
        return nil
    }

    var importCount: Int {
        guard let plan else { return 0 }
        return plan.newCount + plan.replacesPendingCount + plan.possibleDuplicates.filter { forcedLines.contains($0.row.line) }.count
    }
}

/// The import preview: read files, recognize them, show what would happen, then save.
@MainActor
@Observable
final class ImportModel {
    var files: [ImportFile] = []
    var requestFilePicker = false
    var lastResult: String?
    var mappingFileID: UUID?

    var readyFiles: [ImportFile] { files.filter { $0.include && $0.blocker == nil } }

    var totalToImport: Int { readyFiles.reduce(0) { $0 + $1.importCount } }

    func add(_ urls: [URL], runtime: LedgerRuntime) {
        let profiles = runtime.ledger.allProfiles
        for url in urls {
            if files.contains(where: { $0.url == url }) { continue }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                runtime.errorMessage = "EchoLedger couldn't read \(url.lastPathComponent)."
                continue
            }
            let name = url.lastPathComponent
            Task {
                let analysis = await Task.detached(priority: .userInitiated) {
                    ImportAnalyzer.analyze(fileName: name, data: data, profiles: profiles)
                }.value
                self.receive(url: url, data: data, analysis: analysis, runtime: runtime)
            }
        }
    }

    private func receive(url: URL, data: Data, analysis: FileAnalysis, runtime: LedgerRuntime) {
        let draft = ImportFile.NewAccountDraft(name: analysis.profile?.name ?? url.deletingPathExtension().lastPathComponent,
                                               personID: runtime.ledger.people.first?.id,
                                               type: analysis.typeHint ?? .checking,
                                               last4: analysis.digitHints.first ?? "", profileID: analysis.profile?.id)
        var file = ImportFile(url: url, data: data, analysis: analysis, draft: draft)
        applySuggestion(to: &file, runtime: runtime)
        // Two files for the same new account in one import share that new account.
        if file.choice == .new, let twin = files.first(where: { other in
            other.choice == .new && other.draft.profileID == file.draft.profileID
                && other.draft.last4 == file.draft.last4 && other.draft.type == file.draft.type
        }) {
            file.draft = twin.draft
            file.suggestionReason = "Goes to the same new account as \(twin.analysis.fileName)."
        }
        files.append(file)
        replan(file.id, runtime: runtime)
        if analysis.profile == nil, runtime.intelligence.canSetUpLayouts {
            setUpLayout(file.id, runtime: runtime)
        }
    }

    /// Lets Apple Intelligence work out an unknown (or changed) bank layout. A layout that reads
    /// the whole file is used right away and saved with the import; otherwise you choose the
    /// columns, starting from its guess.
    func setUpLayout(_ id: UUID, runtime: LedgerRuntime) {
        guard let index = self.index(of: id) else { return }
        files[index].layoutHelp = .working
        let name = files[index].analysis.fileName
        let data = files[index].data
        Task {
            let outcome = await runtime.intelligence.proposeLayout(fileName: name, data: data)
            self.receiveLayout(outcome, for: id, runtime: runtime)
        }
    }

    private func receiveLayout(_ outcome: LayoutOutcome, for id: UUID, runtime: LedgerRuntime) {
        guard let index = self.index(of: id) else { return }
        files[index].proposedProfile = outcome.check?.profile
        guard let check = outcome.check, check.accepted else {
            files[index].layoutHelp = .failed(outcome.message)
            return
        }
        files[index].layoutHelp = .done(check.note)
        files[index].savesProposedProfile = true
        files[index].flipSigns = false
        files[index].analysis = check.analysis
        files[index].draft.profileID = check.profile.id
        if let type = check.profile.accountType { files[index].draft.type = type }
        var file = files[index]
        applySuggestion(to: &file, runtime: runtime)
        files[index] = file
        replan(id, runtime: runtime)
    }

    private func applySuggestion(to file: inout ImportFile, runtime: LedgerRuntime) {
        switch ImportAnalyzer.suggestAccount(for: file.analysis, accounts: runtime.ledger.accounts) {
        case .existing(let id, let reason):
            file.choice = .existing(id)
            file.suggestionReason = "Matched automatically: \(reason)."
        case .new(let name, let type, let last4, let profileID):
            file.choice = .new
            file.draft.name = name
            file.draft.type = type
            file.draft.last4 = last4 ?? ""
            file.draft.profileID = profileID
            file.suggestionReason = "A new account. Check the name and owner."
        case .choose(let reason):
            file.choice = .undecided
            file.suggestionReason = reason
        case .none:
            file.choice = .undecided
            file.suggestionReason = nil
        }
        if let account = runtime.ledger.accounts.first(where: { $0.id == file.targetAccountID }), account.flipSigns != file.flipSigns {
            file.flipSigns = account.flipSigns
            file.analysis = ImportAnalyzer.analyze(fileName: file.analysis.fileName, data: file.data,
                                                   profiles: file.analysis.profile.map { [$0] } ?? runtime.ledger.allProfiles,
                                                   flipSigns: account.flipSigns)
        }
    }

    func index(of id: UUID) -> Int? {
        files.firstIndex { $0.id == id }
    }

    /// Recomputes what would happen to each row for the chosen account.
    func replan(_ id: UUID, runtime: LedgerRuntime) {
        guard let index = self.index(of: id) else { return }
        guard let accountID = files[index].targetAccountID, files[index].analysis.profile != nil else {
            files[index].plan = nil
            return
        }
        let plan = ImportPlanner.plan(files[index].analysis, accountID: accountID, ledger: runtime.ledger)
        let possible = Set(plan.possibleDuplicates.map { $0.row.line })
        files[index].plan = plan
        files[index].forcedLines = files[index].forcedLines.intersection(possible)
    }

    func setChoice(_ choice: ImportFile.AccountChoice, for id: UUID, runtime: LedgerRuntime) {
        guard let index = self.index(of: id) else { return }
        files[index].choice = choice
        if case .existing(let accountID) = choice, let account = runtime.ledger.account(accountID),
           account.flipSigns != files[index].flipSigns {
            setFlip(account.flipSigns, for: id, runtime: runtime)
            return
        }
        replan(id, runtime: runtime)
    }

    func setFlip(_ flip: Bool, for id: UUID, runtime: LedgerRuntime) {
        guard let index = self.index(of: id) else { return }
        files[index].flipSigns = flip
        let profiles = files[index].analysis.profile.map { [$0] } ?? runtime.ledger.allProfiles
        files[index].analysis = ImportAnalyzer.analyze(fileName: files[index].analysis.fileName, data: files[index].data,
                                                       profiles: profiles, flipSigns: flip)
        replan(id, runtime: runtime)
    }

    /// Saves a layout you mapped for an unknown file and reads the file again with it.
    func applyMapping(_ profile: ImportProfile, for id: UUID, runtime: LedgerRuntime) {
        runtime.commit { $0.upsertProfile(profile) }
        guard let index = self.index(of: id) else { return }
        files[index].layoutHelp = .none
        files[index].savesProposedProfile = false
        files[index].analysis = ImportAnalyzer.analyze(fileName: files[index].analysis.fileName, data: files[index].data,
                                                       profile: profile, flipSigns: files[index].flipSigns)
        files[index].draft.profileID = profile.id
        var file = files[index]
        applySuggestion(to: &file, runtime: runtime)
        files[index] = file
        replan(id, runtime: runtime)
    }

    func remove(_ id: UUID) {
        files.removeAll { $0.id == id }
    }

    func clear() {
        files.removeAll()
    }

    /// Saves every ready file: a safety backup first, then new accounts, then the rows.
    func commit(runtime: LedgerRuntime, archiveFolder: String) {
        let ready = readyFiles
        guard !ready.isEmpty else { return }
        guard runtime.backUpBeforeImport() else { return }
        var batches: [ImportBatch] = []
        runtime.commit { ledger in
            var delta = LedgerDelta()
            for file in ready {
                guard let accountID = file.targetAccountID else { continue }
                if file.savesProposedProfile, let profile = file.analysis.profile, !ledger.profiles.contains(where: { $0.id == profile.id }) {
                    delta.merge(ledger.upsertProfile(profile))
                }
                if file.choice == .new, ledger.account(accountID) == nil {
                    let draft = file.draft
                    let last4 = draft.last4.filter { $0 >= "0" && $0 <= "9" }
                    let account = Account(id: draft.id, name: draft.name.trimmingCharacters(in: .whitespaces),
                                          personID: draft.personID, type: draft.type, last4: last4.count == 4 ? last4 : nil,
                                          profileID: file.analysis.profile?.id, flipSigns: file.flipSigns, isUnassigned: draft.personID == nil && !draft.isShared)
                    delta.merge(ledger.upsertAccount(account))
                } else if var account = ledger.account(accountID), account.flipSigns != file.flipSigns {
                    account.flipSigns = file.flipSigns
                    delta.merge(ledger.upsertAccount(account))
                }
                // Plan again against the ledger as it is now (earlier files in this import count too).
                let plan = ImportPlanner.plan(file.analysis, accountID: accountID, ledger: ledger)
                let result = ledger.commitImport([ImportCommitItem(analysis: file.analysis, plan: plan, forcedLines: file.forcedLines)])
                delta.merge(result.delta)
                batches.append(contentsOf: result.batches)
            }
            return delta
        }
        let imported = batches.reduce(0) { $0 + $1.counts.imported + $1.counts.replacedPending + $1.counts.forcedDuplicates }
        let skipped = batches.reduce(0) { $0 + $1.counts.duplicates }
        lastResult = "Imported \(imported) transactions from \(batches.count) file\(batches.count == 1 ? "" : "s")"
            + (skipped > 0 ? "; \(skipped) were already saved." : ".")
        let importedFileIDs = Set(ready.map(\.id))
        if !archiveFolder.isEmpty {
            archive(ready, batches: batches, folder: archiveFolder, runtime: runtime)
        }
        files.removeAll { importedFileIDs.contains($0.id) }
        runtime.intelligence.afterImport(runtime: runtime)
    }

    /// Moves imported files into a dated folder you chose in Settings (off by default).
    private func archive(_ files: [ImportFile], batches: [ImportBatch], folder: String, runtime: LedgerRuntime) {
        let manager = FileManager.default
        for (file, batch) in zip(files, batches) {
            let month = batch.lastDate?.monthKey ?? "Undated"
            let destinationFolder = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(month, isDirectory: true)
            do {
                try manager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                var destination = destinationFolder.appendingPathComponent(file.url.lastPathComponent)
                var counter = 2
                while manager.fileExists(atPath: destination.path) {
                    let base = file.url.deletingPathExtension().lastPathComponent
                    destination = destinationFolder.appendingPathComponent("\(base) \(counter).\(file.url.pathExtension)")
                    counter += 1
                }
                try manager.moveItem(at: file.url, to: destination)
            } catch {
                runtime.errorMessage = "Imported, but couldn't move \(file.url.lastPathComponent) to your archive folder: \(error.localizedDescription)"
            }
        }
    }
}
