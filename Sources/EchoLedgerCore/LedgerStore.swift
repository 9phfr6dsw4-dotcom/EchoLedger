import Foundation
import SQLite3

public enum StoreError: Error, LocalizedError, Equatable {
    case open(String)
    case sql(String)
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "EchoLedger couldn't open its data file: \(message)"
        case .sql(let message): return "EchoLedger couldn't save: \(message)"
        case .newerVersion(let version):
            return "This data was saved by a newer EchoLedger (format \(version)). Install the newer app to open it."
        }
    }
}

/// Saves your ledger in a local SQLite database (built into macOS). Each record is stored as
/// JSON in one table, and every change is written in a single transaction, so a crash can never
/// leave half an import behind. Original file lines are kept in a second table.
public final class LedgerStore: @unchecked Sendable {
    public static let formatVersion = 1

    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    /// Records that couldn't be read on the last load (kept in the file, never deleted).
    public private(set) var unreadableRecords = 0

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        db = handle
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_close(db)
        db = nil
    }

    // MARK: SQL helpers (call with the lock held, or from init)

    private func errorMessage() -> String {
        guard let db else { return "database is closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sql(errorMessage()) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sql(errorMessage())
        }
        return statement
    }

    private func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func migrate() throws {
        let version = try userVersion()
        if version > LedgerStore.formatVersion { throw StoreError.newerVersion(version) }
        if version < 1 {
            try execute("""
                CREATE TABLE IF NOT EXISTS records (
                    kind TEXT NOT NULL,
                    id TEXT NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY (kind, id)
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS source_lines (
                    batch_id TEXT NOT NULL,
                    line INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    PRIMARY KEY (batch_id, line)
                ) WITHOUT ROWID;
                PRAGMA user_version = 1;
                """)
        }
        // Future formats add steps here: if version < 2 { … PRAGMA user_version = 2 }.
    }

    // MARK: Loading

    /// Reads everything. A brand-new store returns a starter ledger with default categories.
    public func load() throws -> Ledger {
        lock.lock()
        defer { lock.unlock() }
        unreadableRecords = 0
        let decoder = JSONDecoder()
        func records(_ kind: RecordKind) throws -> [Data] {
            let statement = try prepare("SELECT data FROM records WHERE kind = ? ORDER BY id")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, kind.rawValue, -1, LedgerStore.transient)
            var result: [Data] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let count = Int(sqlite3_column_bytes(statement, 0))
                if count > 0, let bytes = sqlite3_column_blob(statement, 0) {
                    result.append(Data(bytes: bytes, count: count))
                }
            }
            return result
        }
        func decode<T: Decodable>(_ type: T.Type, _ kind: RecordKind) throws -> [T] {
            var values: [T] = []
            for data in try records(kind) {
                if let value = try? decoder.decode(T.self, from: data) {
                    values.append(value)
                } else {
                    unreadableRecords += 1
                }
            }
            return values
        }

        var ledger = Ledger()
        ledger.people = try decode(Person.self, .person).sorted { $0.name < $1.name }
        ledger.accounts = try decode(Account.self, .account).sorted { $0.name < $1.name }
        ledger.categories = try decode(LedgerCategory.self, .category)
        ledger.rules = try decode(Rule.self, .rule)
        for merchant in try decode(Merchant.self, .merchant) { ledger.merchants[merchant.id] = merchant }
        for transaction in try decode(LedgerTransaction.self, .transaction) { ledger.transactions[transaction.id] = transaction }
        ledger.batches = try decode(ImportBatch.self, .batch).sorted { $0.importedAt < $1.importedAt }
        ledger.budgets = try decode(Budget.self, .budget)
        ledger.profiles = try decode(ImportProfile.self, .profile)
        ledger.changes = try decode(ChangeSet.self, .change).sorted { $0.date < $1.date }
        for filing in try decode(AIFiling.self, .aiFiling) { ledger.aiFilings[filing.key] = filing }
        if let settings = try decode(LedgerSettings.self, .settings).first {
            ledger.settings = settings
        }
        let isNew = ledger.categories.isEmpty && ledger.transactions.isEmpty && ledger.accounts.isEmpty
        if isNew {
            ledger.categories = LedgerCategory.defaults()
        }
        ledger.categories.sort { ($0.group.rawValue, $0.colorIndex, $0.name) < ($1.group.rawValue, $1.colorIndex, $1.name) }
        return ledger
    }

    /// True when the database holds nothing yet.
    public func isEmpty() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT COUNT(*) FROM records")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        return sqlite3_column_int64(statement, 0) == 0
    }

    // MARK: Saving

    /// Writes exactly what `delta` says changed, taking current values from `ledger`, in one
    /// transaction. Either everything is saved or nothing is.
    public func save(_ delta: LedgerDelta, from ledger: Ledger) throws {
        guard !delta.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        try execute("BEGIN IMMEDIATE")
        do {
            let upsert = try prepare("INSERT OR REPLACE INTO records (kind, id, data) VALUES (?, ?, ?)")
            defer { sqlite3_finalize(upsert) }
            let remove = try prepare("DELETE FROM records WHERE kind = ? AND id = ?")
            defer { sqlite3_finalize(remove) }

            for kind in RecordKind.allCases {
                for id in (delta.changed[kind] ?? []).sorted() {
                    guard let data = try encodedValue(kind: kind, id: id, ledger: ledger, encoder: encoder) else {
                        // It no longer exists in memory, so it was deleted.
                        try run(remove, kind.rawValue, id)
                        continue
                    }
                    sqlite3_reset(upsert)
                    sqlite3_clear_bindings(upsert)
                    sqlite3_bind_text(upsert, 1, kind.rawValue, -1, LedgerStore.transient)
                    sqlite3_bind_text(upsert, 2, id, -1, LedgerStore.transient)
                    let result = data.withUnsafeBytes { raw in
                        sqlite3_bind_blob(upsert, 3, raw.baseAddress, Int32(raw.count), LedgerStore.transient)
                    }
                    guard result == SQLITE_OK, sqlite3_step(upsert) == SQLITE_DONE else { throw StoreError.sql(errorMessage()) }
                }
                for id in (delta.deleted[kind] ?? []).sorted() {
                    try run(remove, kind.rawValue, id)
                }
            }
            if !delta.deletedSourceBatches.isEmpty {
                let statement = try prepare("DELETE FROM source_lines WHERE batch_id = ?")
                defer { sqlite3_finalize(statement) }
                for batch in delta.deletedSourceBatches {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, batch.uuidString, -1, LedgerStore.transient)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sql(errorMessage()) }
                }
            }
            if !delta.sourceLines.isEmpty {
                let statement = try prepare("INSERT OR REPLACE INTO source_lines (batch_id, line, text) VALUES (?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                for line in delta.sourceLines {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, line.batchID.uuidString, -1, LedgerStore.transient)
                    sqlite3_bind_int64(statement, 2, Int64(line.line))
                    sqlite3_bind_text(statement, 3, line.text, -1, LedgerStore.transient)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sql(errorMessage()) }
                }
            }
            try execute("COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func run(_ statement: OpaquePointer, _ first: String, _ second: String) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, first, -1, LedgerStore.transient)
        sqlite3_bind_text(statement, 2, second, -1, LedgerStore.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sql(errorMessage()) }
    }

    private func encodedValue(kind: RecordKind, id: String, ledger: Ledger, encoder: JSONEncoder) throws -> Data? {
        let uuid = UUID(uuidString: id)
        switch kind {
        case .person: return try ledger.people.first { $0.id == uuid }.map { try encoder.encode($0) }
        case .account: return try ledger.accounts.first { $0.id == uuid }.map { try encoder.encode($0) }
        case .category: return try ledger.categories.first { $0.id == uuid }.map { try encoder.encode($0) }
        case .merchant: return try uuid.flatMap { ledger.merchants[$0] }.map { try encoder.encode($0) }
        case .rule: return try ledger.rules.first { $0.id == uuid }.map { try encoder.encode($0) }
        case .transaction: return try uuid.flatMap { ledger.transactions[$0] }.map { try encoder.encode($0) }
        case .batch: return try ledger.batches.first { $0.id == uuid }.map { try encoder.encode($0) }
        case .budget: return try ledger.budgets.first { $0.id == uuid }.map { try encoder.encode($0) }
        case .change: return try ledger.changes.first { $0.id == uuid }.map { try encoder.encode($0) }
        case .profile: return try ledger.profiles.first { $0.id == id }.map { try encoder.encode($0) }
        case .aiFiling: return try ledger.aiFilings[id].map { try encoder.encode($0) }
        case .settings: return try encoder.encode(ledger.settings)
        }
    }

    /// Saves the whole ledger (used for a brand-new store and in tests).
    public func saveAll(_ ledger: Ledger) throws {
        var delta = LedgerDelta()
        for item in ledger.people { delta.change(.person, item.id) }
        for item in ledger.accounts { delta.change(.account, item.id) }
        for item in ledger.categories { delta.change(.category, item.id) }
        for item in ledger.rules { delta.change(.rule, item.id) }
        for id in ledger.merchants.keys { delta.change(.merchant, id) }
        for id in ledger.transactions.keys { delta.change(.transaction, id) }
        for item in ledger.batches { delta.change(.batch, item.id) }
        for item in ledger.budgets { delta.change(.budget, item.id) }
        for item in ledger.changes { delta.change(.change, item.id) }
        for item in ledger.profiles { delta.change(.profile, item.id) }
        for key in ledger.aiFilings.keys { delta.change(.aiFiling, key) }
        delta.change(.settings, "settings")
        try save(delta, from: ledger)
    }

    // MARK: Source lines

    /// The original text of a file line, if kept.
    public func sourceLine(batchID: UUID, line: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let statement = try? prepare("SELECT text FROM source_lines WHERE batch_id = ? AND line = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, batchID.uuidString, -1, LedgerStore.transient)
        sqlite3_bind_int64(statement, 2, Int64(line))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    /// Deletes every kept file line (when you turn off "keep original bank text").
    public func deleteAllSourceLines() throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("DELETE FROM source_lines")
    }

    // MARK: Backups

    /// Writes a consistent copy of the database to `destination` (which must not exist).
    public func backup(to destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("VACUUM INTO ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, destination.path, -1, LedgerStore.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sql(errorMessage()) }
    }

    /// True when a file is a readable EchoLedger database that passes SQLite's own check.
    public static func verify(_ file: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        guard String(cString: text) == "ok" else { return false }
        var tables: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM records", -1, &tables, nil) == SQLITE_OK, let tables else { return false }
        defer { sqlite3_finalize(tables) }
        return sqlite3_step(tables) == SQLITE_ROW
    }
}

/// Automatic and manual backups in the EchoLedger folder (never in iCloud).
public struct BackupManager: Sendable {
    public let folder: URL
    public let keep: Int

    public init(folder: URL, keep: Int = 30) {
        self.folder = folder
        self.keep = keep
    }

    public struct Info: Identifiable, Hashable, Sendable {
        public var url: URL
        public var date: Date
        public var bytes: Int
        public var reason: String
        public var id: URL { url }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    /// Makes a backup now. `reason` is a short tag such as "before-import" or "daily".
    @discardableResult
    public func makeBackup(of store: LedgerStore, reason: String, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var url = folder.appendingPathComponent("EchoLedger-\(BackupManager.stamp(now))-\(reason).sqlite")
        var attempt = 1
        while FileManager.default.fileExists(atPath: url.path) {
            attempt += 1
            url = folder.appendingPathComponent("EchoLedger-\(BackupManager.stamp(now))-\(reason)-\(attempt).sqlite")
        }
        try store.backup(to: url)
        prune()
        return url
    }

    public func list() -> [Info] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("EchoLedger-") }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = url.deletingPathExtension().lastPathComponent
                let parts = name.split(separator: "-")
                let reason = parts.count > 5 ? parts[5...].joined(separator: " ") : "backup"
                return Info(url: url, date: values?.contentModificationDate ?? .distantPast, bytes: values?.fileSize ?? 0,
                            reason: reason)
            }
            .sorted { $0.date > $1.date }
    }

    /// Keeps the newest `keep` backups.
    public func prune() {
        for old in list().dropFirst(keep) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    public func needsDailyBackup(now: Date = Date()) -> Bool {
        guard let newest = list().first else { return true }
        return now.timeIntervalSince(newest.date) > 20 * 3600
    }

    /// Replaces the database file with a backup. The store must be closed first; the current
    /// file is kept beside it as "…-replaced.sqlite" in case you change your mind.
    public static func restore(_ backup: URL, over database: URL) throws {
        guard LedgerStore.verify(backup) else { throw StoreError.open("The backup file is damaged or isn't an EchoLedger backup.") }
        let manager = FileManager.default
        let aside = database.deletingPathExtension().appendingPathExtension("replaced.sqlite")
        try? manager.removeItem(at: aside)
        if manager.fileExists(atPath: database.path) {
            try manager.moveItem(at: database, to: aside)
        }
        for suffix in ["-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: database.path + suffix))
        }
        try manager.copyItem(at: backup, to: database)
    }
}
