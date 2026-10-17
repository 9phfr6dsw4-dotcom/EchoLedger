import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: create-app-icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

/// Same vector geometry as AppIcon.icon and the in-app mark, rendered for Finder.
func drawIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.27, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.19, blue: 0.16, alpha: 1))?.draw(in: shape, angle: -90)
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: body.minX, y: body.maxY)
    context.scaleBy(x: body.width / 1024, y: -body.height / 1024)
    for index in 0..<3 {
        let path = CGMutablePath()
        if index == 0 {
            path.move(to: CGPoint(x: 770, y: 226)); path.addLine(to: CGPoint(x: 389, y: 226))
            path.addQuadCurve(to: CGPoint(x: 226, y: 389), control: CGPoint(x: 226, y: 226))
            path.addLine(to: CGPoint(x: 226, y: 635))
            path.addQuadCurve(to: CGPoint(x: 389, y: 798), control: CGPoint(x: 226, y: 798))
            path.addLine(to: CGPoint(x: 770, y: 798))
        } else if index == 1 {
            path.move(to: CGPoint(x: 770, y: 337)); path.addLine(to: CGPoint(x: 493, y: 337))
            path.addQuadCurve(to: CGPoint(x: 337, y: 493), control: CGPoint(x: 337, y: 337))
            path.addLine(to: CGPoint(x: 337, y: 531))
            path.addQuadCurve(to: CGPoint(x: 493, y: 687), control: CGPoint(x: 337, y: 687))
            path.addLine(to: CGPoint(x: 770, y: 687))
        } else {
            path.move(to: CGPoint(x: 770, y: 448)); path.addLine(to: CGPoint(x: 531, y: 448))
            path.addQuadCurve(to: CGPoint(x: 448, y: 512), control: CGPoint(x: 448, y: 448))
            path.addQuadCurve(to: CGPoint(x: 531, y: 576), control: CGPoint(x: 448, y: 576))
            path.addLine(to: CGPoint(x: 770, y: 576))
        }
        let color = index == 2 ? NSColor(srgbRed: 0.72, green: 0.87, blue: 0.77, alpha: 1)
            : NSColor(srgbRed: 0.95, green: 0.93, blue: 0.87, alpha: 1)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(64); context.setLineCap(.round); context.setLineJoin(.round)
        context.addPath(path); context.strokePath()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func renderIcon(pixelSize: Int, fileName: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "EchoLedgerIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create icon bitmap"])
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "EchoLedgerIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create icon graphics context"])
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixelSize) / 1024, y: CGFloat(pixelSize) / 1024)

    drawIcon()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "EchoLedgerIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon PNG"])
    }
    try data.write(to: iconsetURL.appendingPathComponent(fileName), options: .atomic)
}

let icons: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]
for (size, name) in icons {
    try renderIcon(pixelSize: size, fileName: name)
}
