// Draws carnival.icns: a ferris wheel, the most legible piece of carnival
// iconography that still reads as a dial at 16pt. Run: ./tools/make-icon.sh
import AppKit

let C: CGFloat = 1024                  // canvas; macOS art sits in an 824pt squircle
let inset: CGFloat = 100
let corner: CGFloat = 185

func squircle() -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: C - inset * 2, height: C - inset * 2),
                 xRadius: corner, yRadius: corner)
}

func draw() -> NSImage {
    let img = NSImage(size: NSSize(width: C, height: C))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    let body = squircle()
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.21, blue: 0.22, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)])?
        .draw(in: body, angle: -90)
    NSColor(white: 1, alpha: 0.09).setStroke()
    body.lineWidth = 3
    body.stroke()

    let cx: CGFloat = 512, cy: CGFloat = 585, R: CGFloat = 252
    let green = NSColor(srgbRed: 0.24, green: 0.82, blue: 0.35, alpha: 1)
    let steel = NSColor(srgbRed: 0.60, green: 0.62, blue: 0.65, alpha: 1)

    // legs, clipped out of the wheel's interior so they do not clutter the spokes
    ctx.saveGState()
    let mask = squircle()
    mask.append(NSBezierPath(ovalIn: NSRect(x: cx - R + 12, y: cy - R + 12, width: (R - 12) * 2, height: (R - 12) * 2)))
    mask.windingRule = .evenOdd
    mask.setClip()
    steel.setStroke()
    let legs = NSBezierPath()
    legs.lineWidth = 34
    legs.lineCapStyle = .round
    legs.move(to: NSPoint(x: cx - 158, y: 150)); legs.line(to: NSPoint(x: cx, y: cy))
    legs.move(to: NSPoint(x: cx + 158, y: 150)); legs.line(to: NSPoint(x: cx, y: cy))
    legs.stroke()
    ctx.restoreGState()
    steel.setFill()
    NSBezierPath(roundedRect: NSRect(x: cx - 214, y: 122, width: 428, height: 38),
                 xRadius: 19, yRadius: 19).fill()

    // gondolas, hung outside the rim
    let cabin: CGFloat = 8
    for i in 0..<Int(cabin) {
        let a = CGFloat(i) / cabin * .pi * 2 - .pi / 2   // seat 0 sits at the bottom
        let p = NSPoint(x: cx + cos(a) * (R + 42), y: cy + sin(a) * (R + 42))
        green.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: NSRect(x: p.x - 36, y: p.y - 29, width: 72, height: 58),
                     xRadius: 22, yRadius: 22).fill()
    }

    // spokes
    green.setStroke()
    let spokes = NSBezierPath()
    spokes.lineWidth = 16
    spokes.lineCapStyle = .round
    for i in 0..<Int(cabin) {
        let a = CGFloat(i) / cabin * .pi * 2 - .pi / 2   // seat 0 sits at the bottom
        spokes.move(to: NSPoint(x: cx, y: cy))
        spokes.line(to: NSPoint(x: cx + cos(a) * R, y: cy + sin(a) * R))
    }
    spokes.stroke()

    // rim
    let rim = NSBezierPath(ovalIn: NSRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2))
    rim.lineWidth = 34
    green.setStroke()
    rim.stroke()

    // hub
    NSColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 52, y: cy - 52, width: 104, height: 104)).fill()
    green.setStroke()
    let hub = NSBezierPath(ovalIn: NSRect(x: cx - 52, y: cy - 52, width: 104, height: 104))
    hub.lineWidth = 22
    hub.stroke()

    img.unlockFocus()
    return img
}

let master = draw()
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(dir)/icon_\(px).png"))
}
