import AppKit
import CoreGraphics
import EchoLedgerCore

public struct PDFExportError: LocalizedError {
    public var errorDescription: String? { "The PDF file couldn't be created at that location." }
}

/// Vector PDF drawing with measured text and explicit pagination; no app window or SwiftUI layout.
@MainActor
public enum ReportPDF {
    public static let pageSize = CGSize(width: 612, height: 792)

    public static func write(content: PDFReportContent, style: PDFReportStyle, to url: URL) throws {
        try data(content: content, style: style).write(to: url, options: .atomic)
    }

    public static func data(content: PDFReportContent, style: PDFReportStyle) throws -> Data {
        let layout = PDFLayout(content: content, style: style)
        layout.compose()
        let bytes = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [
                kCGPDFContextTitle: "EchoLedger · \(content.report.filter.span.label)",
                kCGPDFContextCreator: "EchoLedger",
                kCGPDFContextSubject: "\(content.report.scopeLabel) · \(style.name)"
              ] as CFDictionary) else { throw PDFExportError() }
        for (index, page) in layout.pages.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawFrame(page: page, index: index, count: layout.pages.count, context: context)
            for command in page.commands { command(context) }
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }
}

@MainActor
private final class PDFLayout {
    typealias Command = (CGContext) -> Void
    struct Page {
        var title: String
        var commands: [Command] = []
    }

    let content: PDFReportContent
    let style: PDFReportStyle
    var pages: [Page] = []
    var y: CGFloat = 120
    let left: CGFloat = 42
    let width: CGFloat = 528
    let bottom: CGFloat = 718
    var sectionNumber = 0
    let green = NSColor(srgbRed: 0.10, green: 0.29, blue: 0.21, alpha: 1)
    let sage = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.44, alpha: 1)
    let pale = NSColor(srgbRed: 0.93, green: 0.96, blue: 0.93, alpha: 1)
    let ink = NSColor(srgbRed: 0.09, green: 0.14, blue: 0.12, alpha: 1)
    let muted = NSColor(srgbRed: 0.34, green: 0.39, blue: 0.36, alpha: 1)
    let ruleColor = NSColor(srgbRed: 0.78, green: 0.82, blue: 0.79, alpha: 1)

    init(content: PDFReportContent, style: PDFReportStyle) {
        self.content = content
        self.style = style
    }

    var report: Report { content.report }
    func amount(_ cents: Cents) -> String { Money.format(cents, currency: report.filter.currency) }
    func share(_ cents: Cents) -> String {
        Money.shareTenths(cents, of: report.spending).map { Money.percentText(tenths: $0) } ?? "—"
    }
    func bodyFont(_ size: CGFloat = 10, bold: Bool = false) -> NSFont {
        .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
    func headingFont(_ size: CGFloat) -> NSFont {
        if style == .signature { return NSFont(name: "Georgia", size: size) ?? bodyFont(size, bold: true) }
        return bodyFont(size, bold: true)
    }
    func numberFont(_ size: CGFloat = 10, bold: Bool = false) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    func attributes(font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }
    func height(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font: font, color: ink)).height) + 2
    }
    func text(_ string: String, rect: CGRect, font: NSFont, color: NSColor? = nil,
              alignment: NSTextAlignment = .left) {
        let attrs = attributes(font: font, color: color ?? ink, alignment: alignment)
        pages[pages.count - 1].commands.append { _ in
            (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        }
    }
    func fill(_ rect: CGRect, color: NSColor, radius: CGFloat = 0) {
        pages[pages.count - 1].commands.append { context in
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
    }
    func rule(at top: CGFloat) {
        fill(CGRect(x: left, y: top, width: width, height: 0.6), color: ruleColor)
    }
    func newPage(_ title: String) {
        pages.append(Page(title: title))
        y = 120
    }
    func ensure(_ needed: CGFloat, continuation: String = "Report continued") {
        if y + needed > bottom { newPage(continuation) }
    }

    /// Splits even a long unbroken string, without dropping text or crossing the footer.
    func fittingPrefix(_ string: String, width: CGFloat, font: NSFont, maxHeight: CGFloat) -> String {
        if height(string, width: width, font: font) <= maxHeight { return string }
        let chars = Array(string)
        var low = 1, high = chars.count
        while low < high {
            let middle = (low + high + 1) / 2
            if height(String(chars.prefix(middle)), width: width, font: font) <= maxHeight { low = middle }
            else { high = middle - 1 }
        }
        var end = low
        if end < chars.count, let space = chars.prefix(end).lastIndex(where: { $0.isWhitespace }), space > end / 2 {
            end = space + 1
        }
        return String(chars.prefix(max(1, end)))
    }
    func paragraph(_ string: String, font: NSFont? = nil, color: NSColor? = nil, gap: CGFloat = 10,
                   continuation: String = "Report continued") {
        let font = font ?? bodyFont()
        var remaining = string
        while !remaining.isEmpty {
            ensure(24, continuation: continuation)
            let part = fittingPrefix(remaining, width: width, font: font, maxHeight: bottom - y)
            let h = height(part, width: width, font: font)
            text(part, rect: CGRect(x: left, y: y, width: width, height: h), font: font, color: color)
            y += h
            remaining.removeFirst(part.count)
            if !remaining.isEmpty { newPage(continuation) }
        }
        y += gap
    }
    func section(_ title: String, reserve: CGFloat = 40) {
        let label = style == .precision ? String(format: "%02d  %@", sectionNumber + 1, title) : title
        let font = headingFont(style == .signature ? 19 : 14)
        let h = height(label, width: width, font: font)
        ensure(14 + h + 12 + reserve, continuation: title)
        sectionNumber += 1
        rule(at: y)
        y += 14
        text(label, rect: CGRect(x: left, y: y, width: width, height: h), font: font, color: green)
        y += h + 12
    }

    func compose() {
        newPage("Report overview")
        let title: String
        switch style {
        case .signature: title = "Your finances,\nin perspective."
        case .everyday: title = "Your report,\nat a glance"
        case .precision: title = "Financial statement"
        }
        paragraph(title, font: headingFont(style == .precision ? 27 : 32), color: green, gap: 12)
        paragraph("\(report.filter.span.label) · \(report.filter.currency)", font: bodyFont(13, bold: true), gap: 6)
        paragraph("\(DateText.medium(report.filter.span.start)) – \(DateText.medium(report.filter.span.end))\nScope: \(report.scopeLabel)", color: muted, gap: 18)
        metrics()
        section("Spending by category", reserve: 100)
        if report.categories.isEmpty { paragraph("No spending in this period.", color: muted) }
        else if style == .everyday && canUseRing {
            ring()
        } else {
            categoryBars()
        }
        if !content.summary.isEmpty {
            section(content.summaryIsAI ? "Summary" : "Key facts")
            for line in content.summary { paragraph("•  " + line, continuation: "Summary continued") }
            if content.summaryIsAI {
                paragraph("Written by Apple Intelligence on this Mac from EchoLedger's figures; every number was checked.",
                          font: bodyFont(8.5), color: muted)
            }
        }
        if !content.allocation.isEmpty {
            section("Spending assignment", reserve: 70)
            paragraph("Within this report; each expense is counted once. Assignments can differ from who uses a card.",
                      font: bodyFont(9), color: muted)
            tableHeader(heading: "Spending assignment")
            for line in content.allocation {
                tableRow(name: line.name, count: "", value: amount(line.amount), share: share(line.amount), heading: "Spending assignment")
            }
            totalRow("Total spending", value: report.spending)
        }
        newPage("Categories and merchants")
        section("Categories and merchants", reserve: 70)
        tableHeader()
        if report.categories.isEmpty { paragraph("No spending in this period.", color: muted) }
        for category in report.categories {
            // Do not orphan a category heading at the bottom of a page.
            let firstMerchantHeight = category.merchants.first.map { rowHeight($0.name, indent: 12, hasIcon: true) } ?? 0
            tableSpace(rowHeight(category.name) + min(firstMerchantHeight, 180), heading: "Categories and merchants")
            tableRow(name: category.name, count: "\(category.count)", value: amount(category.amount), share: share(category.amount),
                     heading: "Categories and merchants", bold: true)
            for merchant in category.merchants {
                tableRow(name: merchant.name, count: "\(merchant.count)", value: amount(merchant.amount), share: "",
                         heading: "Categories and merchants", indent: 12,
                         icon: content.merchantIcon(name: merchant.name, transactionIDs: merchant.transactionIDs))
            }
        }
        totalRow("Total spending", value: report.spending)
        newPage("Income and report details")
        if report.months.count > 1 {
            section("Month by month", reserve: 60)
            monthHeader()
            for month in report.months {
                if y + 30 > bottom { newPage("Month by month continued"); monthHeader() }
                let h: CGFloat = 26
                text(DateText.monthLabel(month.monthKey), rect: CGRect(x: left, y: y + 5, width: 180, height: h), font: bodyFont())
                for (index, value) in [month.income, month.spending, month.net].enumerated() {
                    moneyText(amount(value), x: left + 192 + CGFloat(index) * 112, top: y + 5, width: 108)
                }
                y += h
                rule(at: y)
            }
        }
        section("Income sources", reserve: 60)
        if report.incomeSources.isEmpty { paragraph("No income in this period.", color: muted) }
        if !report.incomeSources.isEmpty { tableHeader(heading: "Income sources") }
        for line in report.incomeSources {
            tableRow(name: line.name, count: "\(line.count)", value: amount(line.amount), share: "", heading: "Income sources",
                     icon: content.merchantIcon(name: line.name, transactionIDs: line.transactionIDs))
        }
        totalRow("Total income", value: report.income)
        if !content.recurring.isEmpty {
            section("Recurring charges", reserve: 60)
            tableHeader(heading: "Recurring charges")
            for charge in content.recurring {
                let detail = "\(charge.merchantName) · \(charge.cadence.label)" + (charge.priceChanged ? " · price changed" : "")
                tableRow(name: detail, count: "", value: amount(charge.typicalAmount), share: "", heading: "Recurring charges",
                         icon: content.merchantIcon(name: charge.merchantName, transactionIDs: charge.transactionIDs))
            }
        }
        section("About these numbers")
        if report.giftsReceived > 0 {
            paragraph("Income includes \(amount(report.giftsReceived)) of gifts received, which EchoLedger shows as its own line.", continuation: "About these numbers continued")
        }
        paragraph("Posted transactions only. Transfers and card payments are excluded from income and spending. Refunds reduce spending. Apple Intelligence filings that are already counted remain marked in the report notes.")
        paragraph("Transfers and card payments: \(report.transferCount) transactions (\(amount(report.transferVolume)) moved).\nNeeding review: \(report.unknownCount) transactions (\(amount(-report.unknownOut)) out; \(amount(report.unknownIn)) in).\nPending: \(report.pendingCount) charges (\(amount(report.pendingTotal))).", continuation: "About these numbers continued")
        for note in report.notes { paragraph("•  " + note.text, color: muted, continuation: "About these numbers continued") }
        section("Report coverage")
        paragraph("Scope: \(report.scopeLabel)\nCurrency: \(report.filter.currency)\nAccounts: " + (report.accountNames.isEmpty ? "None" : report.accountNames.joined(separator: "; ")), color: muted, continuation: "Report coverage continued")
        paragraph("Generated \(content.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(style.name) style\nMade on this Mac by EchoLedger.", font: bodyFont(9), color: muted)
    }

    func metrics() {
        ensure(90)
        let tileWidth: CGFloat = 168
        for (index, item) in [("INCOME", report.income), ("SPENDING", report.spending), ("NET CASH FLOW", report.savings)].enumerated() {
            let x = left + CGFloat(index) * 180
            if style == .everyday { fill(CGRect(x: x, y: y, width: tileWidth, height: 80), color: pale, radius: 7) }
            text(item.0, rect: CGRect(x: x + 8, y: y + 10, width: 152, height: 16), font: bodyFont(8, bold: true), color: muted)
            moneyText(amount(item.1), x: x + 8, top: y + 30, width: 152, size: 23, bold: true, color: green)
            if index == 2, let rate = report.savingsRateTenths {
                text("\(Money.percentText(tenths: rate)) of income", rect: CGRect(x: x + 8, y: y + 60, width: 152, height: 16), font: bodyFont(8), color: muted)
            }
        }
        y += 98
    }
    func moneyText(_ value: String, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat = 10,
                   bold: Bool = false, color: NSColor? = nil) {
        var size = size
        while size > 7 && (value as NSString).size(withAttributes: [.font: numberFont(size, bold: bold)]).width > width { size -= 0.5 }
        text(value, rect: CGRect(x: x, y: top, width: width, height: max(20, size + 6)), font: numberFont(size, bold: bold), color: color, alignment: .right)
    }

    func categoryBars() {
        let maximum = max(1, report.categories.map { abs(Double($0.amount)) }.max() ?? 1)
        for line in report.categories {
            let labelHeight = height(line.name, width: 155, font: bodyFont())
            // Exceptionally long names use the same splitting path as report notes.
            let separateLabel = labelHeight > 90
            if separateLabel { paragraph(line.name, font: bodyFont(10, bold: true), gap: 4, continuation: "Spending by category continued") }
            let h = separateLabel ? 30 : max(30, labelHeight + 10)
            ensure(h, continuation: "Spending by category continued")
            if !separateLabel {
                text(line.name, rect: CGRect(x: left, y: y + 4, width: 155, height: labelHeight), font: bodyFont())
            }
            let bar = CGRect(x: left + 165, y: y + 8, width: 190, height: 11)
            fill(bar, color: pale, radius: style == .everyday ? 4 : 0)
            fill(CGRect(x: bar.minX, y: bar.minY, width: 190 * abs(Double(line.amount)) / maximum, height: bar.height), color: line.amount < 0 ? muted : sage)
            moneyText(amount(line.amount), x: left + 365, top: y + 4, width: 95)
            moneyText(share(line.amount), x: left + 468, top: y + 4, width: 60)
            y += h
        }
        paragraph("Net spending after refunds · negative amounts represent net refunds.", font: bodyFont(8), color: muted)
    }
    var ringLines: [(name: String, amount: Cents)] {
        let lines = report.categories.map { (name: $0.name, amount: $0.amount) }
        if lines.count <= 7 { return lines }
        return Array(lines.prefix(6)) + [(name: "Other categories (\(lines.count - 6))", amount: lines.dropFirst(6).reduce(0) { $0 + $1.amount })]
    }
    var canUseRing: Bool {
        report.spending > 0 && report.categories.allSatisfy { $0.amount >= 0 }
            && ringLines.allSatisfy { height($0.name, width: 190, font: bodyFont()) <= 18 }
    }
    func ringColor(_ index: Int) -> NSColor {
        index == 0 ? green : sage.blended(withFraction: CGFloat(index) * 0.09, of: pale) ?? sage
    }
    func ring() {
        ensure(190, continuation: "Spending by category")
        let center = CGPoint(x: left + 85, y: y + 85)
        let categories = ringLines
        let total = Double(report.spending)
        let colors = categories.indices.map { ringColor($0) }
        pages[pages.count - 1].commands.append { context in
            var angle = -Double.pi / 2
            for (index, line) in categories.enumerated() {
                guard line.amount > 0 else { continue }
                let next = angle + Double(line.amount) / total * 2 * .pi
                context.setStrokeColor(colors[index].cgColor)
                context.setLineWidth(22)
                context.addArc(center: center, radius: 66, startAngle: angle, endAngle: next, clockwise: false)
                context.strokePath()
                angle = next
            }
        }
        text("TOTAL SPENDING", rect: CGRect(x: left + 32, y: y + 64, width: 106, height: 17), font: bodyFont(7.5, bold: true), color: muted, alignment: .center)
        moneyText(amount(report.spending), x: left + 29, top: y + 84, width: 112, size: 16, bold: true)
        for (index, line) in categories.enumerated() {
            let top = y + CGFloat(index) * 25
            fill(CGRect(x: left + 186, y: top + 3, width: 8, height: 8), color: colors[index], radius: 4)
            text(line.name, rect: CGRect(x: left + 202, y: top, width: 190, height: 20), font: bodyFont())
            moneyText(amount(line.amount), x: left + 400, top: top, width: 128)
        }
        y += 195
        if report.categories.count > 7 {
            paragraph("Smaller categories are grouped in this chart. Every category appears separately in the detailed ledger.", font: bodyFont(8), color: muted)
        }
    }

    func tableHeader(heading: String = "Categories and merchants") {
        let label: String
        switch heading {
        case "Spending assignment": label = "ASSIGNED TO"
        case "Income sources": label = "INCOME SOURCE"
        case "Recurring charges": label = "MERCHANT / FREQUENCY"
        default: label = "CATEGORY / MERCHANT"
        }
        fill(CGRect(x: left, y: y, width: width, height: 24), color: pale)
        text(label, rect: CGRect(x: left + 6, y: y + 6, width: 285, height: 16), font: bodyFont(8, bold: true), color: muted)
        let countLabel = heading == "Spending assignment" || heading == "Recurring charges" ? "" : "COUNT"
        let shareLabel = heading == "Income sources" || heading == "Recurring charges" ? "" : "SHARE"
        for (label, x, w) in [(countLabel, left + 292, CGFloat(48)), ("AMOUNT", left + 350, CGFloat(104)), (shareLabel, left + 466, CGFloat(56))] {
            text(label, rect: CGRect(x: x, y: y + 6, width: w, height: 16), font: bodyFont(8, bold: true), color: muted, alignment: .right)
        }
        y += 28
    }
    func monthHeader() {
        text("MONTH", rect: CGRect(x: left, y: y, width: 180, height: 20), font: bodyFont(8, bold: true), color: muted)
        for (index, label) in ["INCOME", "SPENDING", "NET CASH FLOW"].enumerated() {
            text(label, rect: CGRect(x: left + 192 + CGFloat(index) * 112, y: y, width: 108, height: 20), font: bodyFont(8, bold: true), color: muted, alignment: .right)
        }
        y += 23
        rule(at: y - 3)
    }
    func rowHeight(_ name: String, indent: CGFloat = 0, hasIcon: Bool = false) -> CGFloat {
        max(25, height(name, width: 280 - indent - (hasIcon ? 22 : 0), font: bodyFont()) + 12)
    }
    func tableSpace(_ h: CGFloat, heading: String) {
        if y + h > bottom {
            newPage(heading + " continued")
            tableHeader(heading: heading)
        }
    }
    func tableRow(name: String, count: String, value: String, share: String, heading: String,
                  bold: Bool = false, indent: CGFloat = 0, icon: MerchantIconDescriptor? = nil) {
        let iconWidth: CGFloat = icon == nil ? 0 : 22
        let textWidth = 280 - indent - iconWidth
        var remaining = name
        var first = true
        repeat {
            let part = fittingPrefix(remaining, width: textWidth, font: bodyFont(10, bold: bold), maxHeight: 160)
            let h = max(25, height(part, width: textWidth, font: bodyFont(10, bold: bold)) + 12)
            tableSpace(h, heading: heading)
            if bold { fill(CGRect(x: left, y: y, width: width, height: h), color: pale, radius: style == .everyday ? 3 : 0) }
            text(part, rect: CGRect(x: left + 6 + indent + iconWidth, y: y + 6, width: textWidth, height: h - 8), font: bodyFont(10, bold: bold))
            if first {
                if let icon {
                    let image = MerchantIconArtwork.image(for: icon)
                    let rect = CGRect(x: left + 6 + indent, y: y + 5, width: 16, height: 16)
                    pages[pages.count - 1].commands.append { _ in
                        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                   respectFlipped: true, hints: nil)
                    }
                }
                moneyText(count, x: left + 292, top: y + 6, width: 48)
                moneyText(value, x: left + 350, top: y + 6, width: 104, bold: bold)
                moneyText(share, x: left + 466, top: y + 6, width: 56)
            }
            y += h
            rule(at: y)
            remaining.removeFirst(part.count)
            first = false
        } while !remaining.isEmpty
    }
    func totalRow(_ label: String, value: Cents) {
        ensure(38, continuation: label)
        y += 4
        fill(CGRect(x: left, y: y, width: width, height: 28), color: pale)
        text(label, rect: CGRect(x: left + 6, y: y + 7, width: 280, height: 20), font: bodyFont(10, bold: true))
        moneyText(amount(value), x: left + 350, top: y + 7, width: 104, bold: true)
        y += 40
    }

    /// The same nested echo geometry as the existing app icon, drawn in one ink for print.
    func drawBrandMark(context: CGContext, color: NSColor) {
        context.saveGState()
        context.translateBy(x: left - 7, y: 22)
        context.scaleBy(x: 0.03, y: 0.03)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(64)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for index in 0..<3 {
            let path = CGMutablePath()
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
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    func drawFrame(page: Page, index: Int, count: Int, context: CGContext) {
        context.setFillColor((style == .signature ? NSColor(srgbRed: 0.993, green: 0.989, blue: 0.976, alpha: 1) : .white).cgColor)
        context.fill(CGRect(origin: .zero, size: ReportPDF.pageSize))
        if style == .everyday {
            context.setFillColor(green.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 612, height: 62))
        }
        let headerColor: NSColor = style == .everyday ? .white : green
        let headerAttributes = attributes(font: bodyFont(15, bold: true), color: headerColor)
        ("EchoLedger" as NSString).draw(in: CGRect(x: left + 25, y: 27, width: 150, height: 23), withAttributes: headerAttributes)
        drawBrandMark(context: context, color: headerColor)
        let runningTitle = "\(style.name) · \(page.title)"
        (runningTitle as NSString).draw(in: CGRect(x: 230, y: 30, width: 340, height: 18), withAttributes: attributes(font: bodyFont(8), color: headerColor, alignment: .right))
        let scope = report.scopeLabel.count > 105 ? String(report.scopeLabel.prefix(102)) + "…" : report.scopeLabel
        let metadata = "\(report.filter.span.label) · \(report.filter.currency)\n\(scope)"
        (metadata as NSString).draw(with: CGRect(x: left, y: 72, width: width, height: 40), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(font: bodyFont(8.5), color: muted))
        context.setFillColor(ruleColor.cgColor)
        context.fill(CGRect(x: left, y: 733, width: width, height: 0.6))
        let footer = "Posted only · Transfers excluded · Refunds netted"
        (footer as NSString).draw(in: CGRect(x: left, y: 745, width: 390, height: 16), withAttributes: attributes(font: bodyFont(7.5), color: muted))
        ("\(index + 1) / \(count)" as NSString).draw(in: CGRect(x: 490, y: 744, width: 80, height: 17), withAttributes: attributes(font: numberFont(8), color: muted, alignment: .right))
    }
}
