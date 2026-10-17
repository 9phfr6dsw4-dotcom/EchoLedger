import AppKit
import EchoLedgerCore
import SwiftUI

/// Warm Ledger: cream surfaces, forest accents, and editorial financial typography.
enum Theme {
    static func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    static let canvas = adaptive((0.98, 0.97, 0.94), (0.08, 0.12, 0.11))
    static let sidebar = adaptive((0.93, 0.91, 0.87), (0.06, 0.10, 0.09))
    static let surface = adaptive((0.995, 0.99, 0.97), (0.11, 0.16, 0.14))
    static let accent = adaptive((0.13, 0.33, 0.24), (0.66, 0.87, 0.73))
    static let accentLight = Color(red: 0.66, green: 0.75, blue: 0.64)
    static let income = accent
    static let spending = adaptive((0.53, 0.30, 0.22), (0.91, 0.65, 0.49))
    static let neutral = Color.secondary
    static let palette: [Color] = [
        accent, Color(red: 0.48, green: 0.61, blue: 0.48),
        Color(red: 0.43, green: 0.55, blue: 0.51), Color(red: 0.68, green: 0.56, blue: 0.36),
        Color(red: 0.46, green: 0.57, blue: 0.66), Color(red: 0.66, green: 0.46, blue: 0.39),
        Color(red: 0.57, green: 0.52, blue: 0.65), Color(red: 0.57, green: 0.62, blue: 0.35)
    ]
    static func heading(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }

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
                .font(Theme.heading(38))
            Text(subtitle)
                .font(.system(size: 15))
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
            }
            .padding(32)
            .frame(maxWidth: 1400, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.canvas)
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
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(Theme.heading(36))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
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
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
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
/// The notes under a report. Notes about your files can be marked as fine, one by one or all
/// at once, and then stop showing; Settings brings them back.
struct DataNotesView: View {
    @Environment(LedgerRuntime.self) private var runtime
    let notes: [DataNote]

    private var acknowledgeable: [DataNote] { notes.filter { $0.acknowledgement != nil } }

    var body: some View {
        if !notes.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("About these numbers")
                            .font(.headline)
                        Spacer()
                        if acknowledgeable.count > 1 {
                            Button("Mark All as Fine") { acknowledge(acknowledgeable.compactMap(\.acknowledgement)) }
                                .help("Each file note is marked as fine and stops showing. Settings brings them back.")
                        }
                    }
                    ForEach(notes) { note in
                        row(note)
                    }
                    if !acknowledgeable.isEmpty {
                        Caption("Notes about your files are EchoLedger's guesses. If a card is just used now and then, mark it as fine and the note goes away.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ note: DataNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(note.text, systemImage: note.severity == .warning ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(note.severity == .warning ? Color.orange : Color.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions(note)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func actions(_ note: DataNote) -> some View {
        switch note.acknowledgement {
        case .upToDate(let accountID, let through):
            Menu("It's Fine") {
                Button("The file is complete through \(DateText.medium(through))") {
                    acknowledge([.upToDate(accountID: accountID, through: through)])
                }
                Button("This account is rarely used; don't warn about it again") {
                    acknowledge([.rarelyUsed(accountID: accountID)])
                }
            }
            .fixedSize()
        case .historyStart(let accountID, let date):
            Menu("It's Fine") {
                Button("That's when this account's history starts") {
                    acknowledge([.historyStart(accountID: accountID, on: date)])
                }
                Button("This account is rarely used; don't warn about it again") {
                    acknowledge([.rarelyUsed(accountID: accountID)])
                }
            }
            .fixedSize()
        case .rarelyUsed(let accountID):
            Button("It's Fine") { acknowledge([.rarelyUsed(accountID: accountID)]) }
                .help("This account is rarely used; don't warn about it again")
        case .dismiss(let key):
            Button("Got It") { acknowledge([.dismiss(key: key)]) }
        case .none:
            if note.id == "unknown" || note.id == "ai-filed" {
                Button("Review") { runtime.section = .review }
            }
        }
    }

    private func acknowledge(_ items: [DataNote.Acknowledgement]) {
        runtime.commit { $0.acknowledge(items) }
        runtime.statusMessage = "Marked as fine. To bring these notes back, use Settings → Report notes."
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


struct LedgerPanelStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            configuration.label.font(Theme.heading(21))
            configuration.content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)) }
    }
}

struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        Canvas { context, bounds in
            context.fill(Path(CGRect(origin: .zero, size: bounds)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.08, green: 0.27, blue: 0.22), Color(red: 0.05, green: 0.19, blue: 0.16)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: bounds.height)))
            let scale = bounds.width / 1024
            context.scaleBy(x: scale, y: scale)
            for index in 0..<3 {
                var path = Path()
                if index == 0 {
                    path.move(to: CGPoint(x: 770, y: 226)); path.addLine(to: CGPoint(x: 389, y: 226))
                    path.addQuadCurve(to: CGPoint(x: 226, y: 389), control: CGPoint(x: 226, y: 226))
                    path.addLine(to: CGPoint(x: 226, y: 635))
                    path.addQuadCurve(to: CGPoint(x: 389, y: 798), control: CGPoint(x: 226, y: 798))
                    path.addLine(to: CGPoint(x: 770, y: 798))
                } else if index == 1 {
                    path.move(to: CGPoint(x: 770, y: 337)); path.addLine(to: CGPoint(x: 493, y: 337))
                    path.addQuadCurve(to: CGPoint(x: 337, y: 493), control: CGPoint(x: 337, y: 337))
                    path.addLine(to: CGPoint(x: 337, y: 531))
                    path.addQuadCurve(to: CGPoint(x: 493, y: 687), control: CGPoint(x: 337, y: 687))
                    path.addLine(to: CGPoint(x: 770, y: 687))
                } else {
                    path.move(to: CGPoint(x: 770, y: 448)); path.addLine(to: CGPoint(x: 531, y: 448))
                    path.addQuadCurve(to: CGPoint(x: 448, y: 512), control: CGPoint(x: 448, y: 448))
                    path.addQuadCurve(to: CGPoint(x: 531, y: 576), control: CGPoint(x: 448, y: 576))
                    path.addLine(to: CGPoint(x: 770, y: 576))
                }
                let color = index == 2 ? Color(red: 0.72, green: 0.87, blue: 0.77) : Color(red: 0.95, green: 0.93, blue: 0.87)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 64, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
        .accessibilityHidden(true)
    }
}
