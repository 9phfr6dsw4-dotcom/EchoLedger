import Foundation

/// One parsed CSV record and the physical line it starts on (1-based), so every transaction can
/// point back to its exact source row.
public struct CSVRecord: Hashable, Sendable {
    public var line: Int
    public var fields: [String]
    public var rawText: String

    public init(line: Int, fields: [String], rawText: String) {
        self.line = line
        self.fields = fields
        self.rawText = rawText
    }

    public var isBlank: Bool {
        fields.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

public enum CSVReaderError: Error, Equatable, Sendable {
    case unreadableEncoding
    case empty
}

public enum CSVReader {
    /// Decodes bytes as UTF-8 (with or without BOM) or UTF-16 (with BOM), falling back to
    /// Windows-1252, which some banks still use.
    public static func decode(_ data: Data) throws -> String {
        if data.isEmpty { throw CSVReaderError.empty }
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE,
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return stripBOM(text)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF,
           let text = String(data: data, encoding: .utf16BigEndian) {
            return stripBOM(text)
        }
        if let text = String(data: data, encoding: .utf8) {
            return stripBOM(text)
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        throw CSVReaderError.unreadableEncoding
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Picks comma, tab or semicolon by counting separators outside quotes in the first lines.
    /// Works on Unicode scalars, so "\r\n" is two separate characters here.
    public static func detectDelimiter(_ text: String) -> Character {
        let candidates: [Unicode.Scalar] = [",", "\t", ";"]
        var counts: [Unicode.Scalar: Int] = [:]
        var inQuotes = false
        var lines = 0
        for scalar in text.unicodeScalars {
            if scalar == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if scalar == "\n" {
                lines += 1
                if lines >= 20 { break }
                continue
            }
            if candidates.contains(scalar) { counts[scalar, default: 0] += 1 }
        }
        var best: Unicode.Scalar = ","
        var bestCount = 0
        for candidate in candidates {
            let count = counts[candidate] ?? 0
            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }
        return Character(best)
    }

    /// RFC 4180 parsing: quoted fields, doubled quotes, delimiters and line breaks inside quotes,
    /// CRLF / LF / CR line endings. Blank lines are returned as blank records so they can be
    /// counted rather than silently ignored. Works on Unicode scalars so "\r\n" is handled as
    /// two characters (Swift would otherwise treat it as one).
    public static func parse(_ text: String, delimiter: Character) -> [CSVRecord] {
        let separator: Unicode.Scalar = delimiter.unicodeScalars.first ?? ","
        let quote: Unicode.Scalar = "\""
        let lf: Unicode.Scalar = "\n"
        let cr: Unicode.Scalar = "\r"
        let scalars = Array(text.unicodeScalars)

        var records: [CSVRecord] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var raw = String.UnicodeScalarView()
        var inQuotes = false
        var fieldWasQuoted = false
        var line = 1
        var recordStartLine = 1

        func finishField() {
            let value = String(field)
            fields.append(fieldWasQuoted ? value : value.trimmingCharacters(in: .whitespaces))
            field = String.UnicodeScalarView()
            fieldWasQuoted = false
        }
        func finishRecord() {
            finishField()
            records.append(CSVRecord(line: recordStartLine, fields: fields, rawText: String(raw)))
            fields = []
            raw = String.UnicodeScalarView()
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == quote {
                    if index + 1 < scalars.count, scalars[index + 1] == quote {
                        field.append(quote)
                        raw.append(quote)
                        raw.append(quote)
                        index += 2
                        continue
                    }
                    inQuotes = false
                    raw.append(scalar)
                } else if scalar == lf || scalar == cr {
                    // A line break inside quotes: keep it in the field, count the line.
                    if scalar == cr, index + 1 < scalars.count, scalars[index + 1] == lf {
                        index += 1
                    }
                    line += 1
                    field.append(lf)
                    raw.append(" ")
                } else {
                    field.append(scalar)
                    raw.append(scalar)
                }
                index += 1
                continue
            }
            if scalar == quote {
                if String(field).trimmingCharacters(in: .whitespaces).isEmpty {
                    field = String.UnicodeScalarView()
                    inQuotes = true
                    fieldWasQuoted = true
                } else {
                    field.append(scalar)
                }
                raw.append(scalar)
            } else if scalar == separator {
                finishField()
                raw.append(scalar)
            } else if scalar == lf || scalar == cr {
                if scalar == cr, index + 1 < scalars.count, scalars[index + 1] == lf {
                    index += 1
                }
                finishRecord()
                line += 1
                recordStartLine = line
            } else {
                field.append(scalar)
                raw.append(scalar)
            }
            index += 1
        }
        if !field.isEmpty || !fields.isEmpty || fieldWasQuoted {
            finishRecord()
        }
        return records
    }
}
