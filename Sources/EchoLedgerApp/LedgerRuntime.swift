import AppKit
import EchoLedgerCore
import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case importFiles, review, transactions, reports, ask, rules, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importFiles: return "Import"
        case .review: return "Review"
        case .transactions: return "Transactions"
        case .reports: return "Reports"
        case .ask: return "Ask"
        case .rules: return "Rules & Merchants"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .importFiles: return "square.and.arrow.down"
        case .review: return "checklist"
        case .transactions: return "list.bullet.rectangle"
        case .reports: return "chart.pie"
        case .ask: return "sparkles"
        case .rules: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }

    var shortcut: Character {
        switch self {
        case .importFiles: return "1"
        case .review: return "2"
        case .transactions: return "3"
        case .reports: return "4"
        case .ask: return "5"
        case .rules: return "6"
        case .settings: return "7"
        }
    }
}

/// Owns your ledger, saves every change, and keeps the app's controllers together.
@MainActor
@Observable
final class LedgerRuntime {
    private(set) var ledger = Ledger.starter()
    /// Goes up by one after every saved change; views use it to refresh cached results.
    private(set) var revision = 0
    var section: AppSection = .importFiles
    var errorMessage: String?
    var statusMessage: String?
    /// Set by other screens to open Transactions with a filter.
    var transactionsFocus: TransactionsFocus?

    let dataFolder: URL
    private(set) var store: LedgerStore?
    let backups: BackupManager
    let importer = ImportModel()
    let intelligence = IntelligenceController()

    var databaseURL: URL { dataFolder.appendingPathComponent("EchoLedger.sqlite") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        dataFolder = support.appendingPathComponent("EchoLedger", isDirectory: true)
        backups = BackupManager(folder: dataFolder.appendingPathComponent("Backups", isDirectory: true))
        openStore()
    }

    private func openStore() {
        do {
            let store = try LedgerStore(url: databaseURL)
            let empty = try store.isEmpty()
            let loaded = try store.load()
            if empty {
                // First launch: save the starter categories and settings.
                try store.saveAll(loaded)
            }
            self.store = store
            ledger = loaded
            revision += 1
            if store.unreadableRecords > 0 {
                errorMessage = "\(store.unreadableRecords) saved records couldn't be read and were skipped. They're still in the data file."
            }
            if !empty, backups.needsDailyBackup() {
                _ = try? backups.makeBackup(of: store, reason: "daily")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var today: LocalDate { LocalDate.today(in: ledger.settings.timeZone) }

    /// Applies a change made by one of the Ledger's methods and saves it.
    func commit(_ change: (inout Ledger) -> LedgerDelta) {
        var working = ledger
        let delta = change(&working)
        save(delta, working)
    }

    func commitOptional(_ change: (inout Ledger) -> LedgerDelta?) -> Bool {
        var working = ledger
        guard let delta = change(&working) else { return false }
        save(delta, working)
        return true
    }

    private func save(_ delta: LedgerDelta, _ working: Ledger) {
        guard let store else {
            errorMessage = "EchoLedger can't save changes because its data file couldn't be opened."
            return
        }
        do {
            try store.save(delta, from: working)
            ledger = working
            revision += 1
            if delta.changed[.settings] != nil || delta.changed[.rule] != nil {
                intelligence.invalidate()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Undo

    var undoLabel: String? { ledger.undoLabel }

    func undo() {
        let undone = commitOptional { $0.undoLastChange() }
        if undone { statusMessage = "Undone." }
    }

    // MARK: Source text

    func sourceLine(for transaction: LedgerTransaction) -> String? {
        guard let batchID = transaction.batchID else { return nil }
        return store?.sourceLine(batchID: batchID, line: transaction.sourceLine)
    }

    // MARK: Backups

    func backUpNow() {
        guard let store else { return }
        do {
            let url = try backups.makeBackup(of: store, reason: "manual")
            statusMessage = "Backed up to \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func backUpBeforeImport() -> Bool {
        guard let store else { return false }
        do {
            try backups.makeBackup(of: store, reason: "before-import")
            return true
        } catch {
            errorMessage = "EchoLedger couldn't make its safety backup, so nothing was imported: \(error.localizedDescription)"
            return false
        }
    }

    func restore(_ backup: BackupManager.Info) {
        guard let current = store else { return }
        do {
            try backups.makeBackup(of: current, reason: "before-restore")
            current.close()
            store = nil
            try BackupManager.restore(backup.url, over: databaseURL)
            openStore()
            statusMessage = "Restored the backup from \(backup.date.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            errorMessage = error.localizedDescription
            if store == nil { openStore() }
        }
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
    }

    func setKeepSourceText(_ keep: Bool) {
        commit { ledger in ledger.updateSettings { $0.keepSourceText = keep } }
        if !keep {
            do {
                try store?.deleteAllSourceLines()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Navigation

    func showTransactions(_ focus: TransactionsFocus) {
        transactionsFocus = focus
        section = .transactions
    }
}

/// A filter another screen asks the Transactions screen to show.
struct TransactionsFocus: Equatable {
    var title: String
    var ids: Set<UUID>
}
