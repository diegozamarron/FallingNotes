// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// Fast preview surface. Instead of SwiftUI's Canvas (which turns every path into render-engine work),
/// this draws `drawFrame` straight into a double-buffered IOSurface-backed pixel buffer and hands it to the
/// layer, driven by a display link that only runs while playing.
final class FrameView: NSView {
    var provider: (@MainActor () -> Double)?
    var song: Song?
    var style = Style()
    var playing = false {
        didSet {
            link?.isPaused = !playing
            if !playing { render() }
        }
    }

    private var link: CADisplayLink?
    private var buffers: [CVPixelBuffer] = []
    private var bufferSize = (w: 0, h: 0)
    private var nextBuffer = 0
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Preview resolution cap; the layer scales it up. Keeps per-frame cost low on big/retina windows.
    private let pixelBudget = 1_000_000.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.isPaused = !playing
        l.add(to: .main, forMode: .common)
        link = l
        render()
    }

    override func layout() {
        super.layout()
        render()
    }

    @objc private func tick(_ link: CADisplayLink) { render() }

    private func ensureBuffers(_ w: Int, _ h: Int) {
        guard bufferSize != (w, h) || buffers.isEmpty else { return }
        buffers = (0..<2).compactMap { _ in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ] as CFDictionary, &pb)
            return pb
        }
        bufferSize = (w, h)
    }

    func render() {
        guard let song, bounds.width > 4, bounds.height > 4 else { return }
        var scale = window?.backingScaleFactor ?? 2
        let area = Double(bounds.width * bounds.height)
        if area * Double(scale * scale) > pixelBudget { scale = max(1, CGFloat((pixelBudget / area).squareRoot())) }
        let w = max(Int(bounds.width * scale), 2), h = max(Int(bounds.height * scale), 2)
        ensureBuffers(w, h)
        guard buffers.count == 2 else { return }
        let pb = buffers[nextBuffer]
        nextBuffer ^= 1

        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            drawFrame(ctx, size: CGSize(width: w, height: h), videoTime: provider?() ?? 0, song: song, style: style)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        if let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = surface
            CATransaction.commit()
        }
    }

    deinit { link?.invalidate() }
}

struct FramePreview: NSViewRepresentable {
    let model: AppModel
    let song: Song
    let style: Style
    let playing: Bool

    func makeNSView(context: Context) -> FrameView {
        let v = FrameView(frame: .zero)
        v.provider = { [unowned model] in model.videoTime() }
        return v
    }

    func updateNSView(_ v: FrameView, context: Context) {
        v.song = song
        v.style = style
        v.playing = playing
        if !playing { v.render() }   // while playing the display link redraws
    }
}
