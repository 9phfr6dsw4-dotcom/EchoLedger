import EchoLedgerCore
import SwiftUI

enum PeriodChoice: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, last3Months, yearToDate, lastYear, last12Months, allTime, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .last3Months: return "Last 3 months"
        case .yearToDate: return "This year"
        case .lastYear: return "Last year"
        case .last12Months: return "Last 12 months"
        case .allTime: return "All time"
        case .custom: return "Custom…"
        }
    }

    /// The dates for this choice. Whole calendar months, so comparisons line up.
    func span(today: LocalDate, earliest: LocalDate?, customStart: LocalDate, customEnd: LocalDate) -> DateSpan {
        let thisMonth = DateSpan.month(containing: today)
        switch self {
        case .thisMonth:
            return thisMonth
        case .lastMonth:
            return DateSpan.month(containing: today.firstOfMonth.adding(days: -1))
        case .last3Months:
            return DateSpan(start: today.firstOfMonth.adding(months: -2), end: thisMonth.end)
        case .yearToDate:
            return DateSpan(start: LocalDate(year: today.year, month: 1, day: 1) ?? today, end: thisMonth.end)
        case .lastYear:
            let start = LocalDate(year: today.year - 1, month: 1, day: 1) ?? today
            let end = LocalDate(year: today.year - 1, month: 12, day: 31) ?? today
            return DateSpan(start: start, end: end)
        case .last12Months:
            return DateSpan(start: today.firstOfMonth.adding(months: -11), end: thisMonth.end)
        case .allTime:
            let start = earliest?.firstOfMonth ?? thisMonth.start
            return DateSpan(start: min(start, thisMonth.start), end: thisMonth.end)
        case .custom:
            return DateSpan(start: customStart, end: customEnd)
        }
    }
}

extension LocalDate {
    /// Midday in the current calendar, for date pickers.
    var pickerDate: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    init(pickerDate: Date) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: pickerDate)
        self = LocalDate(year: parts.year ?? 2026, month: parts.month ?? 1, day: parts.day ?? 1) ?? LocalDate(dayNumber: 0)
    }
}

/// Period menu plus custom start/end dates.
struct PeriodPicker: View {
    @Binding var choice: PeriodChoice
    @Binding var customStart: LocalDate
    @Binding var customEnd: LocalDate

    var body: some View {
        HStack(spacing: 8) {
            Picker("Period", selection: $choice) {
                ForEach(PeriodChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .frame(width: 190)
            if choice == .custom {
                DatePicker("From", selection: Binding(get: { customStart.pickerDate },
                                                      set: { customStart = LocalDate(pickerDate: $0) }),
                           displayedComponents: .date)
                    .labelsHidden()
                Text("to")
                DatePicker("To", selection: Binding(get: { customEnd.pickerDate },
                                                    set: { customEnd = LocalDate(pickerDate: $0) }),
                           displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }
}

/// Everyone, or one person.
struct PersonPicker: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Binding var personID: UUID?

    var body: some View {
        if !runtime.ledger.people.isEmpty {
            Picker("Person", selection: $personID) {
                Text("Everyone").tag(UUID?.none)
                ForEach(runtime.ledger.people) { person in
                    Text(person.name).tag(UUID?.some(person.id))
                }
            }
            .frame(width: 170)
        }
    }
}
