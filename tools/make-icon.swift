// Draws carnival.icns: the panel's sparkline taking a roller-coaster ride - a lift
// hill, a loop, and the dot of "now" at the end. carnival.swift draws the same track
// as the menu-bar glyph. Run: ./tools/make-icon.sh
import AppKit

let C: CGFloat = 1024                  // canvas; macOS art sits in an 824pt squircle
let inset: CGFloat = 100
let corner: CGFloat = 185

func squircle() -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: C - inset * 2, height: C - inset * 2),
                 xRadius: corner, yRadius: corner)
}

// `bold` is the cut for 16 and 32 px, where the regular stroke thins out below a pixel
func draw(bold: Bool) -> NSImage {
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

    let green = NSColor(srgbRed: 0.24, green: 0.82, blue: 0.35, alpha: 1)

    // the track lives on a 256-unit grid with y down; `at` places it in the squircle
    let s: CGFloat = bold ? 2.85 : 2.6
    func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 512 + (x - 126) * s, y: 548 - (y - 133.5) * s) }
    // Both ramps meet the loop at 45 degrees and cross at (154, 172.4). An arc that
    // starts away from the current point draws the straight ramp up to it for free.
    func track(loop: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: at(12, 190)); p.line(to: at(24, 190))
        p.curve(to: at(70, 70), controlPoint1: at(44, 190), controlPoint2: at(50, 70))        // lift hill
        p.curve(to: at(114.5, 197), controlPoint1: at(94, 70), controlPoint2: at(88, 197))
        p.appendArc(withCenter: at(114.5, 161), radius: 36 * s, startAngle: 270, endAngle: 315)
        if loop { p.appendArc(withCenter: at(154, 130), radius: 30 * s, startAngle: -45, endAngle: 225) }
        else { p.line(to: at(154, 172.4)) }
        p.appendArc(withCenter: at(193.5, 161), radius: 36 * s, startAngle: 225, endAngle: 270)
        p.curve(to: at(234, 140), controlPoint1: at(209.5, 197), controlPoint2: at(220, 154))
        return p
    }

    // the fill under the line, fading out the way the panel's sparklines do
    let area = track(loop: false)
    area.line(to: at(234, 262)); area.line(to: at(12, 262))
    area.close()
    NSGradient(colors: [green.withAlphaComponent(0.38), green.withAlphaComponent(0.01)])?.draw(in: area, angle: -90)

    green.setStroke()
    let line = track(loop: true)
    line.lineWidth = (bold ? 24 : 16) * s
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    line.stroke()

    green.setFill()
    let dot = (bold ? 19 : 14) * s, end = at(234, 140)
    NSBezierPath(ovalIn: NSRect(x: end.x - dot, y: end.y - dot, width: dot * 2, height: dot * 2)).fill()

    img.unlockFocus()
    return img
}

let master = draw(bold: false), small = draw(bold: true)
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    (px <= 32 ? small : master).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(dir)/icon_\(px).png"))
}
