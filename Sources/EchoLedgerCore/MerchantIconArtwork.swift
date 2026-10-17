#if canImport(AppKit)
import AppKit

/// Shared, cached artwork for SwiftUI and PDF drawing. All images are available offline.
@MainActor
public enum MerchantIconArtwork {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    public static func image(for descriptor: MerchantIconDescriptor) -> NSImage {
        let key = "\(descriptor.logo ?? "")|\(descriptor.symbol ?? "")|\(descriptor.initials)|\(descriptor.tone.rawValue)" as NSString
        if let image = cache.object(forKey: key) { return image }

        // Fixed light artwork keeps brands legible in dark mode and gives exports the same mark.
        let image = NSImage(size: NSSize(width: 96, height: 96))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: 96, height: 96)
        let logo = descriptor.logo.flatMap(MerchantIconCatalog.logoURL).flatMap { NSImage(contentsOf: $0) }
        let ink = color(descriptor.tone)
        (logo == nil ? ink.blended(withFraction: 0.88, of: .white) ?? .white : .white).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 19, yRadius: 19).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        if let logo {
            draw(logo, inside: bounds.insetBy(dx: 15, dy: 15))
        } else if let name = descriptor.symbol,
                  let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 48, weight: .medium)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))) {
            draw(symbol, inside: bounds.insetBy(dx: 24, dy: 24))
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: ink
            ]
            let text = descriptor.initials as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (96 - size.width) / 2, y: (96 - size.height) / 2), withAttributes: attributes)
        }
        image.unlockFocus()
        cache.setObject(image, forKey: key)
        return image
    }

    private static func draw(_ image: NSImage, inside rect: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func color(_ tone: MerchantIconDescriptor.Tone) -> NSColor {
        switch tone {
        case .forest: NSColor(srgbRed: 0.13, green: 0.33, blue: 0.24, alpha: 1)
        case .sage: NSColor(srgbRed: 0.35, green: 0.49, blue: 0.40, alpha: 1)
        case .ochre: NSColor(srgbRed: 0.57, green: 0.43, blue: 0.20, alpha: 1)
        case .blue: NSColor(srgbRed: 0.35, green: 0.47, blue: 0.58, alpha: 1)
        case .terracotta: NSColor(srgbRed: 0.61, green: 0.39, blue: 0.30, alpha: 1)
        case .neutral: NSColor(srgbRed: 0.41, green: 0.44, blue: 0.42, alpha: 1)
        }
    }
}
#endif
