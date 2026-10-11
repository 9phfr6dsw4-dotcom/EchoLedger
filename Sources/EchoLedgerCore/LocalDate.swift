import Foundation

/// A calendar date with no time or time zone. Bank CSVs give date-only values, so they are kept
/// exactly as written and never shifted by a time zone.
public struct LocalDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1900...2200).contains(year), (1...12).contains(month),
              day >= 1, day <= LocalDate.daysInMonth(year: year, month: month) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    private init(unchecked year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        default: return 0
        }
    }

    /// "2026-01-31"
    public var iso: String {
        LocalDate.pad(year, 4) + "-" + LocalDate.pad(month, 2) + "-" + LocalDate.pad(day, 2)
    }

    public var description: String { iso }

    /// "2026-01"
    public var monthKey: String {
        LocalDate.pad(year, 4) + "-" + LocalDate.pad(month, 2)
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    public var firstOfMonth: LocalDate { LocalDate(unchecked: year, month, 1) }

    public var lastOfMonth: LocalDate {
        LocalDate(unchecked: year, month, LocalDate.daysInMonth(year: year, month: month))
    }

    /// Days since 1970-01-01 (civil-from-days algorithm, exact for the Gregorian calendar).
    public var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public init(dayNumber: Int) {
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(unchecked: m <= 2 ? y + 1 : y, m, d)
    }

    public func adding(days: Int) -> LocalDate {
        LocalDate(dayNumber: dayNumber + days)
    }

    public func adding(months: Int) -> LocalDate {
        let total = year * 12 + (month - 1) + months
        let newYear = total / 12
        let newMonth = total % 12 + 1
        let newDay = min(day, LocalDate.daysInMonth(year: newYear, month: newMonth))
        return LocalDate(unchecked: newYear, newMonth, newDay)
    }

    public func days(until other: LocalDate) -> Int {
        other.dayNumber - dayNumber
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Parses "2026-01-31".
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Today in the given time zone.
    public static func today(in timeZone: TimeZone, now: Date = Date()) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return LocalDate(year: parts.year ?? 2026, month: parts.month ?? 1, day: parts.day ?? 1)
            ?? LocalDate(unchecked: 2026, 1, 1)
    }

    // Codable as an ISO string so stored data stays readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = LocalDate(iso: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
        }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}

/// Date layouts found in bank exports.
public enum DateLayout: String, Codable, Sendable, CaseIterable {
    case monthDayYear   // 01/31/2026, 1/31/2026, 01-31-2026, 01/31/26
    case yearMonthDay   // 2026-01-31, 2026/01/31, 2026-01-31T10:00:00
    case dayMonthYear   // 31/01/2026

    public var label: String {
        switch self {
        case .monthDayYear: return "Month/Day/Year"
        case .yearMonthDay: return "Year-Month-Day"
        case .dayMonthYear: return "Day/Month/Year"
        }
    }

    /// Parses a date cell. Times after the date (e.g. "2026-01-31 10:00") are ignored because
    /// banks print local dates; two-digit years mean 20xx.
    public func parse(_ raw: String) -> LocalDate? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let cut = text.firstIndex(where: { $0 == "T" || $0 == " " }) {
            text = String(text[..<cut])
        }
        let separators: Set<Character> = ["/", "-", "."]
        let parts = text.split(whereSeparator: { separators.contains($0) }).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && Int($0) != nil }) else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        func fullYear(_ value: Int, digits: Int) -> Int? {
            if digits == 4 { return value }
            if digits == 2 { return 2000 + value }
            return nil
        }
        switch self {
        case .monthDayYear:
            guard parts[0].count <= 2, parts[1].count <= 2,
                  let y = fullYear(numbers[2], digits: parts[2].count) else { return nil }
            return LocalDate(year: y, month: numbers[0], day: numbers[1])
        case .dayMonthYear:
            guard parts[0].count <= 2, parts[1].count <= 2,
                  let y = fullYear(numbers[2], digits: parts[2].count) else { return nil }
            return LocalDate(year: y, month: numbers[1], day: numbers[0])
        case .yearMonthDay:
            guard parts[0].count == 4, parts[1].count <= 2, parts[2].count <= 2 else { return nil }
            return LocalDate(year: numbers[0], month: numbers[1], day: numbers[2])
        }
    }

    /// Picks the layout that reads the most samples (so one bad row doesn't hide the format).
    /// On a tie, Year-Month-Day wins, then Month/Day/Year over Day/Month/Year, because the
    /// user's banks are US banks.
    public static func detect(samples: [String]) -> DateLayout? {
        let values = samples.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var best: DateLayout?
        var bestCount = 0
        for layout in [DateLayout.yearMonthDay, .monthDayYear, .dayMonthYear] {
            let count = values.filter { layout.parse($0) != nil }.count
            if count > bestCount {
                best = layout
                bestCount = count
            }
        }
        return best
    }
}

/// An inclusive range of calendar dates.
public struct DateSpan: Hashable, Codable, Sendable {
    public var start: LocalDate
    public var end: LocalDate

    public init(start: LocalDate, end: LocalDate) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public func contains(_ date: LocalDate) -> Bool {
        date >= start && date <= end
    }

    public var dayCount: Int { start.days(until: end) + 1 }

    /// The span of the same length that ends the day before this one starts. A span that
    /// covers whole calendar months is compared with the same number of whole months.
    public var previous: DateSpan {
        if start.day == 1, end == end.lastOfMonth {
            let months = (end.year * 12 + end.month) - (start.year * 12 + start.month) + 1
            let newStart = start.adding(months: -months)
            return DateSpan(start: newStart, end: start.adding(days: -1))
        }
        return DateSpan(start: start.adding(days: -dayCount), end: start.adding(days: -1))
    }

    /// Month keys ("2026-01") touched by this span, oldest first.
    public var monthKeys: [String] {
        var keys: [String] = []
        var cursor = start.firstOfMonth
        while cursor <= end {
            keys.append(cursor.monthKey)
            cursor = cursor.adding(months: 1)
        }
        return keys
    }

    public static func month(containing date: LocalDate) -> DateSpan {
        DateSpan(start: date.firstOfMonth, end: date.lastOfMonth)
    }

    public var label: String {
        if start.day == 1, end == end.lastOfMonth {
            if start.year == end.year, start.month == end.month {
                return MonthNames.long(start.month) + " " + String(start.year)
            }
            if start.month == 1, end.month == 12, start.year == end.year {
                return String(start.year)
            }
            return MonthNames.short(start.month) + " " + String(start.year) + " – "
                + MonthNames.short(end.month) + " " + String(end.year)
        }
        return DateText.medium(start) + " – " + DateText.medium(end)
    }
}

public enum MonthNames {
    static let longNames = ["January", "February", "March", "April", "May", "June", "July",
                            "August", "September", "October", "November", "December"]
    public static func long(_ month: Int) -> String {
        (1...12).contains(month) ? longNames[month - 1] : "?"
    }
    public static func short(_ month: Int) -> String {
        String(long(month).prefix(3))
    }
}

public enum DateText {
    /// "Jan 31, 2026"
    public static func medium(_ date: LocalDate) -> String {
        "\(MonthNames.short(date.month)) \(date.day), \(date.year)"
    }

    /// "Jan 31"
    public static func short(_ date: LocalDate) -> String {
        "\(MonthNames.short(date.month)) \(date.day)"
    }

    /// "Jan 2026" from "2026-01"
    public static func monthLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return key }
        return "\(MonthNames.short(m)) \(y)"
    }
}
