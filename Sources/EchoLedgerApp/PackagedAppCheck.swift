import AppKit
import EchoLedgerCore
import EchoLedgerPDF
import PDFKit

/// CI-only entry point, always using a separate fictional demo ledger.
/// Exercises the installed app's resource lookup rather than SwiftPM's build folder.
@MainActor
enum PackagedAppCheck {
    private struct CheckFailed: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(runtime: LedgerRuntime) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--check-package"), runtime.isDemo,
              let index = arguments.firstIndex(of: "--check-output"),
              arguments.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard runtime.section == .transactions, runtime.errorMessage == nil,
                  MerchantIconCatalog.brands.count > 3_000,
                  let logo = MerchantIconCatalog.logoURL(for: "spotify"),
                  let resources = Bundle.main.resourceURL,
                  logo.standardizedFileURL.path.hasPrefix(resources.standardizedFileURL.path + "/") else {
                throw CheckFailed("The installed app did not load its bundled merchant catalog from Contents/Resources.")
            }
            let consumerNames = ["Costco", "In-N-Out", "Trader Joe's", "Panera Bread",
                                 "Marshalls", "Ulta Beauty", "Xfinity", "Mister Car Wash"]
            for name in consumerNames + ["Spotify", "Example Cafe", "Sample Market", "Local Artisan"] {
                let descriptor = MerchantIconCatalog.descriptor(name: name)
                if consumerNames.contains(name) {
                    guard let asset = descriptor.logo, asset.hasPrefix("consumer-"),
                          MerchantIconCatalog.logoURL(for: asset) != nil else {
                        throw CheckFailed("The installed app is missing consumer artwork.")
                    }
                }
                let image = MerchantIconArtwork.image(for: descriptor)
                guard image.tiffRepresentation != nil else { throw CheckFailed("Merchant artwork did not render.") }
            }
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CheckFailed("The demo Transactions window did not render.")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let screenshot = bitmap.representation(using: .png, properties: [:]) else {
                throw CheckFailed("The demo Transactions window could not be recorded.")
            }
            try screenshot.write(to: folder.appendingPathComponent("transactions.png"))

            let end = runtime.today.firstOfMonth.adding(days: -1)
            let filter = ReportFilter(span: DateSpan(start: end.firstOfMonth, end: end))
            let report = ReportEngine.build(runtime.ledger, filter: filter, today: runtime.today)
            let content = PDFReportContent(report: report, ledger: runtime.ledger, summary: [])
            for style in PDFReportStyle.allCases {
                let data = try ReportPDF.data(content: content, style: style)
                guard let pdf = PDFDocument(data: data), pdf.pageCount > 0,
                      pdf.string?.contains("Sample Market") == true else {
                    throw CheckFailed("The installed app could not export its fictional merchant report.")
                }
                try data.write(to: folder.appendingPathComponent("\(style.rawValue).pdf"))
            }
            let result: [String: Any] = ["status": "passed", "brands": MerchantIconCatalog.brands.count,
                                         "section": runtime.section.rawValue, "pdfStyles": PDFReportStyle.allCases.count]
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                .write(to: folder.appendingPathComponent("completed.json"), options: .atomic)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: folder.appendingPathComponent("failed.txt"))
        }
    }
}
