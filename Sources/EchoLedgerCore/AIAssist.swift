import Foundation

// MARK: - New bank layouts

/// Apple Intelligence's reading of an unknown file: which column holds what. Column numbers
/// start at 1; 0 means "none".
public struct LayoutGuess: Sendable, Hashable {
    public var headerRow: Int
    public var dateColumn: Int
    public var descriptionColumn: Int
    public var amountColumn: Int
    public var moneyOutColumn: Int
    public var moneyInColumn: Int
    public var postedDateColumn: Int
    public var statusColumn: Int
    public var purchasesArePositive: Bool
    public var bankName: String
    public var accountType: AccountType?

    public init(headerRow: Int, dateColumn: Int, descriptionColumn: Int, amountColumn: Int, moneyOutColumn: Int,
                moneyInColumn: Int, postedDateColumn: Int, statusColumn: Int, purchasesArePositive: Bool,
                bankName: String, accountType: AccountType?) {
        self.headerRow = headerRow
        self.dateColumn = dateColumn
        self.descriptionColumn = descriptionColumn
        self.amountColumn = amountColumn
        self.moneyOutColumn = moneyOutColumn
        self.moneyInColumn = moneyInColumn
        self.postedDateColumn = postedDateColumn
        self.statusColumn = statusColumn
        self.purchasesArePositive = purchasesArePositive
        self.bankName = bankName
        self.accountType = accountType
    }
}

/// The result of checking a proposed layout against the whole file.
public struct LayoutCheck: Sendable {
    public var profile: ImportProfile
    public var analysis: FileAnalysis
    public var accepted: Bool
    /// Set when EchoLedger reversed the signs because almost every row came out as money in.
    public var flippedSigns: Bool
    public var note: String
}

/// Turns Apple Intelligence's column guess into a layout, then lets EchoLedger's own parser
/// prove it on every row. The model only says which column is which; it never reads amounts.
public enum LayoutProposal {
    /// The first rows of a file as the model sees them, with long digit runs hidden.
    public static func sampleRows(_ data: Data, maxRows: Int = 8) -> [[String]] {
        guard let text = try? CSVReader.decode(data) else { return [] }
        let records = CSVReader.parse(text, delimiter: CSVReader.detectDelimiter(text))
        return Array(records.filter { !$0.isBlank }.prefix(maxRows).map(\.fields))
    }

    public static func promptText(_ rows: [[String]]) -> String {
        rows.indices.map { index in
            let cells = rows[index].indices.map { column in
                "[\(column + 1)] \(SuggestionCheck.redactDigits(String(rows[index][column].prefix(60))))"
            }
            return "Row \(index + 1): " + cells.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    /// Builds a layout from the guess, or nil when the guess doesn't fit the file (columns out
    /// of range, the same column used twice, no amount, or unnamed header columns).
    public static func makeProfile(_ guess: LayoutGuess, rows: [[String]], id: String) -> ImportProfile? {
        guard !rows.isEmpty else { return nil }
        let hasHeader = guess.headerRow >= 1
        guard guess.headerRow <= rows.count else { return nil }
        let headerCells = hasHeader ? rows[guess.headerRow - 1].map { $0.trimmingCharacters(in: .whitespaces) } : []
        let dataRows = hasHeader ? Array(rows.dropFirst(guess.headerRow)) : rows
        let columnCount = hasHeader ? headerCells.count : (dataRows.first?.count ?? 0)
        guard columnCount >= 3 else { return nil }
        func valid(_ column: Int) -> Bool { column >= 1 && column <= columnCount }
        guard valid(guess.dateColumn), valid(guess.descriptionColumn), guess.dateColumn != guess.descriptionColumn else { return nil }
        let single = valid(guess.amountColumn)
        let pair = valid(guess.moneyOutColumn) && valid(guess.moneyInColumn) && guess.moneyOutColumn != guess.moneyInColumn
        guard single || pair else { return nil }
        var used: [Int] = [guess.dateColumn, guess.descriptionColumn]
        used += single ? [guess.amountColumn] : [guess.moneyOutColumn, guess.moneyInColumn]
        guard Set(used).count == used.count else { return nil }

        let names: [String] = hasHeader ? headerCells : (1...columnCount).map { "Column \($0)" }
        if hasHeader {
            // Chosen columns need a unique, non-empty header name.
            for column in used {
                let name = names[column - 1].lowercased()
                guard !name.isEmpty, names.filter({ $0.lowercased() == name }).count == 1 else { return nil }
            }
        }
        func name(_ column: Int) -> String? { valid(column) && !names[column - 1].isEmpty ? names[column - 1] : nil }
        let dateSamples = dataRows.compactMap { $0.count >= guess.dateColumn ? $0[guess.dateColumn - 1] : nil }
        let bank = guess.bankName.trimmingCharacters(in: .whitespaces)
        return ImportProfile(
            id: id, name: bank.isEmpty || bank.lowercased() == "unknown" ? "Bank file" : String(bank.prefix(40)),
            accountType: guess.accountType, hasHeader: hasHeader,
            requiredHeaders: hasHeader ? names.filter { !$0.isEmpty } : [],
            headerlessColumns: hasHeader ? [] : names, headerlessShape: .none,
            dateColumn: names[guess.dateColumn - 1],
            postedDateColumn: guess.postedDateColumn == guess.dateColumn ? nil : name(guess.postedDateColumn),
            descriptionColumn: names[guess.descriptionColumn - 1],
            amountColumn: single ? names[guess.amountColumn - 1] : nil,
            debitColumn: single ? nil : names[guess.moneyOutColumn - 1],
            creditColumn: single ? nil : names[guess.moneyInColumn - 1],
            signConvention: guess.purchasesArePositive ? .positiveIsMoneyOut : .positiveIsMoneyIn,
            statusColumn: name(guess.statusColumn), pendingValues: ["Pending", "Pend", "Authorized"],
            dateLayout: hasHeader ? nil : DateLayout.detect(samples: dateSamples), isBuiltIn: false)
    }

    /// Reads the whole file with the proposed layout. Accepted when at least one row reads and
    /// no more than one row in ten fails. When almost every row comes out as money in (and it
    /// isn't a savings account), the signs are reversed, since purchases are money out.
    public static func check(_ profile: ImportProfile, fileName: String, data: Data) -> LayoutCheck {
        var current = profile
        var analysis = ImportAnalyzer.analyze(fileName: fileName, data: data, profile: current)
        var flipped = false
        if analysis.problem == nil, current.accountType != .savings, mostlyMoneyIn(analysis.rows) {
            current = reversed(current)
            analysis = ImportAnalyzer.analyze(fileName: fileName, data: data, profile: current)
            flipped = true
        }
        let rows = analysis.rows.count
        let accepted = analysis.problem == nil && rows > 0 && analysis.issues.count <= max(1, rows / 10)
        var note: String
        if accepted {
            note = "Apple Intelligence set up this layout and EchoLedger read \(rows) rows with it."
            if flipped { note += " Signs were reversed because almost every row came out as money in; check the preview." }
        } else if let problem = analysis.problem {
            note = "The suggested layout didn't work: \(problem)"
        } else {
            note = "The suggested layout read \(rows) rows but couldn't read \(analysis.issues.count)."
        }
        return LayoutCheck(profile: current, analysis: analysis, accepted: accepted, flippedSigns: flipped, note: note)
    }

    /// At least 5 rows and 70% or more of them money in.
    public static func mostlyMoneyIn(_ rows: [ParsedRow]) -> Bool {
        guard rows.count >= 5 else { return false }
        let moneyIn = rows.filter { $0.amount > 0 }.count
        return moneyIn * 10 >= rows.count * 7
    }

    static func reversed(_ profile: ImportProfile) -> ImportProfile {
        var copy = profile
        if copy.usesDebitCredit {
            let debit = copy.debitColumn
            copy.debitColumn = copy.creditColumn
            copy.creditColumn = debit
        } else {
            copy.signConvention = copy.signConvention == .positiveIsMoneyIn ? .positiveIsMoneyOut : .positiveIsMoneyIn
        }
        return copy
    }

    /// Maps the model's account-type words onto EchoLedger's account types.
    public static func accountType(from text: String) -> AccountType? {
        let clean = text.lowercased()
        if clean.contains("credit") || clean.contains("card") { return .creditCard }
        if clean.contains("saving") { return .savings }
        if clean.contains("check") || clean.contains("debit") { return .checking }
        return nil
    }
}

// MARK: - Your filing style

/// Examples of how you filed similar transactions, given to Apple Intelligence so its answers
/// follow your habits rather than generic ones.
public enum StyleExamples {
    public static func examples(for transaction: LedgerTransaction, ledger: Ledger, limit: Int = 6) -> [String] {
        let target = MerchantText(transaction.rawDescription).key
        let bankCategory = transaction.bankCategory.map { MerchantText.normalize($0) }
        var seen: Set<String> = []
        var candidates: [(score: Int, text: String)] = []
        let decided = ledger.transactions.values
            .filter { $0.isActive && $0.id != transaction.id && ($0.review == .confirmed || $0.method == .learned || $0.method == .userRule) }
            .sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
        for other in decided {
            let key = MerchantText(other.rawDescription).key
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            var score = KeySimilarity.score(target, key)
            if let bankCategory, let otherCategory = other.bankCategory, MerchantText.normalize(otherCategory) == bankCategory {
                score += 25
            }
            guard score >= 40 else { continue }
            let merchant = other.merchantID.flatMap { ledger.merchants[$0]?.name } ?? MerchantText(other.rawDescription).displayName
            let filedAs = ledger.category(other.categoryID)?.name ?? other.kind.label
            candidates.append((score, "“\(SuggestionCheck.redactDigits(MerchantText(other.rawDescription).core))” → \(merchant), \(filedAs)"))
        }
        return candidates.sorted { ($0.score, $1.text) > ($1.score, $0.text) }.prefix(limit).map { $0.text }
    }
}

// MARK: - Merchant names

public enum MerchantNames {
    /// Names that still look like bank text: all capitals, codes and store numbers, or just the
    /// bank text title-cased. Names you set yourself and built-in names are never touched.
    public static func needsTidying(_ merchant: Merchant, directoryNames: Set<String>) -> Bool {
        if merchant.nameLocked || directoryNames.contains(merchant.name.lowercased()) { return false }
        let name = merchant.name
        let letters = name.filter { $0.isLetter }
        if letters.count >= 3, !letters.contains(where: { $0.isLowercase }) { return true }
        if name.contains("*") || name.contains("#") { return true }
        var run = 0
        for character in name {
            run = character.isNumber ? run + 1 : 0
            if run >= 3 { return true }
        }
        return merchant.keys.contains { MerchantText.titleCase($0) == name }
    }

    /// Accepts a proposed new name only when it plainly refers to the same merchant (its letters
    /// overlap the old name's), so a confused answer can't rename Joe's Diner to Starbucks.
    /// Returns nil when the proposal is rejected or unchanged.
    public static func acceptRename(from old: String, to proposed: String) -> String? {
        let new = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new != old, (2...40).contains(new.count), !new.contains("\n"), new.filter({ $0.isLetter }).count >= 2,
              !new.lowercased().contains("http") else { return nil }
        let oldLetters = old.lowercased().filter { $0.isLetter }
        let newLetters = new.lowercased().filter { $0.isLetter }
        if oldLetters == newLetters { return new }
        if newLetters.count >= 3, oldLetters.contains(newLetters) { return new }
        if oldLetters.count >= 3, newLetters.contains(oldLetters) { return new }
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
        }
        if !words(old).isDisjoint(with: words(new)) { return new }
        return nil
    }
}
