// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import CoreText
import CoreGraphics
import Foundation

struct Style {
    var fallSeconds: Double = 2.0
    var background: CGColor = CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
    var trackColors: [CGColor] = Palette.defaults
    var fullKeyboard = true
    var glow = true
    var hidden: Set<Int> = []          // part indices that are not drawn
    var faint: Set<Int> = []           // part indices drawn translucent behind the others
    var faintOpacity: CGFloat = 0.3
    /// The key: one line per instrument (colour + title). Empty = no key.
    var legend: [LegendEntry] = []
    var legendCorner: LegendCorner = .topLeft
    var mode: VisualMode = .simple

    func color(_ index: Int) -> CGColor {
        trackColors.isEmpty ? Palette.defaults[0] : trackColors[index % trackColors.count]
    }
}

/// How elaborate the video looks. Simple is the plain, very readable look; the others add depth and effects.
enum VisualMode: String, CaseIterable, Identifiable {
    case simple, polished, cinematic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .simple: return "Simple"
        case .polished: return "Polished"
        case .cinematic: return "Cinematic"
        }
    }
    var detail: String {
        switch self {
        case .simple: return "Flat colours. Clean and very readable."
        case .polished: return "Shaded notes, glossy keys, a soft gradient background and a fade at the top."
        case .cinematic: return "Everything in Polished plus light beams, sparks, a spotlight and a vignette. Made for presentations and videos."
        }
    }
}

struct LegendEntry: Equatable {
    var title: String
    var color: CGColor
    var faint: Bool
}

enum LegendCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight
    var id: String { rawValue }
    var label: String { self == .topLeft ? "Top left" : "Top right" }
}

enum Palette {
    /// Note colours. The first three are the defaults: Synthesia-style lime green and sky blue, plus a warm
    /// coral-orange as the third (it's opposite blue on the colour wheel, so it stands out against both).
    static let named: [(name: String, color: CGColor)] = [
        ("Green", CGColor(srgbRed: 0.47, green: 0.84, blue: 0.27, alpha: 1)),
        ("Blue", CGColor(srgbRed: 0.27, green: 0.58, blue: 0.96, alpha: 1)),
        ("Coral Orange", CGColor(srgbRed: 1.00, green: 0.56, blue: 0.30, alpha: 1)),
        ("Pink", CGColor(srgbRed: 1.00, green: 0.38, blue: 0.62, alpha: 1)),
        ("Purple", CGColor(srgbRed: 0.70, green: 0.48, blue: 1.00, alpha: 1)),
        ("Yellow", CGColor(srgbRed: 1.00, green: 0.88, blue: 0.30, alpha: 1)),
        ("Teal", CGColor(srgbRed: 0.25, green: 0.85, blue: 0.85, alpha: 1)),
        ("Red", CGColor(srgbRed: 1.00, green: 0.35, blue: 0.35, alpha: 1)),
    ]
    static let defaults: [CGColor] = named.map(\.color)

    /// Background choices (the first is the default).
    static let backgrounds: [(name: String, color: CGColor)] = [
        ("Midnight", CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)),
        ("Black", CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)),
        ("Deep Navy", CGColor(srgbRed: 0.04, green: 0.07, blue: 0.16, alpha: 1)),
        ("Charcoal", CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)),
        ("Plum", CGColor(srgbRed: 0.10, green: 0.05, blue: 0.14, alpha: 1)),
        ("Forest", CGColor(srgbRed: 0.04, green: 0.10, blue: 0.08, alpha: 1)),
    ]
}

private func isBlack(_ p: Int) -> Bool { [1, 3, 6, 8, 10].contains(p % 12) }

/// Keyboard layout for a range of pitches (both ends are white keys).
struct KeyLayout {
    let lo: Int
    let hi: Int
    let width: CGFloat
    let whiteWidth: CGFloat
    private let whiteIndex: [Int]  // index = pitch - lo, value = number of white keys before it

    init(song: Song, fullKeyboard: Bool, width: CGFloat) {
        var lo = 21, hi = 108
        if !fullKeyboard {
            lo = (song.minPitch / 12) * 12
            hi = (song.maxPitch / 12) * 12 + 11
            // Keep at least 4 octaves so tiny pieces don't look huge.
            while hi - lo + 1 < 48 {
                if lo > 24 { lo -= 12 }
                if hi - lo + 1 < 48 && hi < 100 { hi += 12 }
                if lo <= 24 && hi >= 100 { break }
            }
            lo = max(21, lo)
            hi = min(108, hi)
        }
        while isBlack(lo) { lo += 1 }
        while isBlack(hi) { hi -= 1 }
        var idx: [Int] = []
        var count = 0
        for p in lo...hi {
            idx.append(count)
            if !isBlack(p) { count += 1 }
        }
        self.lo = lo
        self.hi = hi
        self.width = width
        self.whiteIndex = idx
        self.whiteWidth = width / CGFloat(max(count, 1))
    }

    func contains(_ pitch: Int) -> Bool { pitch >= lo && pitch <= hi }

    /// Left edge and width of the key (black keys are narrower and straddle two white keys).
    func keyX(_ pitch: Int) -> (x: CGFloat, w: CGFloat, black: Bool) {
        let i = whiteIndex[pitch - lo]
        if isBlack(pitch) {
            let bw = whiteWidth * 0.62
            return (CGFloat(i) * whiteWidth - bw / 2, bw, true)
        }
        return (CGFloat(i) * whiteWidth, whiteWidth, false)
    }
}

private func lowerBound(_ notes: [Note], start: Double) -> Int {
    var lo = 0, hi = notes.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if notes[mid].start < start { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

private func lighten(_ c: CGColor, _ amount: CGFloat) -> CGColor {
    let comps = c.components ?? [1, 1, 1, 1]
    guard comps.count >= 3 else { return c }
    return CGColor(srgbRed: comps[0] + (1 - comps[0]) * amount,
                   green: comps[1] + (1 - comps[1]) * amount,
                   blue: comps[2] + (1 - comps[2]) * amount, alpha: 1)
}

private func darken(_ c: CGColor, _ amount: CGFloat) -> CGColor {
    let comps = c.components ?? [1, 1, 1, 1]
    guard comps.count >= 3 else { return c }
    return CGColor(srgbRed: comps[0] * (1 - amount), green: comps[1] * (1 - amount),
                   blue: comps[2] * (1 - amount), alpha: 1)
}

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// Fills the current clip with a linear gradient.
private func fillGradient(_ ctx: CGContext, _ colors: [CGColor], from a: CGPoint, to b: CGPoint, locations: [CGFloat]? = nil) {
    guard let g = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations) else { return }
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

private func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: a) }

/// A repeatable pseudo-random number in 0..<1, so effects look the same in the preview and in every exported piece.
private func hash01(_ a: Int, _ b: Int) -> CGFloat {
    var x = UInt64(truncatingIfNeeded: a) &* 0x9E3779B97F4A7C15 ^ UInt64(truncatingIfNeeded: b) &* 0xC2B2AE3D27D4EB4F
    x ^= x >> 29
    x = x &* 0xBF58476D1CE4E5B9
    x ^= x >> 32
    return CGFloat(x % 10000) / 10000
}

/// Draws one frame. `ctx` must use a top-left origin (y grows downward).
/// `videoTime` is the position on the preview/export timeline (0 = start of lead-in).
func drawFrame(_ ctx: CGContext, size: CGSize, videoTime: Double, song: Song, style: Style) {
    let W = size.width, H = size.height
    let t = videoTime - Song.leadIn            // song time
    let scale = min(W, H) / 1080

    let layout = KeyLayout(song: song, fullKeyboard: style.fullKeyboard, width: W)
    let kbH = min(H * 0.18, layout.whiteWidth * 5.6)
    let waterH = H - kbH

    ctx.saveGState()
    ctx.setFillColor(style.background)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    let rich = style.mode != .simple
    let cinematic = style.mode == .cinematic
    let bgTop = darken(style.background, 0.45)
    if rich {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: waterH))
        fillGradient(ctx, [bgTop, style.background, lighten(style.background, 0.06)],
                     from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: waterH), locations: [0, 0.55, 1])
        if cinematic, let g = CGGradient(colorsSpace: srgb, colors: [gray(1, 0.09), gray(1, 0)] as CFArray, locations: nil) {
            // A soft spotlight on the keyboard.
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: W / 2, y: waterH), startRadius: 0,
                                   endCenter: CGPoint(x: W / 2, y: waterH), endRadius: max(W * 0.55, waterH * 0.9), options: [])
        }
        ctx.restoreGState()
    }

    // Faint octave lines on the waterfall.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.06))
    ctx.setLineWidth(max(1, scale))
    for p in layout.lo...layout.hi where p % 12 == 0 {
        let x = layout.keyX(p).x
        ctx.move(to: CGPoint(x: x, y: 0))
        ctx.addLine(to: CGPoint(x: x, y: waterH))
    }
    ctx.strokePath()

    // Falling notes.
    var activeColor = [CGColor?](repeating: nil, count: 128)
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: waterH))
    let notes = song.notes
    let firstIndex = lowerBound(notes, start: t - song.maxDuration - 0.01)
    let gap = max(1.5, 2.5 * scale)
    let strokeColors = style.trackColors.map { darken($0, 0.35) }
    ctx.setLineWidth(max(1, 1.2 * scale))
    // Two passes: faint background parts first (translucent, no glow, don't light keys), then the main parts on top.
    for pass in 0..<2 {
    if pass == 0 && style.faint.isEmpty { continue }
    if pass == 0 {
        // Draw the faint notes opaque into one group and fade the group as a whole, so overlapping
        // notes don't stack up and look brighter than the rest.
        ctx.setAlpha(style.faintOpacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setAlpha(1)
    }
    var i = firstIndex
    while i < notes.count, notes[i].start <= t + style.fallSeconds {
        let n = notes[i]
        i += 1
        guard n.end >= t, layout.contains(n.pitch), !style.hidden.contains(n.part),
              style.faint.contains(n.part) == (pass == 0) else { continue }
        let isFaint = pass == 0
        let key = layout.keyX(n.pitch)
        let inset = key.w * 0.08
        let x = key.x + inset
        let w = key.w - inset * 2
        let yBottom = waterH - CGFloat((n.start - t) / style.fallSeconds) * waterH - gap / 2
        let yTop = waterH - CGFloat((n.end - t) / style.fallSeconds) * waterH + gap / 2
        let rect = CGRect(x: x, y: yTop, width: w, height: max(yBottom - yTop, 4 * scale))
        let active = !isFaint && n.start <= t && t < n.end
        let base = style.color(n.part)
        let color = active ? lighten(base, 0.25) : base
        if active { activeColor[n.pitch] = color }

        let radius = min(w * 0.28, 7 * scale, rect.height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if active && style.glow {
            // Cheap glow: a few translucent halos. (A real CG shadow runs a full-size blur per note per frame,
            // which dominated the cost on busy pieces.)
            let halos: [(CGFloat, CGFloat)] = cinematic
                ? [(22, 0.05), (14, 0.08), (8, 0.13), (4, 0.22)]
                : [(10, 0.10), (6, 0.14), (3, 0.22)]
            for (grow, alpha) in halos {
                let g = grow * scale
                let hr = rect.insetBy(dx: -g, dy: -g)
                let hrad = min(radius + g, hr.width / 2, hr.height / 2)
                ctx.setFillColor(base.copy(alpha: alpha) ?? base)
                ctx.addPath(CGPath(roundedRect: hr, cornerWidth: hrad, cornerHeight: hrad, transform: nil))
                ctx.fillPath()
            }
        }
        if rich {
            // Shaded body: light at the top, deeper at the bottom, with a glossy stripe down the left.
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            fillGradient(ctx, [lighten(color, 0.30), color, darken(color, 0.14)],
                         from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.maxY), locations: [0, 0.35, 1])
            ctx.setFillColor(gray(1, active ? 0.34 : 0.18))
            ctx.fill(CGRect(x: rect.minX + w * 0.14, y: rect.minY, width: w * 0.16, height: rect.height))
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(lighten(base, 0.45).copy(alpha: active ? 0.85 : 0.5) ?? base)
            ctx.strokePath()
        } else {
            ctx.setFillColor(color)
            ctx.setStrokeColor(strokeColors.isEmpty ? base : strokeColors[n.part % strokeColors.count])
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)   // one draw call per note
        }
    }
    if pass == 0 {
        ctx.endTransparencyLayer()   // composites the group at the faint opacity
        ctx.setAlpha(1)              // ending the group restores the faint alpha; foreground notes must be opaque
    }
    }
    ctx.setAlpha(1)

    if rich {
        // Notes emerge out of the dark at the top.
        let fadeH = waterH * (cinematic ? 0.22 : 0.10)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: fadeH))
        fillGradient(ctx, [bgTop, bgTop.copy(alpha: 0) ?? bgTop], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: fadeH))
        ctx.restoreGState()
    }
    if cinematic {
        ctx.setBlendMode(.plusLighter)
        // Beams of light rising from every key that is sounding.
        let beamH = waterH * 0.45
        for p in layout.lo...layout.hi {
            guard let c = activeColor[p] else { continue }
            let k = layout.keyX(p)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: k.x, y: waterH - beamH, width: k.w, height: beamH))
            fillGradient(ctx, [c.copy(alpha: 0.65) ?? c, c.copy(alpha: 0) ?? c],
                         from: CGPoint(x: 0, y: waterH), to: CGPoint(x: 0, y: waterH - beamH))
            ctx.restoreGState()
        }
        // Sparks thrown up when a note starts.
        let life = 0.7
        var j = lowerBound(notes, start: t - life)
        while j < notes.count, notes[j].start <= t {
            let n = notes[j]
            defer { j += 1 }
            guard layout.contains(n.pitch), !style.hidden.contains(n.part), !style.faint.contains(n.part) else { continue }
            let age = CGFloat((t - n.start) / life)
            let key = layout.keyX(n.pitch)
            let c = lighten(style.color(n.part), 0.45)
            for q in 0..<5 {
                let r1 = hash01(j, q * 3 + 1), r2 = hash01(j, q * 3 + 2), r3 = hash01(j, q * 3 + 3)
                let x = key.x + key.w / 2 + (r1 - 0.5) * key.w * 2.2 * (0.4 + age)
                let y = waterH - (6 + r2 * 70) * scale * (1 - (1 - age) * (1 - age)) - 2 * scale
                let rad = (1.6 + r3 * 3.0) * scale * (1 - age * 0.7)
                ctx.setFillColor(c.copy(alpha: (1 - age) * 0.9) ?? c)
                ctx.fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
            }
        }
        ctx.setBlendMode(.normal)
        // Vignette.
        if let g = CGGradient(colorsSpace: srgb, colors: [gray(0, 0), gray(0, 0), gray(0, 0.5)] as CFArray,
                              locations: [0, 0.5, 1]) {
            let c = CGPoint(x: W / 2, y: waterH * 0.6)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                   endRadius: hypot(W / 2, waterH * 0.7), options: [.drawsAfterEndLocation])
        }
    }
    ctx.restoreGState()

    // Keyboard, drawn with as few draw calls as possible (this runs 60 times a second in the preview).
    let whiteTop = waterH
    if rich {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: whiteTop, width: W, height: kbH))
        fillGradient(ctx, [gray(0.99), gray(0.97), gray(0.84)], from: CGPoint(x: 0, y: whiteTop),
                     to: CGPoint(x: 0, y: whiteTop + kbH), locations: [0, 0.6, 1])
        ctx.restoreGState()
    } else {
        ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: whiteTop, width: W, height: kbH))
    }
    for p in layout.lo...layout.hi where !isBlack(p) {
        if let c = activeColor[p] {
            let k = layout.keyX(p)
            if rich {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: k.x, y: whiteTop, width: k.w, height: kbH))
                fillGradient(ctx, [lighten(c, 0.15), c, darken(c, 0.18)], from: CGPoint(x: 0, y: whiteTop),
                             to: CGPoint(x: 0, y: whiteTop + kbH), locations: [0, 0.5, 1])
                ctx.restoreGState()
            } else {
                ctx.setFillColor(c)
                ctx.fill(CGRect(x: k.x, y: whiteTop, width: k.w, height: kbH))
            }
        }
    }
    ctx.setStrokeColor(rich ? gray(0.62) : CGColor(gray: 0.45, alpha: 1))
    ctx.setLineWidth(max(1, scale))
    for p in layout.lo...layout.hi where !isBlack(p) && p != layout.lo {
        let x = layout.keyX(p).x
        ctx.move(to: CGPoint(x: x, y: whiteTop))
        ctx.addLine(to: CGPoint(x: x, y: whiteTop + kbH))
    }
    ctx.strokePath()

    if rich {
        // The felt strip casts a soft shadow onto the keys.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: whiteTop, width: W, height: 14 * scale))
        fillGradient(ctx, [gray(0, 0.45), gray(0, 0)], from: CGPoint(x: 0, y: whiteTop), to: CGPoint(x: 0, y: whiteTop + 14 * scale))
        ctx.restoreGState()
    }
    let blackH = kbH * 0.62
    let blackKeys = CGMutablePath()
    var activeBlack: [(CGRect, CGColor, Bool)] = []   // (key, colour, idle)
    for p in layout.lo...layout.hi where isBlack(p) {
        let k = layout.keyX(p)
        let r = CGRect(x: k.x, y: whiteTop, width: k.w, height: blackH)
        if let c = activeColor[p] {
            activeBlack.append((r, darken(c, 0.25), false))
        } else if rich {
            activeBlack.append((r, gray(0.09), true))   // drawn with the shaded look below
        } else {
            blackKeys.addRoundedRect(in: r, cornerWidth: 2.5 * scale, cornerHeight: 2.5 * scale)
        }
    }
    ctx.addPath(blackKeys)
    ctx.setFillColor(CGColor(gray: 0.09, alpha: 1))
    ctx.fillPath()
    for (r, c, idle) in activeBlack {
        let rr = CGPath(roundedRect: r, cornerWidth: 2.5 * scale, cornerHeight: 2.5 * scale, transform: nil)
        if rich {
            ctx.saveGState()
            ctx.addPath(rr)
            ctx.clip()
            fillGradient(ctx, idle ? [gray(0.26), gray(0.09), gray(0.03)] : [lighten(c, 0.1), c, darken(c, 0.4)],
                         from: CGPoint(x: 0, y: r.minY), to: CGPoint(x: 0, y: r.maxY), locations: [0, 0.6, 1])
            ctx.setFillColor(gray(1, idle ? 0.13 : 0.2))
            ctx.fill(CGRect(x: r.minX + r.width * 0.16, y: r.minY, width: r.width * 0.2, height: r.height * 0.86))
            ctx.restoreGState()
        } else {
            ctx.addPath(rr)
            ctx.setFillColor(c)
            ctx.fillPath()
        }
    }
    // Red felt strip along the top of the keys.
    if rich {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: whiteTop - 3 * scale, width: W, height: 3 * scale))
        fillGradient(ctx, [CGColor(srgbRed: 0.9, green: 0.16, blue: 0.2, alpha: 1), CGColor(srgbRed: 0.5, green: 0.05, blue: 0.09, alpha: 1)],
                     from: CGPoint(x: 0, y: whiteTop - 3 * scale), to: CGPoint(x: 0, y: whiteTop))
        ctx.restoreGState()
    } else {
        ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.1, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: whiteTop - 3 * scale, width: W, height: 3 * scale))
    }
    if !style.legend.isEmpty { drawLegend(ctx, size: size, scale: scale, style: style) }
    ctx.restoreGState()
}

/// The key: a rounded panel with a colour swatch and a title for each instrument. `ctx` has a top-left origin.
private func drawLegend(_ ctx: CGContext, size: CGSize, scale: CGFloat, style: Style) {
    let fontSize = 22 * scale
    let font = CTFontCreateWithName("Helvetica Neue Medium" as CFString, fontSize, nil)
    let rowH = fontSize * 1.55
    let pad = 14 * scale
    let swatch = fontSize * 0.8
    let gapX = 10 * scale

    var lines: [(CTLine, CGFloat)] = []
    var textW: CGFloat = 0
    for e in style.legend {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: e.faint ? 0.6 : 0.95),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: e.title, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        lines.append((line, ascent))
        textW = max(textW, w)
    }
    let panelW = min(pad * 2 + swatch + gapX + textW, size.width * 0.5)
    let panelH = pad * 2 + rowH * CGFloat(lines.count) - (rowH - swatch)
    let margin = 20 * scale
    let x0 = style.legendCorner == .topLeft ? margin : size.width - margin - panelW
    let y0 = margin

    let panel = CGPath(roundedRect: CGRect(x: x0, y: y0, width: panelW, height: panelH),
                       cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil)
    ctx.addPath(panel)
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
    ctx.fillPath()
    ctx.addPath(panel)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    ctx.setLineWidth(max(1, scale))
    ctx.strokePath()

    ctx.saveGState()
    ctx.clip(to: CGRect(x: x0, y: y0, width: panelW, height: panelH))
    for (i, e) in style.legend.enumerated() {
        let rowTop = y0 + pad + rowH * CGFloat(i)
        let r = CGRect(x: x0 + pad, y: rowTop, width: swatch, height: swatch)
        ctx.setFillColor(e.faint ? (e.color.copy(alpha: max(0.3, style.faintOpacity + 0.2)) ?? e.color) : e.color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: swatch * 0.28, cornerHeight: swatch * 0.28, transform: nil))
        ctx.fillPath()

        // Text in a flipped coordinate system (the context's origin is the top left).
        let (line, ascent) = lines[i]
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x0 + pad + swatch + gapX, y: rowTop + swatch / 2 + ascent * 0.36)
        CTLineDraw(line, ctx)
    }
    ctx.restoreGState()
}
