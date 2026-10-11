import AppKit
import EchoLedgerCore
import SwiftUI

/// Shared look: the same page structure as EchoFlow and Lumen.
enum Theme {
    static let accent = Color(red: 0.17, green: 0.49, blue: 0.94)
    static let accentLight = Color(red: 0.55, green: 0.88, blue: 1.0)
    static let income = Color(red: 0.16, green: 0.62, blue: 0.40)
    static let spending = Color(red: 0.86, green: 0.36, blue: 0.27)
    static let neutral = Color.secondary

    /// Distinct, readable colors for categories in light and dark mode.
    static let palette: [Color] = [
        Color(red: 0.17, green: 0.49, blue: 0.94), Color(red: 0.95, green: 0.55, blue: 0.16),
        Color(red: 0.20, green: 0.66, blue: 0.47), Color(red: 0.86, green: 0.30, blue: 0.40),
        Color(red: 0.55, green: 0.40, blue: 0.85), Color(red: 0.10, green: 0.70, blue: 0.80),
        Color(red: 0.85, green: 0.70, blue: 0.10), Color(red: 0.60, green: 0.45, blue: 0.30),
        Color(red: 0.95, green: 0.45, blue: 0.70), Color(red: 0.40, green: 0.60, blue: 0.20),
        Color(red: 0.35, green: 0.45, blue: 0.65), Color(red: 0.75, green: 0.35, blue: 0.15)
    ]

    static func color(forCategoryIndex index: Int) -> Color {
        guard index >= 0 else { return Color.gray }
        return palette[index % palette.count]
    }

    static func amountColor(_ cents: Cents) -> Color {
        cents > 0 ? income : Color.primary
    }

    static func dollars(_ cents: Cents) -> Double {
        Double(cents) / 100
    }
}

/// The standard page: a large title, a subtitle, then content.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A scrolling page in the EchoFlow style.
struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: title, subtitle: subtitle)
                content()
                PrivacyFooter()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PrivacyFooter: View {
    var body: some View {
        Label("Your financial data stays on this Mac. Nothing is uploaded.", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

struct ErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Caption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A money amount, right-aligned with tabular digits; money in shows in green.
struct MoneyText: View {
    let cents: Cents
    var currency: String = "USD"
    var colored: Bool = true

    var body: some View {
        Text(Money.format(cents, currency: currency))
            .monospacedDigit()
            .foregroundStyle(colored ? Theme.amountColor(cents) : Color.primary)
    }
}

/// A small headline number.
struct MetricTile: View {
    let title: String
    let value: String
    let detail: String?
    let symbol: String
    var tint: Color = Theme.accent

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// A short colored label such as "Pending" or "Needs review".
struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct CategoryDot: View {
    let colorIndex: Int

    var body: some View {
        Circle()
            .fill(Theme.color(forCategoryIndex: colorIndex))
            .frame(width: 9, height: 9)
    }
}

/// Notes about what a report does and doesn't include. Always shown with results.
struct DataNotesView: View {
    let notes: [DataNote]

    var body: some View {
        if !notes.isEmpty {
            GroupBox("About these numbers") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes) { note in
                        Label(note.text, systemImage: note.severity == .warning ? "exclamationmark.circle" : "info.circle")
                            .foregroundStyle(note.severity == .warning ? Color.orange : Color.secondary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }
}

extension TransactionKind {
    var color: Color {
        switch self {
        case .expense: return Theme.spending
        case .income: return Theme.income
        case .transfer: return Color.secondary
        case .unknown: return Color.orange
        }
    }
}
