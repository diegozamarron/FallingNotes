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

    func color(_ index: Int) -> CGColor {
        trackColors.isEmpty ? Palette.defaults[0] : trackColors[index % trackColors.count]
    }
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
            for (grow, alpha) in [(10.0, 0.10), (6.0, 0.14), (3.0, 0.22)] as [(CGFloat, CGFloat)] {
                let g = grow * scale
                let hr = rect.insetBy(dx: -g, dy: -g)
                let hrad = min(radius + g, hr.width / 2, hr.height / 2)
                ctx.setFillColor(base.copy(alpha: alpha) ?? base)
                ctx.addPath(CGPath(roundedRect: hr, cornerWidth: hrad, cornerHeight: hrad, transform: nil))
                ctx.fillPath()
            }
        }
        ctx.setFillColor(color)
        ctx.setStrokeColor(strokeColors.isEmpty ? base : strokeColors[n.part % strokeColors.count])
        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)   // one draw call per note
    }
    if pass == 0 {
        ctx.endTransparencyLayer()   // composites the group at the faint opacity
        ctx.setAlpha(1)              // ending the group restores the faint alpha; foreground notes must be opaque
    }
    }
    ctx.setAlpha(1)
    ctx.restoreGState()

    // Keyboard, drawn with as few draw calls as possible (this runs 60 times a second in the preview).
    let whiteTop = waterH
    ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
    ctx.fill(CGRect(x: 0, y: whiteTop, width: W, height: kbH))
    for p in layout.lo...layout.hi where !isBlack(p) {
        if let c = activeColor[p] {
            let k = layout.keyX(p)
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: k.x, y: whiteTop, width: k.w, height: kbH))
        }
    }
    ctx.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
    ctx.setLineWidth(max(1, scale))
    for p in layout.lo...layout.hi where !isBlack(p) && p != layout.lo {
        let x = layout.keyX(p).x
        ctx.move(to: CGPoint(x: x, y: whiteTop))
        ctx.addLine(to: CGPoint(x: x, y: whiteTop + kbH))
    }
    ctx.strokePath()

    let blackH = kbH * 0.62
    let blackKeys = CGMutablePath()
    var activeBlack: [(CGRect, CGColor)] = []
    for p in layout.lo...layout.hi where isBlack(p) {
        let k = layout.keyX(p)
        let r = CGRect(x: k.x, y: whiteTop, width: k.w, height: blackH)
        if let c = activeColor[p] {
            activeBlack.append((r, darken(c, 0.25)))
        } else {
            blackKeys.addRoundedRect(in: r, cornerWidth: 2.5 * scale, cornerHeight: 2.5 * scale)
        }
    }
    ctx.addPath(blackKeys)
    ctx.setFillColor(CGColor(gray: 0.09, alpha: 1))
    ctx.fillPath()
    for (r, c) in activeBlack {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2.5 * scale, cornerHeight: 2.5 * scale, transform: nil))
        ctx.setFillColor(c)
        ctx.fillPath()
    }
    // Red felt strip along the top of the keys.
    ctx.setFillColor(CGColor(srgbRed: 0.72, green: 0.1, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: whiteTop - 3 * scale, width: W, height: 3 * scale))
    ctx.restoreGState()
}
