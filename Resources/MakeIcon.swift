import AppKit

// A chat bubble (its one tight corner is the tail) carrying a forward arrow: a WeChat chat being passed on.
// Flat colours only. Drawn on the macOS icon grid (824/1024 tile with a drop shadow).
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

let tileColor = color(0xFFFFFF), tileBorder = color(0x000000, 0.10)
let bubbleColor = color(0x1D1D1F) // alternatives tried: green 0x0F9D6B, blue 0x2D6BF6

/// Rounded rect whose bottom-left corner is tight, so the shape reads as a speech bubble without a drawn tail.
func bubblePath(_ r: NSRect, radius big: CGFloat, tail small: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX + small, y: r.minY))
    p.line(to: NSPoint(x: r.maxX - big, y: r.minY))
    p.appendArc(withCenter: NSPoint(x: r.maxX - big, y: r.minY + big), radius: big, startAngle: 270, endAngle: 360)
    p.line(to: NSPoint(x: r.maxX, y: r.maxY - big))
    p.appendArc(withCenter: NSPoint(x: r.maxX - big, y: r.maxY - big), radius: big, startAngle: 0, endAngle: 90)
    p.line(to: NSPoint(x: r.minX + big, y: r.maxY))
    p.appendArc(withCenter: NSPoint(x: r.minX + big, y: r.maxY - big), radius: big, startAngle: 90, endAngle: 180)
    p.line(to: NSPoint(x: r.minX, y: r.minY + small))
    p.appendArc(withCenter: NSPoint(x: r.minX + small, y: r.minY + small), radius: small, startAngle: 180, endAngle: 270)
    p.close()
    return p
}

/// Forward arrow: rises from the lower left, bends right and ends in an open head.
func arrowPath() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 400, y: 410))
    p.line(to: NSPoint(x: 400, y: 470))
    p.curve(to: NSPoint(x: 520, y: 590), controlPoint1: NSPoint(x: 400, y: 536), controlPoint2: NSPoint(x: 454, y: 590))
    p.line(to: NSPoint(x: 590, y: 590))
    p.move(to: NSPoint(x: 572, y: 680))
    p.line(to: NSPoint(x: 668, y: 590))
    p.line(to: NSPoint(x: 572, y: 500))
    // Scale to ~82% around the stroke's visual centre and place it on the bubble's centre.
    var t = AffineTransform(translationByX: 512, byY: 512)
    t.scale(0.82)
    t.translate(x: -534, y: -545)
    p.transform(using: t)
    p.lineWidth = 66 * 0.82
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    return p
}

func drawIcon(in g: CGContext) {
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor(white: 0, alpha: 0.20).cgColor)
    tileColor.setFill()
    tile.fill()
    g.restoreGState()
    g.saveGState()
    tile.addClip()
    tileBorder.setStroke()
    tile.lineWidth = 4
    tile.stroke()
    g.restoreGState()

    let bubble = bubblePath(NSRect(x: 252, y: 262, width: 520, height: 500), radius: 190, tail: 40)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor(white: 0, alpha: 0.12).cgColor)
    bubbleColor.setFill()
    bubble.fill()
    g.restoreGState()

    NSColor.white.setStroke()
    arrowPath().stroke()
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
