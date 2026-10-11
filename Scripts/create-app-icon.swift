import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: create-app-icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

/// A ring segment from `start` to `end` degrees (counterclockwise, 0 = right), as a closed path.
func ringSegment(center: NSPoint, outer: CGFloat, inner: CGFloat, start: CGFloat, end: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
    path.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
    path.close()
    return path
}

/// Draws the EchoLedger icon on a 1024-point canvas: the family's navy rounded square, a
/// donut chart with a blue-to-cyan arc and a white slice, and three white ledger lines inside.
func drawIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0.07, 0.09, 0.16).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let background = NSGradient(
        colors: [color(0.05, 0.07, 0.13), color(0.08, 0.11, 0.19), color(0.30, 0.36, 0.49)],
        atLocations: [0, 0.55, 1],
        colorSpace: .deviceRGB
    )
    background?.draw(in: bodyPath, angle: 90)
    color(1, 1, 1, 0.08).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    rim.lineWidth = 3
    rim.stroke()

    let center = NSPoint(x: 512, y: 512)
    let glyphGradient = NSGradient(
        colors: [color(0.17, 0.49, 0.94), color(0.35, 0.72, 1.0), color(0.55, 0.88, 1.0)],
        atLocations: [0, 0.5, 1],
        colorSpace: .deviceRGB
    )
    // Blue-to-cyan arc: most of the ring.
    let arc = ringSegment(center: center, outer: 262, inner: 172, start: 96, end: 374)
    glyphGradient?.draw(in: arc, angle: 90)
    // White slice in the upper right.
    color(0.97, 0.98, 1.0).setFill()
    ringSegment(center: center, outer: 262, inner: 172, start: 22, end: 88).fill()

    // Three ledger lines in the middle.
    let lines: [(y: CGFloat, width: CGFloat)] = [(558, 150), (512, 112), (466, 132)]
    for line in lines {
        let rect = NSRect(x: 512 - 75, y: line.y - 11, width: line.width, height: 22)
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
    }
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
