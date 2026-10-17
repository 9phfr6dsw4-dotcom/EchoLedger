import AppKit
import XCTest
@testable import EchoLedgerCore

final class MerchantIconTests: XCTestCase {
    func testOnlyExactResolvedNamesReceiveBrandArtwork() {
        for (name, logo) in [("Spotify", "spotify"), ("  SPOTIFY \n", "spotify"),
                             ("Apple Services", "apple"), ("Amazon Prime", "amazon"),
                             ("McDonald’s", "mcdonalds"), ("Uber Eats", "ubereats")] {
            XCTAssertEqual(MerchantIconCatalog.descriptor(name: name).logo, logo, name)
        }
        for name in ["Amazonas Cafe", "Apple Valley Market", "Spotify Support Services", "Not Netflix",
                     "7-Eleven", "Forever 21", "PAYPAL *SPOTIFY", "", "Sample Market"] {
            XCTAssertNil(MerchantIconCatalog.descriptor(name: name).logo, name)
        }
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "7-Eleven").initials, "7E")
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "Forever 21").initials, "F2")
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "").initials, "?")
        XCTAssertNil(MerchantIconCatalog.logoURL(for: "../catalog"))
    }

    func testDemoCategoryAndTransferFallbacks() {
        let cafe = MerchantIconCatalog.descriptor(name: "Example Cafe", categoryName: "Dining")
        XCTAssertNil(cafe.logo)
        XCTAssertEqual(cafe.symbol, "cup.and.saucer.fill")
        XCTAssertEqual(cafe, MerchantIconCatalog.descriptor(name: "Example Cafe"))
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "Local market", categoryName: "Groceries").symbol, "basket.fill")
        XCTAssertNil(MerchantIconCatalog.descriptor(name: "Local artisan").symbol)
        let transfer = MerchantIconCatalog.descriptor(name: "Apple", kind: .transfer)
        XCTAssertNil(transfer.logo)
        XCTAssertEqual(transfer.symbol, "arrow.left.arrow.right")
    }

    func testCatalogResourcesAreCompleteAndNamesAreUnambiguous() throws {
        XCTAssertGreaterThanOrEqual(MerchantIconCatalog.brands.count, 48)
        var names: Set<String> = []
        var assets: Set<String> = []
        for brand in MerchantIconCatalog.brands {
            XCTAssertTrue(assets.insert(brand.asset).inserted, brand.asset)
            let url = try XCTUnwrap(MerchantIconCatalog.logoURL(for: brand.asset), brand.asset)
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)), brand.asset)
            XCTAssertEqual(image.pixelsWide, 192)
            XCTAssertEqual(image.pixelsHigh, 192)
            for name in brand.names {
                XCTAssertTrue(names.insert(MerchantIconCatalog.key(name)).inserted, name)
                XCTAssertEqual(MerchantIconCatalog.descriptor(name: name).logo, brand.asset)
            }
        }
    }

    func testUsesLedgerMerchantIdentityInsteadOfPaymentProcessor() throws {
        let household = TestHousehold.make()
        let transaction = try XCTUnwrap(household.ledger.transactions.values.first {
            $0.rawDescription.uppercased().contains("PAYPAL *COINBASE")
        })
        XCTAssertEqual(MerchantIconCatalog.descriptor(for: transaction, ledger: household.ledger).logo, "coinbase")
    }

    @MainActor
    func testAllBrandAndFallbackArtworkRendersAndIsCached() throws {
        let names = MerchantIconCatalog.brands.flatMap(\.names) + ["Example Cafe", "Sample Market", "Local Artisan", ""]
        for name in names {
            let descriptor = MerchantIconCatalog.descriptor(name: name)
            let image = MerchantIconArtwork.image(for: descriptor)
            XCTAssertEqual(image.size, NSSize(width: 96, height: 96))
            XCTAssertNotNil(image.tiffRepresentation, name)
            XCTAssertTrue(image === MerchantIconArtwork.image(for: descriptor))
        }
        // A missing logo must still render the category symbol, without a loading state.
        let missing = MerchantIconDescriptor(logo: "missing", symbol: "basket.fill", initials: "LM", tone: .sage)
        XCTAssertNotNil(MerchantIconArtwork.image(for: missing).tiffRepresentation)
    }
}
