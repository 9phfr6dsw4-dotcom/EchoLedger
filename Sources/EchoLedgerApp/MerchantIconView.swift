import EchoLedgerCore
import SwiftUI

/// Decorative: the adjacent merchant name supplies the accessible label.
struct MerchantIconView: View {
    let descriptor: MerchantIconDescriptor
    var size: CGFloat = 24

    init(name: String, categoryName: String? = nil, kind: TransactionKind = .expense, size: CGFloat = 24) {
        descriptor = MerchantIconCatalog.descriptor(name: name, categoryName: categoryName, kind: kind)
        self.size = size
    }

    init(descriptor: MerchantIconDescriptor, size: CGFloat = 24) {
        self.descriptor = descriptor
        self.size = size
    }

    var body: some View {
        Image(nsImage: MerchantIconArtwork.image(for: descriptor))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            .accessibilityHidden(true)
    }
}

/// Reports use the same transaction context as the table, including custom categories.
struct MerchantReportIcon: View {
    @Environment(LedgerRuntime.self) private var runtime
    let name: String
    let transactionIDs: [UUID]
    var size: CGFloat = 24

    var body: some View {
        let descriptor = transactionIDs.lazy.compactMap { runtime.ledger.transactions[$0] }.first
            .map { MerchantIconCatalog.descriptor(for: $0, ledger: runtime.ledger) }
            ?? MerchantIconCatalog.descriptor(name: name)
        MerchantIconView(descriptor: descriptor, size: size)
    }
}
