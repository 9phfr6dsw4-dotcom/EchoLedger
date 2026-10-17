import Foundation

/// Presentation only: selecting artwork never classifies or changes a transaction.
public struct MerchantIconDescriptor: Hashable, Sendable {
    public enum Tone: String, Hashable, Sendable { case forest, sage, ochre, blue, terracotta, neutral }

    public let logo: String?
    public let symbol: String?
    public let initials: String
    public let tone: Tone
}

/// Exact matches against resolved merchant names, with no network access or fuzzy brand guesses.
public enum MerchantIconCatalog {
    public struct Brand: Decodable, Sendable {
        public let asset: String
        public let names: [String]
    }

    public static let brands: [Brand] = {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json", subdirectory: "MerchantIcons"),
              let data = try? Data(contentsOf: url),
              let brands = try? JSONDecoder().decode([Brand].self, from: data) else { return [] }
        return brands
    }()

    private static let byName: [String: String] = {
        var result: [String: String] = [:]
        for brand in brands {
            for name in brand.names { result[key(name)] = brand.asset }
        }
        return result
    }()

    private static let assets = Set(brands.map(\.asset))

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
        return Bundle.module.url(forResource: asset, withExtension: "png", subdirectory: "MerchantIcons")
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
        return MerchantIconDescriptor(logo: kind == .transfer ? nil : byName[nameKey],
                                      symbol: fallback.0, initials: letters, tone: fallback.1)
    }

    public static func descriptor(for transaction: LedgerTransaction, ledger: Ledger) -> MerchantIconDescriptor {
        descriptor(name: ReportEngine.merchantIdentity(transaction, ledger: ledger).name,
                   categoryName: ledger.category(transaction.categoryID)?.name, kind: transaction.kind)
    }

    /// Case, accents, and typographic apostrophes may vary; words and numbers stay intact.
    static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
