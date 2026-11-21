#!/usr/bin/env swift
// Renders Encore's app icon into Encore/Assets.xcassets/AppIcon.appiconset.
//
//     swift Scripts/render-app-icon.swift            (run from the repo root)
//
// The icon: a velvet-curtained stage after dark, a tungsten spotlight falling on an italic
// Bodoni "E" with the wordmark's lamp-dot beside it.

import AppKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = repo.appendingPathComponent("Encore/Assets.xcassets/AppIcon.appiconset")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawMaster(_ ctx: CGContext, side: CGFloat) {
    let s = side / 1024
    ctx.scaleBy(x: s, y: s)
    // macOS icon grid: 824pt body centred in 1024, continuous-ish corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.5).cgColor)
    ctx.addPath(path); ctx.setFillColor(rgb(0x0E0C0B).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Ink ground, slightly lifted toward the top.
    let ground = CGGradient(colorsSpace: space, colors: [rgb(0x221B16).cgColor, rgb(0x0B0908).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Spotlight cone from above.
    ctx.saveGState()
    let cone = CGMutablePath()
    cone.move(to: CGPoint(x: 452, y: 940)); cone.addLine(to: CGPoint(x: 572, y: 940))
    cone.addLine(to: CGPoint(x: 800, y: 230)); cone.addLine(to: CGPoint(x: 224, y: 230)); cone.closeSubpath()
    ctx.addPath(cone); ctx.clip()
    let beam = CGGradient(colorsSpace: space, colors: [rgb(0xFFB648, 0.04).cgColor, rgb(0xFFB648, 0.20).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(beam, start: CGPoint(x: 512, y: 940), end: CGPoint(x: 512, y: 230), options: [])
    ctx.restoreGState()

    // Pool of light on the boards.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 240); ctx.scaleBy(x: 1, y: 0.2)
    let pool = CGGradient(colorsSpace: space, colors: [rgb(0xFFC66A, 0.55).cgColor, rgb(0xFFB648, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 330, options: [])
    ctx.restoreGState()

    // Velvet curtains, gathered at both sides: vertical folds.
    func curtain(leftEdge: Bool) {
        let width: CGFloat = 150
        let x0: CGFloat = leftEdge ? 100 : 924 - width
        let folds = 5
        for i in 0..<folds {
            let fw = width / CGFloat(folds)
            let rect = CGRect(x: x0 + CGFloat(i) * fw, y: 100, width: fw, height: 824)
            let lit: CGFloat = leftEdge ? CGFloat(i) / CGFloat(folds) : 1 - CGFloat(i) / CGFloat(folds)
            let fold = CGGradient(colorsSpace: space, colors: [rgb(0x5E0C18).cgColor, rgb(0xB81E33).blended(withFraction: 0.3 * (1 - lit), of: rgb(0x5E0C18))!.cgColor, rgb(0x4A0912).cgColor] as CFArray, locations: [0, 0.5, 1])!
            ctx.saveGState(); ctx.clip(to: rect)
            ctx.drawLinearGradient(fold, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
            ctx.restoreGState()
        }
        // Shade the curtain toward the bottom and the inner edge.
        let shade = CGGradient(colorsSpace: space, colors: [rgb(0x000000, 0).cgColor, rgb(0x000000, 0.55).cgColor] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.clip(to: CGRect(x: x0, y: 100, width: width, height: 824))
        ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: 700), end: CGPoint(x: 0, y: 100), options: [])
        ctx.restoreGState()
    }
    curtain(leftEdge: true)
    curtain(leftEdge: false)

    // Valance across the top: scalloped velvet.
    ctx.saveGState()
    let valance = CGMutablePath()
    valance.move(to: CGPoint(x: 100, y: 924)); valance.addLine(to: CGPoint(x: 100, y: 846))
    let scallops = 5
    let w = 824 / CGFloat(scallops)
    for i in 0..<scallops {
        let x = 100 + CGFloat(i) * w
        valance.addQuadCurve(to: CGPoint(x: x + w, y: 846), control: CGPoint(x: x + w / 2, y: 800))
    }
    valance.addLine(to: CGPoint(x: 924, y: 924)); valance.closeSubpath()
    ctx.addPath(valance); ctx.clip()
    let vg = CGGradient(colorsSpace: space, colors: [rgb(0x9E1A2C).cgColor, rgb(0x5A0B16).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(vg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 800), options: [])
    ctx.restoreGState()
    // Gold trim line under the valance.
    ctx.saveGState()
    let trim = CGMutablePath()
    trim.move(to: CGPoint(x: 100, y: 846))
    for i in 0..<scallops {
        let x = 100 + CGFloat(i) * w
        trim.addQuadCurve(to: CGPoint(x: x + w, y: 846), control: CGPoint(x: x + w / 2, y: 800))
    }
    ctx.addPath(trim); ctx.setStrokeColor(rgb(0xE0A048, 0.85).cgColor); ctx.setLineWidth(5); ctx.strokePath()
    ctx.restoreGState()

    // The "E", lit from above.
    let font = NSFont(name: "BodoniSvtyTwoITCTT-BookIta", size: 470) ?? NSFont(name: "Didot-Italic", size: 470) ?? .systemFont(ofSize: 470)
    let attr = NSAttributedString(string: "E", attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetImageBounds(line, ctx)
    let origin = CGPoint(x: 512 - bounds.midX - 18, y: 285 - bounds.minY)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xFFB648, 0.45).cgColor)
    ctx.textPosition = origin
    // Fill glyph with a vertical warm gradient via clipping to its outline.
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    let glyphPath = CGMutablePath()
    for run in runs {
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for (g, p) in zip(glyphs, positions) {
            if let gp = CTFontCreatePathForGlyph(runFont, g, nil) {
                glyphPath.addPath(gp, transform: CGAffineTransform(translationX: origin.x + p.x, y: origin.y + p.y))
            }
        }
    }
    ctx.addPath(glyphPath); ctx.setFillColor(rgb(0xF4EDE4).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(glyphPath); ctx.clip()
    let glyphFill = CGGradient(colorsSpace: space, colors: [rgb(0xFFF4E2).cgColor, rgb(0xFFD08A).cgColor, rgb(0xE39A3A).cgColor] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(glyphFill, start: CGPoint(x: 0, y: 760), end: CGPoint(x: 0, y: 280), options: [])
    ctx.restoreGState()

    // The lamp dot.
    let dotCenter = CGPoint(x: origin.x + bounds.maxX + 34, y: 300)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFFB648, 0.9).cgColor)
    ctx.setFillColor(rgb(0xFFB648).cgColor)
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - 24, y: dotCenter.y - 24, width: 48, height: 48))
    ctx.restoreGState()

    ctx.restoreGState()

    // Hairline rim.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0xF4EDE4, 0.10).cgColor); ctx.setLineWidth(3); ctx.strokePath()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    gc.cgContext.interpolationQuality = .high
    drawMaster(gc.cgContext, side: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(pixels: px).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
        print("wrote \(name)")
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
