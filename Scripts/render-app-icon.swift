#!/usr/bin/env swift
// Renders Encore's app icon into Encore/Assets.xcassets/AppIcon.appiconset.
//
//     swift Scripts/render-app-icon.swift            (run from the repo root)
//
// The icon is a curtain call: velvet curtains drawn back, and a cast of five bars (a waveform)
// silhouetted in the light. No letterforms.

import AppKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = repo.appendingPathComponent("Encore/Assets.xcassets/AppIcon.appiconset")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

func begin(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.5))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x0E0C0B)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
}
func end(_ ctx: CGContext) {
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0xF4EDE4, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
}
func ground(_ ctx: CGContext) {
    ctx.drawLinearGradient(gradient([(0, rgb(0x221B16)), (1, rgb(0x0B0908))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
}

// MARK: Shared pieces

/// Warm light pouring from behind, brightest at `center`.
func backlight(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFF3D6)), (0.22, rgb(0xFFD589)), (0.5, rgb(0xF2A03A)), (0.78, rgb(0x8A4312)), (1, rgb(0x2A1408))]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [.drawsAfterEndLocation])
}

/// Stage boards across the bottom with a pool of light.
func boards(_ ctx: CGContext, top: CGFloat, poolAlpha: CGFloat = 0.75) {
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 100, y: 100, width: 824, height: top - 100))
    ctx.drawLinearGradient(gradient([(0, rgb(0x5A3413)), (1, rgb(0x170D07))]),
                           start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: 100), options: [])
    ctx.translateBy(x: 512, y: top - 6); ctx.scaleBy(x: 1, y: 0.26)
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFE3A6, poolAlpha)), (1, rgb(0xFFB648, 0))]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 400, options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0xFFDFA0, 0.35)); ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: 100, y: top)); ctx.addLine(to: CGPoint(x: 924, y: top)); ctx.strokePath()
}

/// One tied-back velvet curtain on the left; call inside a mirrored transform for the right.
func tiedCurtain(_ ctx: CGContext, innerTop: CGFloat = 500, tie: CGPoint = CGPoint(x: 232, y: 452), foot: CGFloat = 292) {
    let shape = CGMutablePath()
    shape.move(to: CGPoint(x: 90, y: 934))
    shape.addLine(to: CGPoint(x: innerTop, y: 934))
    shape.addCurve(to: tie, control1: CGPoint(x: innerTop - 20, y: 720), control2: CGPoint(x: tie.x + 120, y: tie.y + 90))
    shape.addCurve(to: CGPoint(x: foot, y: 90), control1: CGPoint(x: tie.x + 40, y: tie.y - 120), control2: CGPoint(x: foot - 10, y: 240))
    shape.addLine(to: CGPoint(x: 90, y: 90))
    shape.closeSubpath()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x4A0912)), (0.55, rgb(0x9E1A2C)), (1, rgb(0xC9253B))]),
                           start: CGPoint(x: 100, y: 0), end: CGPoint(x: innerTop, y: 0), options: [])
    // Folds: fan from the rod down into the tie-back, then hang below it.
    let folds = 7
    for i in 0..<folds {
        let t = CGFloat(i) / CGFloat(folds - 1)
        let topX = 118 + t * (innerTop - 150)
        let fold = CGMutablePath()
        fold.move(to: CGPoint(x: topX, y: 934))
        fold.addCurve(to: CGPoint(x: tie.x - 70 + t * 62, y: tie.y + 8),
                      control1: CGPoint(x: topX - 4, y: 760), control2: CGPoint(x: tie.x - 60 + t * 150, y: tie.y + 130))
        fold.addCurve(to: CGPoint(x: 112 + t * (foot - 130), y: 90),
                      control1: CGPoint(x: tie.x - 70 + t * 80, y: tie.y - 130), control2: CGPoint(x: 112 + t * (foot - 130), y: 250))
        ctx.addPath(fold)
        ctx.setStrokeColor(i % 2 == 0 ? rgb(0x2E050B, 0.55) : rgb(0xE8445A, 0.30))
        ctx.setLineWidth(i % 2 == 0 ? 16 : 9); ctx.setLineCap(.round); ctx.strokePath()
    }
    // Shade toward the outer edge and the floor.
    ctx.drawLinearGradient(gradient([(0, rgb(0x000000, 0.45)), (1, rgb(0x000000, 0))]),
                           start: CGPoint(x: 100, y: 0), end: CGPoint(x: 300, y: 0), options: [])
    ctx.drawLinearGradient(gradient([(0, rgb(0x000000, 0)), (1, rgb(0x000000, 0.5))]),
                           start: CGPoint(x: 0, y: 420), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()
    // Lit inner edge.
    let edge = CGMutablePath()
    edge.move(to: CGPoint(x: innerTop, y: 934))
    edge.addCurve(to: tie, control1: CGPoint(x: innerTop - 20, y: 720), control2: CGPoint(x: tie.x + 120, y: tie.y + 90))
    edge.addCurve(to: CGPoint(x: foot, y: 90), control1: CGPoint(x: tie.x + 40, y: tie.y - 120), control2: CGPoint(x: foot - 10, y: 240))
    ctx.addPath(edge); ctx.setStrokeColor(rgb(0xFF8C7A, 0.55)); ctx.setLineWidth(5); ctx.strokePath()
    // Gold tie-back.
    ctx.saveGState()
    ctx.translateBy(x: tie.x - 34, y: tie.y + 2); ctx.rotate(by: -0.42)
    let band = CGPath(roundedRect: CGRect(x: -62, y: -15, width: 124, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: rgb(0x000000, 0.5))
    ctx.addPath(band); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFE2A0)), (0.5, rgb(0xE0A048)), (1, rgb(0x8C5A18))]),
                           start: CGPoint(x: 0, y: 15), end: CGPoint(x: 0, y: -15), options: [])
    ctx.restoreGState()
}
func bothCurtains(_ ctx: CGContext, innerTop: CGFloat = 500, tie: CGPoint = CGPoint(x: 232, y: 452), foot: CGFloat = 292) {
    tiedCurtain(ctx, innerTop: innerTop, tie: tie, foot: foot)
    ctx.saveGState()
    ctx.translateBy(x: 1024, y: 0); ctx.scaleBy(x: -1, y: 1)
    tiedCurtain(ctx, innerTop: innerTop, tie: tie, foot: foot)
    ctx.restoreGState()
}

/// A row of rounded bars standing on a baseline, like a cast taking a bow.
func cast(_ ctx: CGContext, heights: [CGFloat], width: CGFloat, gap: CGFloat, baseline: CGFloat,
          fill: (CGRect) -> Void) {
    let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
    var x = 512 - total / 2
    for h in heights {
        fill(CGRect(x: x, y: baseline, width: width, height: h))
        x += width + gap
    }
}

// MARK: The icon

/// Curtain call: the cast (a waveform of standing bars) silhouetted in the light.
func curtainCall(_ ctx: CGContext) {
    begin(ctx); ground(ctx)
    backlight(ctx, center: CGPoint(x: 512, y: 540), radius: 580)
    boards(ctx, top: 300)
    // Long shadows toward the viewer.
    cast(ctx, heights: [150, 250, 360, 250, 150], width: 50, gap: 30, baseline: 300) { r in
        let shadow = CGMutablePath()
        shadow.move(to: CGPoint(x: r.minX, y: r.minY)); shadow.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        let spread = (r.midX - 512) * 0.55
        shadow.addLine(to: CGPoint(x: r.maxX + spread + 18, y: 100)); shadow.addLine(to: CGPoint(x: r.minX + spread - 18, y: 100))
        shadow.closeSubpath()
        ctx.saveGState(); ctx.addPath(shadow); ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0x120803, 0.75)), (1, rgb(0x120803, 0.15))]),
                               start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 100), options: [])
        ctx.restoreGState()
    }
    cast(ctx, heights: [150, 250, 360, 250, 150], width: 50, gap: 30, baseline: 300) { r in
        let bar = CGPath(roundedRect: r, cornerWidth: 25, cornerHeight: 25, transform: nil)
        ctx.addPath(bar); ctx.setFillColor(rgb(0x1A0C05)); ctx.fillPath()
        ctx.addPath(bar); ctx.setStrokeColor(rgb(0xFFE7B8, 0.5)); ctx.setLineWidth(3); ctx.strokePath()
    }
    bothCurtains(ctx, innerTop: 470, tie: CGPoint(x: 214, y: 470), foot: 262)
    end(ctx)
}

// MARK: Output

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    gc.cgContext.interpolationQuality = .high
    gc.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    curtainCall(gc.cgContext)
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
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote the app icon")
