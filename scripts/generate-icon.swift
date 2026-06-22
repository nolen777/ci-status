import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetURL = root.appendingPathComponent("Packaging/CIStatus.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let outputs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in outputs {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size),
            pixelsHigh: Int(size),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw NSError(domain: "CIStatusIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(size: size)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CIStatusIcon", code: 2)
    }

    try png.write(to: iconsetURL.appendingPathComponent(filename))
}

private func drawIcon(size: CGFloat) {
    let scale = size / 1024
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    bounds.fill()

    let shadow = NSShadow()
    shadow.shadowBlurRadius = 44 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -18 * scale)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()

    let tileRect = bounds.insetBy(dx: 72 * scale, dy: 72 * scale)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 210 * scale, yRadius: 210 * scale)
    NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.17, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.03)
    ])
    gloss?.draw(in: tile, angle: 90)

    drawStatusOrb(center: CGPoint(x: 512 * scale, y: 520 * scale), radius: 278 * scale, scale: scale)
    drawBadge(center: CGPoint(x: 752 * scale, y: 760 * scale), radius: 86 * scale, color: .systemGreen, symbol: "checkmark", scale: scale)
    drawBadge(center: CGPoint(x: 260 * scale, y: 248 * scale), radius: 70 * scale, color: .systemRed, symbol: "xmark", scale: scale)
}

private func drawStatusOrb(center: CGPoint, radius: CGFloat, scale: CGFloat) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let orb = NSBezierPath(ovalIn: rect)
    NSColor.systemBlue.setFill()
    orb.fill()

    NSColor.white.withAlphaComponent(0.35).setStroke()
    orb.lineWidth = 14 * scale
    orb.stroke()

    NSColor.white.setStroke()

    let lineWidth = 38 * scale
    let arcRadius = 105 * scale

    let upper = NSBezierPath()
    upper.lineWidth = lineWidth
    upper.lineCapStyle = .round
    upper.appendArc(withCenter: center, radius: arcRadius, startAngle: 142, endAngle: -18, clockwise: true)
    upper.stroke()

    let lower = NSBezierPath()
    lower.lineWidth = lineWidth
    lower.lineCapStyle = .round
    lower.appendArc(withCenter: center, radius: arcRadius, startAngle: -38, endAngle: -202, clockwise: true)
    lower.stroke()

    NSColor.white.setFill()
    drawArrowhead(at: CGPoint(x: center.x + 112 * scale, y: center.y - 36 * scale), angle: -28, size: 70 * scale)
    drawArrowhead(at: CGPoint(x: center.x - 112 * scale, y: center.y + 36 * scale), angle: 152, size: 70 * scale)
}

private func drawBadge(center: CGPoint, radius: CGFloat, color: NSColor, symbol: String, scale: CGFloat) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let badge = NSBezierPath(ovalIn: rect)
    color.setFill()
    badge.fill()

    NSColor.white.withAlphaComponent(0.8).setStroke()
    badge.lineWidth = 8 * scale
    badge.stroke()

    NSColor.white.setStroke()

    let mark = NSBezierPath()
    mark.lineWidth = max(8 * scale, radius * 0.16)
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round

    if symbol == "checkmark" {
        mark.move(to: CGPoint(x: center.x - radius * 0.42, y: center.y - radius * 0.02))
        mark.line(to: CGPoint(x: center.x - radius * 0.12, y: center.y - radius * 0.34))
        mark.line(to: CGPoint(x: center.x + radius * 0.45, y: center.y + radius * 0.34))
    } else {
        mark.move(to: CGPoint(x: center.x - radius * 0.36, y: center.y - radius * 0.36))
        mark.line(to: CGPoint(x: center.x + radius * 0.36, y: center.y + radius * 0.36))
        mark.move(to: CGPoint(x: center.x - radius * 0.36, y: center.y + radius * 0.36))
        mark.line(to: CGPoint(x: center.x + radius * 0.36, y: center.y - radius * 0.36))
    }

    mark.stroke()
}

private func drawArrowhead(at point: CGPoint, angle degrees: CGFloat, size: CGFloat) {
    let radians = degrees * .pi / 180
    let direction = CGPoint(x: cos(radians), y: sin(radians))
    let normal = CGPoint(x: -direction.y, y: direction.x)
    let base = CGPoint(x: point.x - direction.x * size, y: point.y - direction.y * size)

    let arrow = NSBezierPath()
    arrow.move(to: point)
    arrow.line(to: CGPoint(x: base.x + normal.x * size * 0.42, y: base.y + normal.y * size * 0.42))
    arrow.line(to: CGPoint(x: base.x - normal.x * size * 0.42, y: base.y - normal.y * size * 0.42))
    arrow.close()
    arrow.fill()
}
