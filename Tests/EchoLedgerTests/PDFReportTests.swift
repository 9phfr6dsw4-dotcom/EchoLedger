import PDFKit
import XCTest
@testable import EchoLedgerCore
@testable import EchoLedgerPDF

@MainActor
final class PDFReportTests: XCTestCase {
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
        report.notes = (1...45).map { index in
            DataNote(id: "note-\(index)", severity: .info,
                     text: "NOTE_\(index)_START " + Array(repeating: "A fictional coverage explanation that must remain readable.", count: 9).joined(separator: " ") + " NOTE_\(index)_END")
        }
        let content = PDFReportContent(report: report, ledger: household.ledger, summary: ["Summary survives."], summaryIsAI: true)
        for style in PDFReportStyle.allCases {
            let pdf = try XCTUnwrap(PDFDocument(data: ReportPDF.data(content: content, style: style)))
            let text = try XCTUnwrap(pdf.string)
            XCTAssertGreaterThan(pdf.pageCount, 8)
            XCTAssertTrue(text.contains("Example account 40"))
            XCTAssertTrue(text.contains("every number was checked"))
            for index in 1...45 {
                for marker in ["NOTE_\(index)_START", "NOTE_\(index)_END"] {
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
