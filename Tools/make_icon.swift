// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
// Draws the app icon (falling notes landing on a piano keyboard) as a 1024x1024 PNG.
// usage: swift Tools/make_icon.swift out.png   (Tools/make_icon.sh turns it into Resources/AppIcon.icns)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func lighten(_ c: CGColor, _ t: CGFloat) -> CGColor {
    let k = c.components!
    return rgb(k[0] + (1 - k[0]) * t, k[1] + (1 - k[1]) * t, k[2] + (1 - k[2]) * t)
}

let green = rgb(0.47, 0.84, 0.27)
let blue = rgb(0.27, 0.58, 0.96)
let coral = rgb(1.00, 0.56, 0.30)

// macOS icon grid: the artwork is an ~824pt rounded square centred in the 1024 canvas.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 188, cornerHeight: 188, transform: nil)

// Soft drop shadow under the whole shape.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0, 0, 0, 0.38))
ctx.addPath(shape)
ctx.setFillColor(rgb(0.05, 0.06, 0.12))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Night-blue background.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.17, 0.21, 0.40), rgb(0.07, 0.09, 0.20), rgb(0.03, 0.04, 0.10)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

// Keyboard along the bottom.
let kbTop: CGFloat = body.minY + 262
let whiteCount = 7
let keyW = body.width / CGFloat(whiteCount)
let active: [Int: CGColor] = [1: green, 4: blue]          // lit keys, matching the notes landing on them

for i in 0..<whiteCount {
    let r = CGRect(x: body.minX + CGFloat(i) * keyW, y: body.minY, width: keyW, height: kbTop - body.minY)
    ctx.setFillColor(active[i].map { lighten($0, 0.35) } ?? rgb(0.97, 0.97, 0.98))
    ctx.fill(r)
}
// Key gaps
ctx.setStrokeColor(rgb(0.45, 0.47, 0.55, 0.9))
ctx.setLineWidth(3)
for i in 1..<whiteCount {
    let x = body.minX + CGFloat(i) * keyW
    ctx.move(to: CGPoint(x: x, y: body.minY)); ctx.addLine(to: CGPoint(x: x, y: kbTop))
}
ctx.strokePath()
// Black keys sit between C-D, D-E, F-G, G-A, A-B.
let blackH: CGFloat = 160, blackW: CGFloat = 74
for gap in [1, 2, 4, 5, 6] {
    let x = body.minX + CGFloat(gap) * keyW - blackW / 2
    let r = CGRect(x: x, y: kbTop - blackH, width: blackW, height: blackH)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(rgb(0.07, 0.08, 0.12))
    ctx.fillPath()
}
// Red felt strip where the notes land.
ctx.setFillColor(rgb(0.78, 0.13, 0.18))
ctx.fill(CGRect(x: body.minX, y: kbTop, width: body.width, height: 9))

// Falling notes: (white-key column, bottom y, height, colour). The two on the lit keys touch the felt.
let barW = keyW * 0.74
let notes: [(col: Int, y0: CGFloat, h: CGFloat, c: CGColor)] = [
    (1, 0, 170, green), (1, 240, 110, green),
    (2, 170, 120, blue), (2, 350, 80, blue),
    (3, 280, 140, coral), (3, 100, 70, coral),
    (4, 0, 150, blue), (4, 220, 100, blue),
    (5, 140, 100, green), (5, 310, 110, green),
]
let waterBottom = kbTop + 9
for n in notes {
    let x = body.minX + CGFloat(n.col) * keyW + (keyW - barW) / 2
    let y = waterBottom + 12 + n.y0
    let r = CGRect(x: x, y: y, width: barW, height: n.h)
    let isActive = n.y0 == 0
    if isActive {   // glow, like the app: a few translucent halos
        for (g, a) in [(34.0, 0.10), (22.0, 0.14), (11.0, 0.22)] as [(CGFloat, CGFloat)] {
            let h = r.insetBy(dx: -g, dy: -g)
            ctx.addPath(CGPath(roundedRect: h, cornerWidth: 30 + g, cornerHeight: 30 + g, transform: nil))
            ctx.setFillColor(n.c.copy(alpha: a)!)
            ctx.fillPath()
        }
    }
    let path = CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(isActive ? lighten(n.c, 0.25) : n.c)
    ctx.fillPath()
    // Slight top-lit sheen on each bar
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let sheen = CGGradient(colorsSpace: cs, colors: [rgb(1, 1, 1, 0.30), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: x, y: r.maxY), end: CGPoint(x: x, y: r.midY), options: [])
    ctx.restoreGState()
}

// Glassy highlight over the top of the icon.
let gloss = CGGradient(colorsSpace: cs, colors: [rgb(1, 1, 1, 0.14), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.maxY - 330), options: [])
ctx.restoreGState()

// Thin inner rim.
ctx.addPath(shape)
ctx.setStrokeColor(rgb(1, 1, 1, 0.16))
ctx.setLineWidth(3)
ctx.strokePath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote", CommandLine.arguments[1])
