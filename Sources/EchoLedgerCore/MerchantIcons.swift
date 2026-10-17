import Foundation

/// Presentation only: selecting artwork never classifies or changes a transaction.
public struct MerchantIconDescriptor: Hashable, Sendable {
    public enum Tone: String, Hashable, Sendable { case forest, sage, ochre, blue, terracotta, neutral }

    public let logo: String?
    public let symbol: String?
    public let initials: String
    public let tone: Tone
}

/// Explicit merchant names and numbered-store variants, without network access or fuzzy guesses.
public enum MerchantIconCatalog {
    private static let resourceBundleName = "EchoLedger_EchoLedgerCore.bundle"
    private final class BundleMarker: NSObject {}

    /// Installed apps keep SwiftPM resources in Contents/Resources. The generated
    /// Bundle.module accessor can trap before our optional fallback gets a chance to run.
    /// Resolve existing bundles explicitly instead, including SwiftPM's test layout.
    private static let resources: Bundle? = {
        if let installed = resourceBundle(in: Bundle.main.bundleURL) { return installed }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        let moduleHost = Bundle(for: BundleMarker.self).bundleURL
        let developmentHosts = [moduleHost, moduleHost.deletingLastPathComponent(),
                                Bundle.main.bundleURL.deletingLastPathComponent(),
                                Bundle.main.executableURL?.deletingLastPathComponent()]
        for host in developmentHosts.compactMap({ $0 }) {
            if let bundle = resourceBundle(in: host) { return bundle }
        }
        return nil
    }()

    static func resourceBundle(in host: URL) -> Bundle? {
        let candidates = [host.appendingPathComponent("Contents/Resources/" + resourceBundleName),
                          host.appendingPathComponent("Resources/" + resourceBundleName),
                          host.appendingPathComponent(resourceBundleName)]
        return candidates.lazy.compactMap { Bundle(url: $0) }.first
    }

    public struct Brand: Decodable, Sendable {
        public let asset: String
        public let names: [String]
    }

    static let prepared: [Brand] = loadBrands(from: resources, subdirectory: "PreparedMerchantIcons")
    public static let brands: [Brand] = {
        let preparedNames = Set(prepared.flatMap(\.names).map(key))
        return loadBrands(from: resources).map {
            Brand(asset: $0.asset, names: $0.names.filter { !preparedNames.contains(key($0)) })
        } + prepared
    }()

    static func loadBrands(from bundle: Bundle?, subdirectory: String = "MerchantIcons") -> [Brand] {
        guard let url = bundle?.url(forResource: "catalog", withExtension: "json", subdirectory: subdirectory),
              let data = try? Data(contentsOf: url),
              let brands = try? JSONDecoder().decode([Brand].self, from: data) else { return [] }
        return brands
    }

    private static let byName: [String: String] = {
        var result: [String: String] = [:]
        for brand in brands {
            for name in brand.names { result[key(name)] = brand.asset }
        }
        return result
    }()

    private static let assets = Set(brands.map(\.asset))
    private static let purposeAssets = Set([
        "atm", "capital-one-transfer", "car-payments", "cash-back-redemption-ref", "college-transcript",
        "daily-cash-adjustment", "donation", "interest-charge", "interest-charge-on-cash-advances",
        "interest-charge-on-purchases", "purchase-interest-charge", "late-fee", "political-donation",
        "pre-service-teacher", "rent", "teacher-background-check", "diploma", "person-payment",
        "family-payment", "university"
    ].map { "prepared-" + $0 })

    private static let defaultCategories: [String: String] = {
        var result: [String: String] = [:]
        for merchant in BuiltInKnowledge.merchants { result[key(merchant.name)] = merchant.category }
        return result
    }()

    // Fictional demo merchants get meaningful symbols without being mistaken for real brands.
    private static let demoSymbols: [String: (String, MerchantIconDescriptor.Tone)] = [
        "example activities": ("star.fill", .sage),
        "sample books": ("book.closed.fill", .terracotta),
        "example services": ("briefcase.fill", .sage),
        "sample goods": ("bag.fill", .terracotta),
        "example bus": ("bus.fill", .blue),
        "sample transit": ("tram.fill", .blue),
        "example kitchen": ("fork.knife", .ochre),
        "sample lunch": ("takeoutbag.and.cup.and.straw.fill", .ochre),
        "example cafe": ("cup.and.saucer.fill", .ochre),
        "sample market": ("basket.fill", .sage),
        "sample property rent": ("house.fill", .forest)
    ]

    public static func logoURL(for asset: String) -> URL? {
        // Only names from our catalog can select a bundled file.
        guard assets.contains(asset) else { return nil }
        let directory = asset.hasPrefix("prepared-") ? "PreparedMerchantIcons" : "MerchantIcons"
        return resources?.url(forResource: asset, withExtension: "png", subdirectory: directory)
    }

    public static func descriptor(name: String, categoryName: String? = nil,
                                  kind: TransactionKind = .expense) -> MerchantIconDescriptor {
        let nameKey = key(name)
        let initials = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let letters = initials.isEmpty ? "?" : initials
        let fallback: (String?, MerchantIconDescriptor.Tone)
        if kind == .transfer {
            fallback = ("arrow.left.arrow.right", .neutral)
        } else if let demo = demoSymbols[nameKey] {
            fallback = (demo.0, demo.1)
        } else {
            let category = key(categoryName ?? defaultCategories[nameKey] ?? "")
            switch category {
            case "housing": fallback = ("house.fill", .forest)
            case "groceries": fallback = ("basket.fill", .sage)
            case "dining": fallback = ("fork.knife", .ochre)
            case "transportation": fallback = ("car.fill", .blue)
            case "shopping": fallback = ("bag.fill", .terracotta)
            case "subscriptions": fallback = ("repeat", .sage)
            case "utilities": fallback = ("bolt.fill", .ochre)
            case "health": fallback = ("cross.case.fill", .sage)
            case "personal care": fallback = ("sparkles", .terracotta)
            case "entertainment": fallback = ("ticket.fill", .ochre)
            case "travel": fallback = ("airplane", .blue)
            case "education": fallback = ("book.closed.fill", .terracotta)
            default: fallback = (nil, kind == .income ? .forest : .neutral)
            }
        }
        let logo: String?
        if identifiesZelle(name) {
            logo = "zelle"
        } else if kind == .transfer {
            logo = purposeAsset(for: nameKey) ?? "prepared-person-payment"
        } else {
            logo = brandAsset(for: nameKey) ?? purposeAsset(for: nameKey)
        }
        return MerchantIconDescriptor(logo: logo,
                                      symbol: fallback.0, initials: letters, tone: fallback.1)
    }

    /// Generic artwork describes a payment purpose; it does not infer a company identity.
    private static func purposeAsset(for name: String) -> String? {
        if let exact = byName[name], purposeAssets.contains(exact) { return exact }
        if name.range(of: #"\bbackground\s+check\b"#, options: .regularExpression) != nil { return "prepared-teacher-background-check" }
        if name.range(of: #"\btranscript\b"#, options: .regularExpression) != nil { return "prepared-diploma" }
        if name.range(of: #"\bdonation\b"#, options: .regularExpression) != nil { return "prepared-donation" }
        if name.range(of: #"\buniversity(?:a)?\b"#, options: .regularExpression) != nil { return "prepared-university" }
        return nil
    }

    /// Presentation-only matching, deliberately independent of filing and reporting rules.
    static func identifiesZelle(_ text: String) -> Bool {
        key(text).range(of: #"\bzelle(?:pay)?\b"#, options: .regularExpression) != nil
    }

    private static func brandAsset(for name: String) -> String? {
        if let exact = byName[name] { return exact }
        // Only remove an explicit store identifier or a trailing 3+ digit store number.
        // Arbitrary trailing words (including locations) do not establish brand identity.
        let base = name.replacingOccurrences(of: #"\s+(?:(?:store\s*#?\s*|#\s*)\d+[a-z]?|\d{3,})$"#,
                                             with: "", options: .regularExpression)
        return base == name ? nil : byName[base]
    }

    public static func descriptor(for transaction: LedgerTransaction, ledger: Ledger) -> MerchantIconDescriptor {
        let identity = ReportEngine.merchantIdentity(transaction, ledger: ledger).name
        let savedName = transaction.merchantID.flatMap { ledger.merchants[$0]?.name } ?? ""
        let name = [identity, transaction.rawDescription, savedName, transaction.bankMerchant ?? ""].contains(where: identifiesZelle)
            ? "Zelle" : identity
        return descriptor(name: name, categoryName: ledger.category(transaction.categoryID)?.name, kind: transaction.kind)
    }

    /// Case, accents, and typographic apostrophes may vary; words and numbers stay intact.
    static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
