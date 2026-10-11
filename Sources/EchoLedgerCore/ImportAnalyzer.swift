import CryptoKit
import Foundation

/// One transaction row read from a file, before it is saved.
public struct ParsedRow: Sendable, Hashable, Identifiable {
    public var line: Int
    public var date: LocalDate
    public var postedDate: LocalDate?
    public var amount: Cents
    public var description: String
    public var bankMerchant: String?
    public var bankCategory: String?
    public var status: TransactionStatus
    public var checkNumber: String?
    public var rawText: String
    public var fingerprint: String
    public var occurrence: Int

    public var id: Int { line }
}

/// A row that could not be read, with the reason. Never silently dropped.
public struct RowIssue: Sendable, Hashable, Identifiable {
    public var line: Int
    public var reason: String
    public var rawText: String

    public var id: Int { line }
}

/// Everything EchoLedger learned from one file, before choosing what to save.
public struct FileAnalysis: Sendable, Identifiable {
    public let id: UUID
    public var fileName: String
    public var fileHash: String
    public var profile: ImportProfile?
    public var delimiter: Character
    public var headers: [String]
    /// Lines above the header row (Citi adds a few) — counted, not imported.
    public var skippedLines: Int
    public var rows: [ParsedRow]
    public var issues: [RowIssue]
    public var blankLines: Int
    public var dateLayout: DateLayout?
    /// Account type suggested by the file's content (for layouts shared by several account types).
    public var typeHint: AccountType?
    /// Four-digit numbers found in the file name or a card-number column.
    public var digitHints: [String]
    /// A file-level problem that stops the import (unreadable file, unknown layout).
    public var problem: String?
    /// Records of a file whose layout is unknown, so you can map its columns.
    public var sampleRecords: [[String]]

    public var firstDate: LocalDate? { rows.map(\.date).min() }
    public var lastDate: LocalDate? { rows.map(\.date).max() }

    /// Every line of the file is one of these.
    public var accountedLines: Int { skippedLines + (profile?.hasHeader == true ? 1 : 0) + rows.count + issues.count + blankLines }
}

public enum ImportAnalyzer {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    public static func fingerprint(date: LocalDate, amount: Cents, description: String) -> String {
        "\(date.iso)|\(amount)|\(MerchantText.normalize(description))"
    }

    /// Reads a file and recognizes its layout. `profiles` are tried in order (your saved layouts
    /// first, then the built-in ones).
    public static func analyze(fileName: String, data: Data, profiles: [ImportProfile], flipSigns: Bool = false) -> FileAnalysis {
        var analysis = FileAnalysis(id: UUID(), fileName: fileName, fileHash: sha256(data), profile: nil, delimiter: ",",
                                    headers: [], skippedLines: 0, rows: [], issues: [], blankLines: 0, dateLayout: nil,
                                    typeHint: nil, digitHints: digitHints(inFileName: fileName), problem: nil,
                                    sampleRecords: [])
        let text: String
        do {
            text = try CSVReader.decode(data)
        } catch CSVReaderError.empty {
            analysis.problem = "This file is empty."
            return analysis
        } catch {
            analysis.problem = "This file isn't readable text. Export it from your bank as CSV."
            return analysis
        }
        let delimiter = CSVReader.detectDelimiter(text)
        analysis.delimiter = delimiter
        let records = CSVReader.parse(text, delimiter: delimiter)
        analysis.sampleRecords = Array(records.filter { !$0.isBlank }.prefix(8).map(\.fields))

        guard let detected = detect(records: records, profiles: profiles) else {
            analysis.problem = "EchoLedger doesn't recognize this layout yet. Choose which columns hold the date, description and amount."
            if let header = records.first(where: { !$0.isBlank }) { analysis.headers = header.fields }
            return analysis
        }
        return parse(records: records, layout: detected, into: analysis, flipSigns: flipSigns)
    }

    /// Re-reads a file with a layout you chose or mapped yourself.
    public static func analyze(fileName: String, data: Data, profile: ImportProfile, flipSigns: Bool = false) -> FileAnalysis {
        analyze(fileName: fileName, data: data, profiles: [profile], flipSigns: flipSigns)
    }

    struct DetectedLayout {
        let profile: ImportProfile
        /// Index of the header record, or nil for headerless files.
        let headerIndex: Int?
        let columns: [String: Int]
    }

    static func columnMap(_ names: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, name) in names.enumerated() {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if map[key] == nil { map[key] = index }
        }
        return map
    }

    static func detect(records: [CSVRecord], profiles: [ImportProfile]) -> DetectedLayout? {
        var best: (layout: DetectedLayout, score: Int)?
        let searchLimit = min(records.count, 12)
        for profile in profiles where profile.hasHeader {
            let required = profile.requiredHeaders.map { $0.lowercased() }
            let forbidden = profile.forbiddenHeaders.map { $0.lowercased() }
            for index in 0..<searchLimit {
                let map = columnMap(records[index].fields)
                guard !required.isEmpty, required.allSatisfy({ map[$0] != nil }),
                      !forbidden.contains(where: { map[$0] != nil }) else { continue }
                if best == nil || required.count > best!.score {
                    best = (DetectedLayout(profile: profile, headerIndex: index, columns: map), required.count)
                }
                break
            }
        }
        if let best { return best.layout }
        let sample = records.filter { !$0.isBlank }.prefix(5)
        guard !sample.isEmpty else { return nil }
        // Built-in headerless layouts first, so a layout you set up can't take over their files.
        let headerless = profiles.filter { !$0.hasHeader && $0.isBuiltIn } + profiles.filter { !$0.hasHeader && !$0.isBuiltIn }
        for profile in headerless {
            if sample.allSatisfy({ headerlessShapeMatches(profile, record: $0) }) {
                return DetectedLayout(profile: profile, headerIndex: nil, columns: columnMap(profile.headerlessColumns))
            }
        }
        return nil
    }

    static func headerlessShapeMatches(_ profile: ImportProfile, record: CSVRecord) -> Bool {
        let fields = record.fields
        guard fields.count == profile.headerlessColumns.count else { return false }
        let layout = profile.dateLayout ?? .monthDayYear
        switch profile.headerlessShape {
        case .wellsFargoClassic:
            return layout.parse(fields[0]) != nil && Money.parseCents(fields[1]) != nil
                && fields[2].trimmingCharacters(in: .whitespaces) == "*"
        case .comenity:
            let amount = fields[1].trimmingCharacters(in: .whitespaces)
            return layout.parse(fields[0]) != nil && amount.contains("$") && Money.parseCents(amount) != nil
                && !fields[2].trimmingCharacters(in: .whitespaces).isEmpty
        case .none:
            // A layout set up for a file without a header: the date and amount columns must read.
            let map = columnMap(profile.headerlessColumns)
            guard let dateIndex = map[profile.dateColumn.lowercased()], dateIndex < fields.count,
                  layout.parse(fields[dateIndex]) != nil else { return false }
            if let amountName = profile.amountColumn, let amountIndex = map[amountName.lowercased()] {
                return amountIndex < fields.count && Money.parseCents(fields[amountIndex]) != nil
            }
            return true
        }
    }

    static func parse(records: [CSVRecord], layout: DetectedLayout, into start: FileAnalysis, flipSigns: Bool) -> FileAnalysis {
        var analysis = start
        let profile = layout.profile
        analysis.profile = profile
        let dataStart = (layout.headerIndex ?? -1) + 1
        if let headerIndex = layout.headerIndex {
            analysis.headers = records[headerIndex].fields
            // Lines above the header (Citi exports start with a summary).
            analysis.skippedLines = headerIndex
        } else {
            analysis.headers = profile.headerlessColumns
        }
        let dataRecords = Array(records[dataStart...])

        func column(_ name: String?) -> Int? {
            guard let name else { return nil }
            return layout.columns[name.lowercased()]
        }
        let dateIndex = column(profile.dateColumn)
        let postedIndex = column(profile.postedDateColumn)
        let descriptionIndex = column(profile.descriptionColumn)
        let merchantIndex = column(profile.merchantColumn)
        let categoryIndex = column(profile.categoryColumn)
        let amountIndex = column(profile.amountColumn)
        let debitIndex = column(profile.debitColumn)
        let creditIndex = column(profile.creditColumn)
        let statusIndex = column(profile.statusColumn)
        let checkIndex = column(profile.checkNumberColumn)
        let cardIndex = column(profile.cardNumberColumn)

        guard let dateIndex, let descriptionIndex,
              amountIndex != nil || (debitIndex != nil && creditIndex != nil) else {
            analysis.problem = "The layout “\(profile.name)” is missing a date, description or amount column."
            return analysis
        }

        // Pick the date layout from the dates in the file.
        var layoutForDates = profile.dateLayout
        if layoutForDates == nil {
            let samples = dataRecords.filter { !$0.isBlank && $0.fields.count > dateIndex }
                .prefix(200).map { $0.fields[dateIndex] }
            layoutForDates = DateLayout.detect(samples: Array(samples))
        }
        analysis.dateLayout = layoutForDates
        let pendingValues = Set(profile.pendingValues.map { $0.lowercased() })
        var occurrences: [String: Int] = [:]
        var cardDigits: [String] = []

        for record in dataRecords {
            if record.isBlank {
                analysis.blankLines += 1
                continue
            }
            let fields = record.fields
            func value(_ index: Int?) -> String? {
                guard let index, index < fields.count else { return nil }
                let text = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            func issue(_ reason: String) {
                analysis.issues.append(RowIssue(line: record.line, reason: reason, rawText: record.rawText))
            }
            guard let dateText = value(dateIndex) else {
                issue("No date in this row (it may be a summary line).")
                continue
            }
            guard let layoutForDates, let date = layoutForDates.parse(dateText) else {
                issue("The date “\(dateText)” isn't a date EchoLedger can read.")
                continue
            }
            var postedDate: LocalDate?
            if let postedText = value(postedIndex) {
                postedDate = layoutForDates.parse(postedText)
            }
            var amount: Cents
            if let amountIndex {
                guard let amountText = value(amountIndex) else {
                    issue("No amount in this row.")
                    continue
                }
                guard let parsed = Money.parseCents(amountText) else {
                    issue("The amount “\(amountText)” isn't an exact dollar amount.")
                    continue
                }
                amount = profile.signConvention == .positiveIsMoneyOut ? -parsed : parsed
            } else {
                let debitText = value(debitIndex)
                let creditText = value(creditIndex)
                let debit = debitText.flatMap(Money.parseCents)
                let credit = creditText.flatMap(Money.parseCents)
                if debitText != nil, debit == nil {
                    issue("The debit “\(debitText ?? "")” isn't an exact dollar amount.")
                    continue
                }
                if creditText != nil, credit == nil {
                    issue("The credit “\(creditText ?? "")” isn't an exact dollar amount.")
                    continue
                }
                let debitSize = debit.map { Cents($0.magnitude) } ?? 0
                let creditSize = credit.map { Cents($0.magnitude) } ?? 0
                if debitSize != 0, creditSize != 0 {
                    issue("Both Debit and Credit are filled in, so the direction is unclear.")
                    continue
                }
                if debit == nil, credit == nil {
                    issue("No amount in this row.")
                    continue
                }
                // A debit is always money out and a credit always money in; printed signs are ignored.
                amount = creditSize != 0 ? creditSize : -debitSize
            }
            if flipSigns { amount = -amount }
            var description = value(descriptionIndex) ?? ""
            let bankMerchant = value(merchantIndex)
            if description.isEmpty, let bankMerchant { description = bankMerchant }
            guard !description.isEmpty else {
                issue("No description in this row.")
                continue
            }
            description = description.replacingOccurrences(of: "\n", with: " ")
            var status = TransactionStatus.posted
            if let statusText = value(statusIndex), pendingValues.contains(statusText.lowercased()) {
                status = .pending
            }
            if let card = value(cardIndex) {
                let digits = card.filter { $0 >= "0" && $0 <= "9" }
                if digits.count >= 4 { cardDigits.append(String(digits.suffix(4))) }
            }
            let fingerprint = ImportAnalyzer.fingerprint(date: date, amount: amount, description: description)
            let occurrence = (occurrences[fingerprint] ?? 0) + 1
            occurrences[fingerprint] = occurrence
            analysis.rows.append(ParsedRow(line: record.line, date: date, postedDate: postedDate, amount: amount,
                                           description: description, bankMerchant: bankMerchant,
                                           bankCategory: value(categoryIndex), status: status,
                                           checkNumber: value(checkIndex), rawText: record.rawText,
                                           fingerprint: fingerprint, occurrence: occurrence))
        }
        if layoutForDates == nil, !dataRecords.isEmpty {
            analysis.problem = "The dates in this file aren't in a format EchoLedger can read."
        }
        for digits in cardDigits where !analysis.digitHints.contains(digits) {
            analysis.digitHints.append(digits)
        }
        if profile.accountType == nil {
            analysis.typeHint = AccountTypeMarkers.guess(descriptions: analysis.rows.map(\.description))
        } else {
            analysis.typeHint = profile.accountType
        }
        return analysis
    }

    /// Four-digit groups in a file name ("Chase9001_Activity.CSV" → ["9001"]).
    public static func digitHints(inFileName name: String) -> [String] {
        let stem = (name as NSString).deletingPathExtension
        var hints: [String] = []
        var current = ""
        for character in stem + " " {
            if character >= "0" && character <= "9" {
                current.append(character)
            } else {
                if current.count == 4, !hints.contains(current) { hints.append(current) }
                current = ""
            }
        }
        return hints
    }

    /// Chooses the account for a file, or describes a new one to create. The answer is only a
    /// suggestion: the preview lets you pick any account.
    public static func suggestAccount(for analysis: FileAnalysis, accounts: [Account]) -> AccountSuggestion {
        guard let profile = analysis.profile else { return .none }
        let active = accounts.filter { !$0.isArchived }
        var candidates = active.filter { $0.profileID == profile.id }
        if let hint = analysis.typeHint, profile.accountType == nil {
            candidates = candidates.filter { $0.type == hint }
        }
        let byDigits = candidates.filter { account in
            guard let last4 = account.last4 else { return false }
            return analysis.digitHints.contains(last4)
        }
        if byDigits.count == 1 { return .existing(byDigits[0].id, reason: "matched the card ending \(byDigits[0].last4 ?? "")") }
        if candidates.count == 1 { return .existing(candidates[0].id, reason: "the only \(profile.name) account") }
        if candidates.count > 1 {
            return .choose(reason: "Several accounts use this layout. Choose which one this file belongs to.")
        }
        let type = analysis.typeHint ?? profile.accountType ?? .checking
        let last4 = analysis.digitHints.first
        var name = profile.name
        if profile.accountType == nil { name += " " + type.label.lowercased() }
        if let last4 { name += " ••\(last4)" }
        return .new(name: name, type: type, last4: last4, profileID: profile.id)
    }
}

public enum AccountSuggestion: Sendable, Hashable {
    case none
    case existing(UUID, reason: String)
    case choose(reason: String)
    case new(name: String, type: AccountType, last4: String?, profileID: String)
}
