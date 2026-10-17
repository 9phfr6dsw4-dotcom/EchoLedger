import AppKit
import XCTest
@testable import EchoLedgerCore

final class MerchantIconTests: XCTestCase {
    func testInstalledAppResolvesResourcesInsideContentsResources() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Example.app")
        let bundleURL = app.appendingPathComponent("Contents/Resources/EchoLedger_EchoLedgerCore.bundle")
        let icons = bundleURL.appendingPathComponent("MerchantIcons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        try Data("[{\"asset\":\"example\",\"names\":[\"Example Brand\"]}]".utf8)
            .write(to: icons.appendingPathComponent("catalog.json"))
        let bundle = try XCTUnwrap(MerchantIconCatalog.resourceBundle(in: app))
        XCTAssertEqual(bundle.bundleURL.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(MerchantIconCatalog.loadBrands(from: bundle).first?.names, ["Example Brand"])
    }

    func testMissingOrUnreadableResourceBundleReturnsEmptyCatalogWithoutTrapping() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(MerchantIconCatalog.resourceBundle(in: folder.appendingPathComponent("Absent.app")))
        XCTAssertTrue(MerchantIconCatalog.loadBrands(from: nil).isEmpty)
        let bundleURL = folder.appendingPathComponent("Example.app/Contents/Resources/EchoLedger_EchoLedgerCore.bundle")
        let icons = bundleURL.appendingPathComponent("MerchantIcons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertTrue(MerchantIconCatalog.loadBrands(from: bundle).isEmpty)
        try Data("invalid catalog".utf8).write(to: icons.appendingPathComponent("catalog.json"))
        XCTAssertTrue(MerchantIconCatalog.loadBrands(from: bundle).isEmpty)
    }

    func testExplicitResolvedNamesReceiveBrandArtwork() {
        for (name, logo) in [("Spotify", "spotify"), ("  SPOTIFY \n", "spotify"),
                             ("Apple Services", "apple"), ("Amazon Prime", "amazonprime"),
                             ("McDonald’s", "mcdonalds"), ("Uber Eats", "ubereats")] {
            XCTAssertEqual(MerchantIconCatalog.descriptor(name: name).logo, logo, name)
        }
        for name in ["Amazonas Cafe", "Apple Valley Market", "Spotify Support Services", "Not Netflix",
                     "Forever 21", "PAYPAL *SPOTIFY", "", "Sample Market"] {
            XCTAssertNil(MerchantIconCatalog.descriptor(name: name).logo, name)
        }
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "7-Eleven").initials, "7E")
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "Forever 21").initials, "F2")
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "").initials, "?")
        XCTAssertNil(MerchantIconCatalog.logoURL(for: "../catalog"))
    }

    func testConsumerBrandCoverageAndExplicitAliases() {
        let examples = [("In-N-Out", "in-n-out-burger"), ("In N Out Burger", "in-n-out-burger"),
                        ("Habit Burger", "habit-burger-grill"), ("The Habit", "habit-burger-grill"),
                        ("Black Bear Diner", "black-bear-diner"), ("Panera Bread", "panera-bread"),
                        ("Farmer Boys", "farmer-boys"), ("Wiener Schnitzel", "wienerschnitzel"),
                        ("Olive Garden", "olive-garden"), ("Wendy’s", "wendys"),
                        ("Carls Jr", "carls-jr"), ("Costco", "costco"), ("Costco Gas", "costco"),
                        ("Trader Joes", "trader-joes"), ("Save Mart", "save-mart"),
                        ("7-Eleven", "7-eleven"), ("Whole Foods", "whole-foods-market"),
                        ("Marshalls", "marshalls"), ("Ulta Beauty", "ulta-beauty"),
                        ("Xfinity", "xfinity"), ("Comcast Xfinity", "xfinity"),
                        ("Mister Car Wash", "mister-car-wash"), ("Mister Carwash", "mister-car-wash"),
                        ("Meijer", "meijer"), ("Hy-Vee", "hy-vee"), ("Wegmans", "wegmans"),
                        ("ShopRite", "shoprite"), ("Wawa", "wawa"), ("Culver’s", "culvers")]
        for (name, asset) in examples {
            XCTAssertEqual(MerchantIconCatalog.descriptor(name: name).logo, "consumer-" + asset, name)
        }
    }

    func testNumberedStoresWithoutGuessingFromOtherWords() {
        for name in ["Costco #0042", "COSTCO STORE 42", "Costco Store #42", "Costco 0042"] {
            XCTAssertEqual(MerchantIconCatalog.descriptor(name: name).logo, "consumer-costco", name)
        }
        for name in ["Costco Support", "Costco #42 Repair", "Costco Retail Partners", "Habit Cafe",
                     "Habit Exampleville", "Shellfish Kitchen", "Not Panera Bread", "Wendysmith"] {
            XCTAssertNil(MerchantIconCatalog.descriptor(name: name, categoryName: "Dining").logo, name)
        }
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "Costco #0042", kind: .transfer).logo, "prepared-person-payment")
    }

    func testDemoCategoryAndTransferFallbacks() {
        let cafe = MerchantIconCatalog.descriptor(name: "Example Cafe", categoryName: "Dining")
        XCTAssertNil(cafe.logo)
        XCTAssertEqual(cafe.symbol, "cup.and.saucer.fill")
        XCTAssertEqual(cafe, MerchantIconCatalog.descriptor(name: "Example Cafe"))
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "Local market", categoryName: "Groceries").symbol, "basket.fill")
        XCTAssertNil(MerchantIconCatalog.descriptor(name: "Local artisan").symbol)
        let transfer = MerchantIconCatalog.descriptor(name: "Apple", kind: .transfer)
        XCTAssertEqual(transfer.logo, "prepared-person-payment")
        XCTAssertEqual(transfer.symbol, "arrow.left.arrow.right")
    }

    func testCatalogResourcesAreCompleteAndNamesAreUnambiguous() throws {
        XCTAssertGreaterThan(MerchantIconCatalog.brands.count, 3_000)
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

    func testPreparedArtworkAndGenericPurposesAreAvailableOffline() throws {
        XCTAssertEqual(MerchantIconCatalog.prepared.count, 50)
        for item in MerchantIconCatalog.prepared {
            XCTAssertTrue(item.asset.hasPrefix("prepared-"))
            let url = try XCTUnwrap(MerchantIconCatalog.logoURL(for: item.asset))
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            XCTAssertEqual(image.pixelsWide, 192)
            XCTAssertEqual(image.pixelsHigh, 192)
            XCTAssertTrue(image.hasAlpha)
        }
        for (name, asset) in [("Example College Transcript", "diploma"),
                              ("Sample Donation", "donation"),
                              ("Example Background Check", "teacher-background-check"),
                              ("Example University Tuition", "university")] {
            XCTAssertEqual(MerchantIconCatalog.descriptor(name: name).logo, "prepared-" + asset)
        }
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "Capital One Transfer", kind: .transfer).logo,
                       "prepared-capital-one-transfer")
        for name in ["Transcription Studio", "Donationville Cafe", "Universityville Market"] {
            XCTAssertNil(MerchantIconCatalog.descriptor(name: name).logo)
        }
    }

    func testZelleArtworkOverridesCounterpartAndTransferFallbackWithoutChangingMoney() throws {
        var household = TestHousehold.make()
        let account = try XCTUnwrap(household.ledger.accounts.first)
        let category = try XCTUnwrap(household.ledger.category(named: "Dining"))
        let counterpart = Merchant(name: "Casey Example")
        household.ledger.merchants[counterpart.id] = counterpart
        for kind in [TransactionKind.transfer, .income, .expense, .unknown] {
            for amount in [Cents(-2500), Cents(2500)] {
                for text in ["Zelle payment from Casey Example", "zElLe TO CASEY EXAMPLE", "ZellePay transfer"] {
                    var item = LedgerTransaction(accountID: account.id, batchID: nil, sourceLine: 1,
                        date: day("2026-09-10"), postedDate: nil, amount: amount, currency: "USD",
                        rawDescription: text, status: .posted, fingerprint: UUID().uuidString, occurrence: 1)
                    item.kind = kind; item.categoryID = category.id; item.merchantID = counterpart.id
                    XCTAssertEqual(MerchantIconCatalog.descriptor(for: item, ledger: household.ledger).logo, "zelle")
                }
            }
        }
        XCTAssertEqual(MerchantIconCatalog.descriptor(name: "Zelle gift", kind: .income).logo, "zelle")
        for text in ["Gazelle", "Gazelle payment", "Zellex", "NotZellePay"] {
            XCTAssertFalse(MerchantIconCatalog.identifiesZelle(text))
        }
        var columnOnly = LedgerTransaction(accountID: account.id, batchID: nil, sourceLine: 1,
            date: day("2026-09-10"), postedDate: nil, amount: 2500, currency: "USD",
            rawDescription: "Payment from Casey Example", bankMerchant: "Zelle", status: .posted,
            fingerprint: UUID().uuidString, occurrence: 1)
        columnOnly.kind = .transfer
        XCTAssertEqual(MerchantIconCatalog.descriptor(for: columnOnly, ledger: household.ledger).logo, "zelle")
        columnOnly.bankMerchant = nil
        let savedZelle = Merchant(name: "Zelle payment")
        household.ledger.merchants[savedZelle.id] = savedZelle
        columnOnly.merchantID = savedZelle.id
        XCTAssertEqual(MerchantIconCatalog.descriptor(for: columnOnly, ledger: household.ledger).logo, "zelle")
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
        let names = ["Spotify", "Starbucks", "Amazon", "Apple Services", "Max", "YouTube TV",
                     "Costco", "Panera Bread", "Trader Joe's", "In-N-Out",
                     "College Transcript", "ATM", "Rent", "Zelle transfer", "Person Payment",
                     "Example Cafe", "Sample Market", "Local Artisan", ""]
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
