// Draws the AgentBench app icon (monochrome: A solid card vs B outlined card on
// a near-black squircle) to icon_1024.png. Run: swift Tools/make-icon.swift
import AppKit

let size: CGFloat = 1024
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// squircle background (leave margin for the standard macOS icon grid)
let M: CGFloat = 104
let inner = NSRect(x: M, y: M, width: size - 2*M, height: size - 2*M)
let bg = NSBezierPath(roundedRect: inner, xRadius: 183, yRadius: 183)
color(0x16161A).setFill(); bg.fill()
// subtle top sheen
let sheen = NSBezierPath(roundedRect: inner, xRadius: 183, yRadius: 183)
color(0xFFFFFF).withAlphaComponent(0.04).setFill(); sheen.fill()

// two cards
let cardW: CGFloat = 230, cardH: CGFloat = 460, gap: CGFloat = 56
let totalW = cardW*2 + gap
let startX = inner.minX + (inner.width - totalW)/2
let cardY = inner.minY + (inner.height - cardH)/2
let left  = NSRect(x: startX, y: cardY, width: cardW, height: cardH)
let right = NSRect(x: startX + cardW + gap, y: cardY, width: cardW, height: cardH)

// content lines inside a card
func lines(in r: NSRect, color c: NSColor) {
    let widths: [CGFloat] = [0.66, 0.44, 0.74, 0.5]
    for (i, w) in widths.enumerated() {
        let lh: CGFloat = 26
        let ly = r.maxY - 96 - CGFloat(i) * 56
        let lr = NSRect(x: r.minX + 34, y: ly, width: (r.width - 68) * w, height: lh)
        c.setFill(); NSBezierPath(roundedRect: lr, xRadius: 13, yRadius: 13).fill()
    }
}
// badge square at top of a card
func badge(in r: NSRect, fill: NSColor?, stroke: NSColor?) {
    let b = NSRect(x: r.minX + 34, y: r.maxY - 34 - 56, width: 56, height: 56)
    let p = NSBezierPath(roundedRect: b, xRadius: 14, yRadius: 14)
    if let fill { fill.setFill(); p.fill() }
    if let stroke { stroke.setStroke(); p.lineWidth = 7; p.stroke() }
}

// A — solid white card
let lp = NSBezierPath(roundedRect: left, xRadius: 30, yRadius: 30)
NSColor.white.setFill(); lp.fill()
badge(in: left, fill: color(0x16161A), stroke: nil)
lines(in: NSRect(x: left.minX, y: left.minY, width: left.width, height: left.height - 78),
      color: color(0xC7C7CC))

// B — outlined white card
let rp = NSBezierPath(roundedRect: right, xRadius: 30, yRadius: 30)
NSColor.white.setStroke(); rp.lineWidth = 16; rp.stroke()
badge(in: right, fill: nil, stroke: NSColor.white)
lines(in: NSRect(x: right.minX, y: right.minY, width: right.width, height: right.height - 78),
      color: NSColor.white)

NSGraphicsContext.restoreGraphicsState()

let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: url)
print("wrote \(url.path)")
