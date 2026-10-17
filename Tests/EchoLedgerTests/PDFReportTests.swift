import PDFKit
import XCTest
@testable import EchoLedgerCore
@testable import EchoLedgerPDF

@MainActor
final class PDFReportTests: XCTestCase {
    func testEveryStyleEmbedsMerchantArtworkAndPreservesTheIconSnapshot() throws {
        let household = TestHousehold.make()
        let report = household.report()
        let recurring = Insights.recurring(household.ledger, filter: report.filter, asOf: report.filter.span.end)
        let content = PDFReportContent(report: report, ledger: household.ledger, summary: [], recurring: recurring)
        for category in report.categories {
            for merchant in category.merchants {
                let transaction = try XCTUnwrap(merchant.transactionIDs.first.flatMap { household.ledger.transactions[$0] })
                XCTAssertEqual(content.merchantIcon(name: merchant.name, transactionIDs: merchant.transactionIDs),
                               MerchantIconCatalog.descriptor(for: transaction, ledger: household.ledger))
            }
        }
        for style in PDFReportStyle.allCases {
            let data = try ReportPDF.data(content: content, style: style)
            let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
            let document = try XCTUnwrap(CGPDFDocument(provider))
            var count = 0
            for index in 1...document.numberOfPages {
                let page = try XCTUnwrap(document.page(at: index))
                var resources: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(page.dictionary, "Resources", &resources), let resources {
                    count += embeddedImages(in: resources)
                }
            }
            // Core Graphics can reuse an image XObject for repeated merchant marks.
            XCTAssertGreaterThan(count, 0, "\(style.name) omitted merchant artwork")
            let text = try XCTUnwrap(PDFDocument(data: data)?.string)
            for category in report.categories {
                for merchant in category.merchants {
                    XCTAssertTrue(text.contains(merchant.name))
                    XCTAssertTrue(text.contains(Money.format(merchant.amount)))
                }
            }
        }
    }

    func testEveryStylePreservesAmountsScopeAndAllDetailRows() throws {
        let household = TestHousehold.make()
        let report = household.report()
        let content = PDFReportContent(report: report, ledger: household.ledger, summary: ["Synthetic report summary."],
                                       generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(content.allocation.reduce(Cents(0)) { $0 + $1.amount }, report.spending)
        var documents: [Data] = []
        for style in PDFReportStyle.allCases {
            let bytes = try ReportPDF.data(content: content, style: style)
            documents.append(bytes)
            let pdf = try XCTUnwrap(PDFDocument(data: bytes))
            let text = try XCTUnwrap(pdf.string)
            XCTAssertGreaterThanOrEqual(pdf.pageCount, 3)
            for required in [style.name, report.scopeLabel, report.filter.currency, Money.format(report.income),
                             Money.format(report.spending), Money.format(report.savings), "Synthetic report summary.",
                             "Income sources", "Needing review:", "Pending:", "Report coverage"] {
                XCTAssertTrue(text.contains(required), "\(style.name) omitted \(required)")
            }
            for category in report.categories {
                XCTAssertTrue(text.contains(category.name))
                XCTAssertTrue(text.contains(Money.format(category.amount)))
                for merchant in category.merchants { XCTAssertTrue(text.contains(merchant.name), merchant.name) }
            }
            for source in report.incomeSources { XCTAssertTrue(text.contains(source.name), source.name) }
            for index in 0..<pdf.pageCount {
                let page = try XCTUnwrap(pdf.page(at: index))
                XCTAssertEqual(page.bounds(for: .mediaBox).size, ReportPDF.pageSize)
                XCTAssertTrue(page.string?.contains("\(index + 1) / \(pdf.pageCount)") == true)
                XCTAssertTrue(page.string?.contains(report.scopeLabel) == true)
            }
        }
        XCTAssertNotEqual(documents[0], documents[1])
        XCTAssertNotEqual(documents[1], documents[2])
    }

    func testLongNotesAndNamesContinueWithoutClippingOrLosingRows() throws {
        let household = TestHousehold.make()
        var report = household.report()
        report.categories[0].name = Array(repeating: "Long category name", count: 8).joined(separator: " ")
        report.categories[0].merchants[0].name = Array(repeating: "Long merchant name", count: 16).joined(separator: " ")
        report.accountNames = (1...40).map { "Example account \($0) with an intentionally long name" }
        // Plain markers avoid PDFKit reordering the low underscore glyphs during extraction.
        // Each note's first and last marker still must survive, inside the printable body.
        report.notes = (1...45).map { index in
            DataNote(id: "note-\(index)", severity: .info,
                     text: "Note\(index)start " + Array(repeating: "A fictional coverage explanation that must remain readable.", count: 9).joined(separator: " ") + " Note\(index)end")
        }
        let content = PDFReportContent(report: report, ledger: household.ledger, summary: ["Summary survives."], summaryIsAI: true)
        for style in PDFReportStyle.allCases {
            let pdf = try XCTUnwrap(PDFDocument(data: ReportPDF.data(content: content, style: style)))
            let text = try XCTUnwrap(pdf.string)
            XCTAssertGreaterThan(pdf.pageCount, 8)
            XCTAssertTrue(text.contains("Example account 40"))
            XCTAssertTrue(text.contains("every number was checked"))
            for index in 1...45 {
                for marker in ["Note\(index)start", "Note\(index)end"] {
                    XCTAssertTrue(text.contains(marker), "\(style.name) lost \(marker)")
                    let matches = pdf.findString(marker, withOptions: .literal)
                    XCTAssertFalse(matches.isEmpty)
                    for match in matches {
                        for page in match.pages {
                            // PDFKit uses bottom-left coordinates; body ends 74pt above the page edge.
                            XCTAssertGreaterThan(match.bounds(for: page).minY, 65, marker)
                            XCTAssertLessThan(match.bounds(for: page).maxY, 680, marker)
                        }
                    }
                }
            }
            XCTAssertTrue(text.contains("Categories and merchants continued"))
        }
    }

    func testPeopleAndCardFiltersUseTheSnapshotWithoutDoubleCounting() throws {
        let household = TestHousehold.make()
        for mode in [PeopleMode.assigned, .cards] {
            let filter = ReportFilter(span: TestHousehold.september, personIDs: [household.sam.id], peopleMode: mode)
            let report = ReportEngine.build(household.ledger, filter: filter, today: TestHousehold.today)
            let content = PDFReportContent(report: report, ledger: household.ledger, summary: [])
            XCTAssertEqual(content.allocation.reduce(Cents(0)) { $0 + $1.amount }, report.spending)
            for style in PDFReportStyle.allCases {
                let pdf = try XCTUnwrap(PDFDocument(data: ReportPDF.data(content: content, style: style)))
                let text = try XCTUnwrap(pdf.string)
                XCTAssertTrue(text.contains(report.scopeLabel))
                XCTAssertTrue(text.contains(Money.format(report.spending)))
                XCTAssertFalse(text.contains("Scope: Whole household"))
            }
        }
    }

    func testEmptyAndNetRefundReportsAreFiniteAndReadable() throws {
        let household = TestHousehold.make()
        var empty = household.report()
        empty.income = 0; empty.spending = 0
        empty.categories = []; empty.incomeSources = []; empty.includedIDs = []
        empty.notes = []; empty.months = []
        for style in PDFReportStyle.allCases {
            let data = try ReportPDF.data(content: PDFReportContent(report: empty, ledger: household.ledger, summary: []), style: style)
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            let text = try XCTUnwrap(pdf.string)
            XCTAssertTrue(text.contains("No spending in this period."))
            XCTAssertTrue(text.contains("No income in this period."))
            XCTAssertFalse(text.contains("NaN"))
        }
        var refund = household.report()
        refund.categories = [refund.categories[0]]
        refund.categories[0].amount = -500
        refund.spending = -500
        let pdf = try XCTUnwrap(PDFDocument(data: ReportPDF.data(content: PDFReportContent(report: refund, ledger: household.ledger, summary: []), style: .everyday)))
        XCTAssertTrue(pdf.string?.contains(Money.format(-500)) == true)
        XCTAssertTrue(pdf.string?.contains("negative amounts represent net refunds") == true)
    }

    func testNonUSDCurrencyAndCategoryNameLongerThanAPage() throws {
        let household = TestHousehold.make()
        var report = household.report()
        report.filter.currency = "EUR"
        // The fixture's original prose notes contain USD amounts; this test changes only the
        // numeric report fields to EUR, so do not carry over those unrelated USD sentences.
        report.notes = []
        report.categories[0].name = "CATEGORYSTART " + Array(repeating: "An unusually long fictional category label", count: 120).joined(separator: " ") + " CATEGORYEND"
        for style in PDFReportStyle.allCases {
            let pdf = try XCTUnwrap(PDFDocument(data: ReportPDF.data(content: PDFReportContent(report: report, ledger: household.ledger, summary: []), style: style)))
            let text = try XCTUnwrap(pdf.string)
            XCTAssertTrue(text.contains(Money.format(report.spending, currency: "EUR")))
            XCTAssertFalse(text.contains("$"))
            for marker in ["CATEGORYSTART", "CATEGORYEND"] {
                XCTAssertTrue(text.contains(marker))
                for selection in pdf.findString(marker, withOptions: .literal) {
                    for page in selection.pages {
                        XCTAssertGreaterThan(selection.bounds(for: page).minY, 65)
                        XCTAssertLessThan(selection.bounds(for: page).maxY, 680)
                    }
                }
            }
        }
    }

    func testMonthRowsAndIncomeBeyondTheOldLimitsAreRetained() throws {
        let household = TestHousehold.make()
        var report = household.report(span: DateSpan(start: day("2025-01-01"), end: day("2026-09-30")))
        let source = try XCTUnwrap(report.incomeSources.first)
        report.incomeSources = (1...30).map { index in
            var row = source
            row.id = "source-\(index)"; row.name = "Fictional income source \(index)"
            return row
        }
        for style in PDFReportStyle.allCases {
            let pdf = try XCTUnwrap(PDFDocument(data: ReportPDF.data(content: PDFReportContent(report: report, ledger: household.ledger, summary: []), style: style)))
            let text = try XCTUnwrap(pdf.string)
            XCTAssertTrue(text.contains("Fictional income source 30"))
            for month in report.months { XCTAssertTrue(text.contains(DateText.monthLabel(month.monthKey))) }
        }
    }
}

/// Count embedded raster artwork through image and form XObjects, independently of text output.
private func embeddedImages(in resources: CGPDFDictionaryRef) -> Int {
    var objects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return 0 }
    var count = 0
    CGPDFDictionaryApplyFunction(objects, { _, object, info in
        guard let info else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
        let dictionary = CGPDFStreamGetDictionary(stream)
        var subtype: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
            info.assumingMemoryBound(to: Int.self).pointee += 1
        } else {
            var nested: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                info.assumingMemoryBound(to: Int.self).pointee += embeddedImages(in: nested)
            }
        }
    }, &count)
    return count
}
