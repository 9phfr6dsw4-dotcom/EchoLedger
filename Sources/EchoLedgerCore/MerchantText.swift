import Foundation

/// Reads a raw bank description and separates the merchant from the bank's boilerplate.
///
/// The original text is never changed or thrown away; this only produces extra forms for
/// matching:
/// - `normalized`: upper case with single spaces (what rules match against)
/// - `core`: bank wrappers removed ("PURCHASE AUTHORIZED ON 09/05 …", "… CARD 1234")
/// - `via` / `counterpart`: a payment service and the party behind it
///   ("PAYPAL *COINBASEINC" → via PayPal, counterpart COINBASEINC)
/// - `key`: a stable grouping key with store numbers, reference codes and a trailing state removed
public struct MerchantText: Sendable, Hashable {
    public let normalized: String
    public let core: String
    public let via: String?
    public let counterpart: String?
    public let key: String

    public init(_ raw: String) {
        let normalized = MerchantText.normalize(raw)
        self.normalized = normalized
        let core = MerchantText.stripWrappers(normalized)
        self.core = core
        var via: String?
        var counterpart: String?
        var base = MerchantText.stripFacilitator(core)
        for service in MerchantText.paymentServices {
            if let match = service.regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
               let range = Range(match.range(at: 1), in: base) {
                let party = String(base[range]).trimmingCharacters(in: .whitespaces)
                if !party.isEmpty {
                    via = service.name
                    counterpart = party
                    base = MerchantText.stripFacilitator(party)
                }
                break
            }
        }
        self.via = via
        self.counterpart = counterpart
        let key = MerchantText.makeKey(base)
        self.key = key.isEmpty ? MerchantText.lettersOnly(normalized) : key
    }

    /// A readable merchant name guessed from the key: "JOES DINER" → "Joes Diner".
    public var displayName: String {
        MerchantText.titleCase(key)
    }

    // MARK: Steps

    public static func normalize(_ raw: String) -> String {
        var words: [String] = []
        var current = ""
        for scalar in raw.uppercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "\u{00A0}" {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    nonisolated(unsafe) private static let leadingWrappers: [NSRegularExpression] = [
        regex(#"^(PURCHASE|PURCHASE INTL|RECURRING PAYMENT|PURCHASE RETURN|RETURN OF PURCHASE|REFUND|MONEY TRANSFER) AUTHORIZED ON \d{1,2}/\d{1,2} "#),
        regex(#"^(POS PURCHASE|POS DEBIT|POS|DEBIT CARD PURCHASE|DEBIT CARD|DEBIT PURCHASE|DBT CRD \d{4}|CHECKCARD( \d{4})?|CHECK CARD( \d{4})?|VISA DDA PUR|ACH DEBIT|ACH CREDIT|APLPAY|APL\*PAY|APPLE PAY)( -)? "#)
    ]

    nonisolated(unsafe) private static let trailingWrappers: [NSRegularExpression] = [
        regex(#" [SP]\d{9,} CARD \d{4}$"#),
        regex(#" CARD \d{4}$"#),
        regex(#" ON \d{1,2}/\d{1,2}\b.*$"#),
        regex(#" (WEB|PPD|CCD|TEL|IAT) ID: ?\S*$"#)
    ]

    public static func stripWrappers(_ normalized: String) -> String {
        var text = normalized
        for _ in 0..<3 {
            var changed = false
            for pattern in leadingWrappers {
                let replaced = pattern.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                if replaced != text, !replaced.isEmpty {
                    text = replaced
                    changed = true
                }
            }
            if !changed { break }
        }
        for pattern in trailingWrappers {
            let replaced = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            if !replaced.isEmpty { text = replaced }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Card-processing companies that print their code in front of the real merchant
    /// ("SQ *JOES COFFEE", "TST* SUNSET TACOS"). They are not the merchant, so they are dropped.
    nonisolated(unsafe) private static let facilitator = regex(
        #"^(SQ|TST|SPO|PY|PAR|FSP|BT|CKO|SMP|LS|POY|CLR|SAQ|TOAST|SUMUP|ZTL|HLU|EB) ?\* ?"#)
    nonisolated(unsafe) private static let shopify = regex(#"^SP (?=[A-Z0-9])"#)

    static func stripFacilitator(_ text: String) -> String {
        var result = facilitator.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        result = shopify.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? text : trimmed
    }

    struct PaymentService: @unchecked Sendable {
        let name: String
        let regex: NSRegularExpression
    }

    /// Services that move money on behalf of someone else. The party after the prefix is the real
    /// merchant or person; the service itself is only recorded as "via".
    nonisolated(unsafe) static let paymentServices: [PaymentService] = [
        PaymentService(name: "PayPal", regex: regex(#"^(?:PAYPAL ?\*|PP ?\*|PAYPAL INST XFER |PAYPAL TRANSFER )(.+)$"#)),
        PaymentService(name: "Venmo", regex: regex(#"^(?:VENMO ?\*|VENMO PAYMENT |VENMO CASHOUT )(.+)$"#)),
        PaymentService(name: "Cash App", regex: regex(#"^(?:SQC ?\*|CASH APP ?\*)(.+)$"#)),
        PaymentService(name: "Zelle", regex: regex(#"^ZELLE (?:PAYMENT |TRANSFER )?(?:TO|FROM) (.+)$"#)),
        PaymentService(name: "Google", regex: regex(#"^GOOGLE ?\*(.+)$"#)),
        PaymentService(name: "Apple Cash", regex: regex(#"^APPLE CASH (?:SENT|RECEIVED|TRANSFER) (?:TO |FROM )?(.+)$"#))
    ]

    nonisolated(unsafe) private static let referenceCode = regex(#"\*[A-Z0-9]*[0-9][A-Z0-9]*.*$"#)
    nonisolated(unsafe) private static let domainSuffix = regex(#"\.(COM|NET|ORG|CO|IO|US)\b"#)

    static let stateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA",
        "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK",
        "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "DC", "PR"
    ]

    nonisolated(unsafe) private static let webAddress = regex(#"/|\.[A-Z]{2,}"#)

    /// Store numbers, reference ids, card numbers and web addresses. Words at the very start are
    /// always kept ("24 HOUR FITNESS", "APPLE.COM/BILL").
    static func isReferenceToken(_ token: String) -> Bool {
        let digits = token.filter { $0 >= "0" && $0 <= "9" }.count
        let letters = token.filter { $0 >= "A" && $0 <= "Z" }.count
        if token.hasPrefix("#") { return true }
        if digits >= 3, letters == 0 { return true }
        if digits >= 4 { return true }
        if digits >= 2, letters >= 1, token.count >= 6 { return true }
        if digits >= 1, token.count >= 10 { return true }
        if webAddress.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil { return true }
        return false
    }

    public static func makeKey(_ text: String) -> String {
        let base = referenceCode.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        var tokens = base.split(separator: " ").map(String.init)
        if let cut = tokens.indices.dropFirst().first(where: { isReferenceToken(tokens[$0]) }) {
            tokens = Array(tokens[..<cut])
        }
        tokens = tokens.map { token in
            domainSuffix.stringByReplacingMatches(in: token, range: NSRange(token.startIndex..., in: token), withTemplate: "")
        }
        // Clean punctuation inside the remaining words.
        var words: [String] = []
        for token in tokens {
            var cleaned = ""
            for character in token {
                if (character >= "A" && character <= "Z") || (character >= "0" && character <= "9") || character == "&" {
                    cleaned.append(character)
                } else if character == "'" || character == "\u{2019}" {
                    continue
                } else {
                    cleaned.append(" ")
                }
            }
            words.append(contentsOf: cleaned.split(separator: " ").map(String.init))
        }
        if let last = words.last, last == "USA" || last == "US", words.count >= 3 {
            words.removeLast()
        }
        if let last = words.last, stateCodes.contains(last), words.count >= 3 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    static func lettersOnly(_ text: String) -> String {
        let mapped = text.map { ($0 >= "A" && $0 <= "Z") ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    public static func titleCase(_ key: String) -> String {
        key.split(separator: " ").map { word -> String in
            let text = String(word)
            let vowels = text.filter { "AEIOUY".contains($0) }.count
            if text.count <= 3, vowels == 0, text.allSatisfy({ $0 >= "A" && $0 <= "Z" }) {
                return text
            }
            return text.prefix(1).uppercased() + text.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            preconditionFailure("Invalid built-in pattern \(pattern): \(error)")
        }
    }
}

/// Fast literal phrase search with word boundaries, used for the merchant list and simple rules.
public enum PhraseSearch {
    /// True when `phrase` appears in `text` with no letter or digit directly before it, and none
    /// directly after it unless `allowSuffix` is set. Both must already be upper case.
    public static func contains(_ text: [UInt8], phrase: [UInt8], allowSuffix: Bool) -> Bool {
        guard !phrase.isEmpty, phrase.count <= text.count else { return false }
        let first = phrase[0]
        var start = 0
        let lastStart = text.count - phrase.count
        while start <= lastStart {
            if text[start] == first {
                var matched = true
                var offset = 1
                while offset < phrase.count {
                    if text[start + offset] != phrase[offset] {
                        matched = false
                        break
                    }
                    offset += 1
                }
                if matched {
                    let beforeOK = start == 0 || !isWordByte(text[start - 1]) || !isWordByte(first)
                    let endIndex = start + phrase.count
                    let afterOK = allowSuffix || endIndex == text.count || !isWordByte(text[endIndex])
                        || !isWordByte(phrase[phrase.count - 1])
                    if beforeOK && afterOK { return true }
                }
            }
            start += 1
        }
        return false
    }

    @inline(__always)
    static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
    }
}

/// Similarity between two merchant keys from 0 to 100 (an edit-distance ratio, with a boost when
/// one key is a whole-word prefix of the other). It is a hint for review, never proof.
public enum KeySimilarity {
    /// `floor`: scores that can't reach it may be reported as 0 without computing them (a
    /// length difference alone rules them out). Results at or above the floor are exact.
    public static func score(_ a: String, _ b: String, floor: Int = 0) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 100 }
        if floor > 0 {
            let lengthA = a.utf8.count
            let lengthB = b.utf8.count
            let longest = max(lengthA, lengthB)
            let prefixBoost = min(lengthA, lengthB) >= 4
                && (a.hasPrefix(b + " ") || b.hasPrefix(a + " "))
            if !prefixBoost, abs(lengthA - lengthB) * 100 > (100 - floor) * longest { return 0 }
        }
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        var previous = Array(0...y.count)
        var current = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let distance = previous[y.count]
        let longest = max(x.count, y.count)
        var result = (100 * (longest - distance) + longest / 2) / longest
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 4, long.hasPrefix(short + " ") {
            result = max(result, 90)
        }
        return result
    }
}
