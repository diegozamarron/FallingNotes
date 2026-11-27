// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
// Draws the installer window's background (the same look as the app) as a PNG.
// usage: swift Tools/make_dmg_background.swift out.png <scale 1|2> <version>
import AppKit

let args = CommandLine.arguments
let outPath = args[1]
let scale = Int(args[2]) ?? 1
let version = args.count > 3 ? args[3] : ""

let W: CGFloat = 660, H: CGFloat = 400          // the window's size in points
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)           // points; the extra pixels make it sharp on Retina screens
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
func lighten(_ c: CGColor, _ t: CGFloat) -> CGColor {
    let k = c.components!; return rgb(k[0] + (1 - k[0]) * t, k[1] + (1 - k[1]) * t, k[2] + (1 - k[2]) * t)
}
/// Convert from "distance from the top" to Core Graphics' bottom-up y.
func Y(_ top: CGFloat) -> CGFloat { H - top }

let green = rgb(0.47, 0.84, 0.27), blue = rgb(0.27, 0.58, 0.96), coral = rgb(1.00, 0.56, 0.30)

// Night-blue background, like the app icon.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.17, 0.21, 0.40), rgb(0.07, 0.09, 0.20), rgb(0.03, 0.04, 0.10)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: W / 2, y: H), end: CGPoint(x: W / 2, y: 0), options: [])

// Piano keyboard along the bottom.
let kbTop: CGFloat = 348
let keys = 24
let keyW = W / CGFloat(keys)
let lit: [Int: CGColor] = [2: green, 21: blue]
for i in 0..<keys {
    ctx.setFillColor(lit[i].map { lighten($0, 0.35) } ?? rgb(0.96, 0.96, 0.97))
    ctx.fill(CGRect(x: CGFloat(i) * keyW, y: 0, width: keyW, height: Y(kbTop)))
}
ctx.setStrokeColor(rgb(0.45, 0.47, 0.55, 0.9)); ctx.setLineWidth(1)
for i in 1..<keys { ctx.move(to: CGPoint(x: CGFloat(i) * keyW, y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(i) * keyW, y: Y(kbTop))) }
ctx.strokePath()
for gap in 1..<keys where [1, 2, 4, 5, 6].contains(gap % 7) {
    let r = CGRect(x: CGFloat(gap) * keyW - keyW * 0.3, y: Y(kbTop) - 30, width: keyW * 0.6, height: 30)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
    ctx.setFillColor(rgb(0.07, 0.08, 0.12)); ctx.fillPath()
}
ctx.setFillColor(rgb(0.78, 0.13, 0.18)); ctx.fill(CGRect(x: 0, y: Y(kbTop) - 0.5, width: W, height: 3))   // felt strip

// Falling notes: (key column, top, height, colour, opacity). The two on the lit keys touch the keyboard.
let barW = keyW * 0.74
let notes: [(col: Int, top: CGFloat, h: CGFloat, c: CGColor, a: CGFloat)] = [
    (2, 300, 48, green, 1), (2, 232, 44, green, 0.9), (2, 150, 36, green, 0.75),
    (21, 304, 44, blue, 1), (21, 222, 52, blue, 0.9), (21, 140, 34, blue, 0.75),
    (0, 90, 40, coral, 0.8), (1, 190, 30, blue, 0.7), (22, 150, 38, green, 0.7), (23, 70, 44, coral, 0.8),
    // across the top, above the panel
    (8, 18, 50, coral, 0.7), (10, 44, 30, green, 0.7), (12, 20, 46, blue, 0.75),
    (14, 38, 34, coral, 0.7), (16, 16, 52, green, 0.75), (18, 46, 30, blue, 0.7), (19, 24, 44, coral, 0.8),
]
for n in notes {
    let x = CGFloat(n.col) * keyW + (keyW - barW) / 2
    let r = CGRect(x: x, y: Y(n.top + n.h), width: barW, height: n.h)
    let landing = n.top + n.h >= kbTop - 1
    if landing {   // a soft glow where a note lands, like the app
        for (g, a) in [(10.0, 0.10), (6.0, 0.14), (3.0, 0.22)] as [(CGFloat, CGFloat)] {
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -g, dy: -g), cornerWidth: 8 + g, cornerHeight: 8 + g, transform: nil))
            ctx.setFillColor(n.c.copy(alpha: a)!); ctx.fillPath()
        }
    }
    let path = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)
    ctx.saveGState()
    ctx.setAlpha(n.a)
    ctx.addPath(path); ctx.setFillColor(landing ? lighten(n.c, 0.25) : n.c); ctx.fillPath()
    ctx.addPath(path); ctx.clip()
    let sheen = CGGradient(colorsSpace: cs, colors: [rgb(1, 1, 1, 0.30), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: x, y: r.maxY), end: CGPoint(x: x, y: r.midY), options: [])
    ctx.restoreGState()
}

// A soft dark panel behind the middle so the icons and text stay readable over the notes.
let panel = CGRect(x: 100, y: Y(310), width: 460, height: 222)
ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 26, cornerHeight: 26, transform: nil))
ctx.setFillColor(rgb(0.03, 0.04, 0.10, 0.62)); ctx.fillPath()
ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 26, cornerHeight: 26, transform: nil))
ctx.setStrokeColor(rgb(1, 1, 1, 0.10)); ctx.setLineWidth(1); ctx.strokePath()

// Arrow from the app to Applications.
let arrowY: CGFloat = 160
ctx.setStrokeColor(rgb(1, 1, 1, 0.85)); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 262, y: Y(arrowY))); ctx.addLine(to: CGPoint(x: 392, y: Y(arrowY))); ctx.strokePath()
ctx.move(to: CGPoint(x: 372, y: Y(arrowY - 16))); ctx.addLine(to: CGPoint(x: 396, y: Y(arrowY))); ctx.addLine(to: CGPoint(x: 372, y: Y(arrowY + 16)))
ctx.strokePath()

// Text.
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerX: CGFloat, top: CGFloat, align: NSTextAlignment = .center) {
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.5); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
    let para = NSMutableParagraphStyle(); para.alignment = align
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                                                .paragraphStyle: para, .shadow: shadow]
    let str = NSAttributedString(string: s, attributes: attrs)
    let box = CGSize(width: 640, height: size * 1.5)
    let origin = align == .left ? CGPoint(x: centerX, y: Y(top) - box.height) : CGPoint(x: centerX - box.width / 2, y: Y(top) - box.height)
    str.draw(in: CGRect(origin: origin, size: box))
}
text("Falling Notes", size: 24, weight: .semibold, alpha: 0.95, centerX: 28, top: 20, align: .left)
if !version.isEmpty { text("Version \(version)", size: 12, weight: .regular, alpha: 0.55, centerX: 29, top: 52, align: .left) }
text("Drag Falling Notes into Applications", size: 16, weight: .semibold, alpha: 0.95, centerX: W / 2, top: 262)
text("First launch: System Settings → Privacy & Security → Open Anyway", size: 11, weight: .regular, alpha: 0.65, centerX: W / 2, top: 286)
text("© 2026 Diego Zamarron · Free software under the GNU GPL v3 or later", size: 10, weight: .regular, alpha: 0.5, centerX: W / 2, top: 318)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote", outPath)
