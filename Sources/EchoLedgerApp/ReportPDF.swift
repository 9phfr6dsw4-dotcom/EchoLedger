import Charts
import CoreGraphics
import EchoLedgerCore
import SwiftUI

struct PDFExportError: LocalizedError {
    var errorDescription: String? { "The PDF file couldn't be created at that location." }
}

/// Writes a multi-page, letter-size PDF of a report, drawn from the same report data as the
/// screen, so every figure matches.
@MainActor
enum ReportPDF {
    static let pageSize = CGSize(width: 612, height: 792)
    static let rowsPerPage = 30

    enum TableRow: Hashable {
        case category(name: String, colorIndex: Int, amount: Cents, count: Int, share: String)
        case merchant(name: String, amount: Cents, count: Int)
    }

    static func write(bundle: ReportBundle, ledger: Ledger, bullets: [GroundedBullet], who: String, to url: URL) throws {
        let report = bundle.report
        var pages: [AnyView] = [AnyView(PDFSummaryPage(bundle: bundle, bullets: bullets))]
        var rows: [TableRow] = []
        for line in report.categories {
            let share = Money.shareTenths(line.amount, of: report.spending).map { Money.percentText(tenths: $0) } ?? ""
            rows.append(.category(name: line.name, colorIndex: line.colorIndex, amount: line.amount, count: line.count, share: share))
            for merchant in line.merchants {
                rows.append(.merchant(name: merchant.name, amount: merchant.amount, count: merchant.count))
            }
        }
        var start = 0
        while start < rows.count {
            let chunk = Array(rows[start..<min(start + rowsPerPage, rows.count)])
            pages.append(AnyView(PDFTablePage(rows: chunk, isFirst: start == 0, total: report.spending)))
            start += rowsPerPage
        }
        pages.append(AnyView(PDFDetailsPage(bundle: bundle)))

        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw PDFExportError() }
        let header = "\(report.filter.span.label) · \(who) · \(report.filter.currency)"
        for (index, page) in pages.enumerated() {
            let framed = PDFPageFrame(header: header, pageNumber: index + 1, pageCount: pages.count, content: page)
                .frame(width: pageSize.width, height: pageSize.height)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: framed)
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
}

struct PDFPageFrame: View {
    let header: String
    let pageNumber: Int
    let pageCount: Int
    let content: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EchoLedger")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text(header)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Text("Made on this Mac by EchoLedger. Pending charges and transactions needing review aren't in the totals.")
                    .font(.system(size: 7.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Page \(pageNumber) of \(pageCount)")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 42)
        .padding(.vertical, 34)
    }
}

struct PDFSummaryPage: View {
    let bundle: ReportBundle
    let bullets: [GroundedBullet]

    var body: some View {
        let report = bundle.report
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(report.filter.span.label)
                    .font(.system(size: 24, weight: .semibold))
                Text("\(DateText.medium(report.filter.span.start)) to \(DateText.medium(report.filter.span.end)) · generated \(Date().formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text("Accounts: \(report.accountNames.isEmpty ? "none" : report.accountNames.joined(separator: ", "))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                pdfTile("Income", Money.format(report.income), Theme.income)
                pdfTile("Spending", Money.format(report.spending), Theme.spending)
                pdfTile("Saved", Money.format(report.savings) + (report.savingsRateTenths.map { " (\(Money.percentText(tenths: $0)))" } ?? ""), Theme.accent)
                pdfTile("Needs review", "\(report.unknownCount)", report.unknownCount == 0 ? Theme.income : Color.orange)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(bullets.isEmpty ? "Key facts" : "Summary")
                    .font(.system(size: 12, weight: .semibold))
                let lines = bullets.isEmpty ? bundle.facts.prefix(6).map(\.text) : bullets.map(\.text)
                ForEach(lines.indices, id: \.self) { index in
                    Text("•  \(lines[index])")
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !bullets.isEmpty {
                    Text("Written by Apple Intelligence on this Mac from EchoLedger's figures; every number was checked.")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            if !report.categories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spending by category")
                        .font(.system(size: 12, weight: .semibold))
                    Chart(Array(report.categories.prefix(10))) { line in
                        BarMark(x: .value("Spent", Theme.dollars(line.amount)), y: .value("Category", line.name))
                            .foregroundStyle(Theme.color(forCategoryIndex: line.colorIndex))
                            .annotation(position: .trailing) {
                                Text(Money.format(line.amount))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(min(report.categories.count, 10) * 22 + 10))
                }
            }
            if !report.notes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("About these numbers")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(report.notes) { note in
                        Text("•  \(note.text)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func pdfTile(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct PDFTablePage: View {
    let rows: [ReportPDF.TableRow]
    let isFirst: Bool
    let total: Cents

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isFirst ? "Categories and merchants" : "Categories and merchants (continued)")
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 10)
            HStack {
                Text("Category / merchant").frame(maxWidth: .infinity, alignment: .leading)
                Text("Count").frame(width: 50, alignment: .trailing)
                Text("Share").frame(width: 55, alignment: .trailing)
                Text("Spent").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            ForEach(rows.indices, id: \.self) { index in
                row(rows[index])
                Divider().opacity(0.4)
            }
        }
    }

    @ViewBuilder
    private func row(_ row: ReportPDF.TableRow) -> some View {
        switch row {
        case .category(let name, let colorIndex, let amount, let count, let share):
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(Theme.color(forCategoryIndex: colorIndex)).frame(width: 6, height: 6)
                    Text(name).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)").frame(width: 50, alignment: .trailing)
                Text(share).frame(width: 55, alignment: .trailing)
                Text(Money.format(amount)).fontWeight(.semibold).frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 9.5))
            .padding(.vertical, 4)
        case .merchant(let name, let amount, let count):
            HStack {
                Text(name).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)").frame(width: 50, alignment: .trailing)
                Text("").frame(width: 55)
                Text(Money.format(amount)).frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 9))
            .foregroundStyle(Color.primary.opacity(0.8))
            .padding(.vertical, 2.5)
        }
    }
}

struct PDFDetailsPage: View {
    let bundle: ReportBundle

    var body: some View {
        let report = bundle.report
        VStack(alignment: .leading, spacing: 16) {
            if report.months.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Month by month")
                        .font(.system(size: 14, weight: .semibold))
                    MonthBars(months: report.months)
                        .frame(height: 170)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Income sources")
                    .font(.system(size: 14, weight: .semibold))
                if report.incomeSources.isEmpty {
                    Text("No income in this period.").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                ForEach(report.incomeSources.prefix(12)) { source in
                    HStack {
                        Text(source.name)
                        Spacer()
                        Text(Money.format(source.amount))
                    }
                    .font(.system(size: 9.5))
                }
                HStack {
                    Text("Total income").fontWeight(.semibold)
                    Spacer()
                    Text(Money.format(report.income)).fontWeight(.semibold)
                }
                .font(.system(size: 9.5))
            }
            let active = bundle.recurring.filter(\.isActive)
            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recurring charges")
                        .font(.system(size: 14, weight: .semibold))
                    ForEach(active.prefix(14)) { charge in
                        HStack {
                            Text(charge.merchantName)
                            Text(charge.cadence.label.lowercased()).foregroundStyle(.secondary)
                            if charge.priceChanged {
                                Text("price changed").foregroundStyle(Color.orange)
                            }
                            Spacer()
                            Text(Money.format(charge.typicalAmount))
                        }
                        .font(.system(size: 9.5))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Not in the totals")
                    .font(.system(size: 14, weight: .semibold))
                Group {
                    Text("Transfers and card payments between your accounts: \(report.transferCount) (\(Money.format(report.transferVolume)) moved).")
                    Text("Needing review: \(report.unknownCount) transactions (\(Money.format(-report.unknownOut)) out, \(Money.format(report.unknownIn)) in).")
                    Text("Pending: \(report.pendingCount) charges (\(Money.format(report.pendingTotal))).")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }
        }
    }
}
