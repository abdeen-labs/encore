#!/usr/bin/env swift
// Renders Encore's app icons.
//
//     swift scripts/render-app-icon.swift            (run from the repo root)
//
// The app icon (Encore/Assets.xcassets/AppIcon.appiconset) is a chatty speech bubble: a tangerine bubble with a
// cream waveform inside, tilted, with a few sprinkles, on a cream tile with a peach blush. The alternate icon
// (AppIconCandy.appiconset, picked in Settings). DockIconBubble and DockIconCandy are the same two as plain images. is a cast of five candy bars. Both are drawn like the app's buttons:
// a soft key on a darker lip. No letterforms.

import AppKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = repo.appendingPathComponent("Encore/Assets.xcassets")

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

func begin(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x4A3022, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0xF6EBDA)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFF9F0)), (1, rgb(0xF2E3CC))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Peach blush in the top-right corner.
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFCBA6, 0.55)), (1, rgb(0xFFCBA6, 0))]),
                           startCenter: CGPoint(x: 880, y: 900), startRadius: 0, endCenter: CGPoint(x: 880, y: 900), endRadius: 520, options: [])
}
func end(_ ctx: CGContext) {
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0x4A3022, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
}

/// Fills `path` as a soft key: a darker lip underneath, then the face with a top-lit gradient.
func softKey(_ ctx: CGContext, _ path: CGPath, top: UInt32, bottom: UInt32, lip: UInt32, lipDepth: CGFloat = 22) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -lipDepth - 10), blur: 30, color: rgb(0x4A3022, 0.22))
    ctx.translateBy(x: 0, y: -lipDepth); ctx.addPath(path); ctx.setFillColor(rgb(lip)); ctx.fillPath()
    ctx.restoreGState()
    let box = path.boundingBox
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(top)), (1, rgb(bottom))]),
                           start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    ctx.restoreGState()
}

func sprinkle(_ ctx: CGContext, _ c: CGPoint, _ size: CGSize, _ color: UInt32, _ angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: angle * .pi / 180)
    let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(size.width, size.height) / 2, cornerHeight: min(size.width, size.height) / 2, transform: nil))
    ctx.setFillColor(rgb(color)); ctx.fillPath()
    ctx.restoreGState()
}

func bars(_ ctx: CGContext, heights: [CGFloat], width: CGFloat, gap: CGFloat, center: CGPoint, color: (Int) -> UInt32) {
    let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
    var x = center.x - total / 2
    for (i, h) in heights.enumerated() {
        let r = CGRect(x: x, y: center.y - h / 2, width: width, height: h)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
        ctx.setFillColor(rgb(color(i))); ctx.fillPath()
        x += width + gap
    }
}

// MARK: The icons

/// The app icon: a chunky tangerine speech bubble with a cream waveform, tilted, with sprinkles.
func bubble(_ ctx: CGContext) {
    begin(ctx)
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 530); ctx.rotate(by: 7 * .pi / 180); ctx.translateBy(x: -512, y: -530)
    let shape = CGMutablePath()
    shape.addRoundedRect(in: CGRect(x: 232, y: 340, width: 560, height: 420), cornerWidth: 190, cornerHeight: 190)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 330, y: 400))
    tail.addCurve(to: CGPoint(x: 268, y: 250), control1: CGPoint(x: 320, y: 330), control2: CGPoint(x: 300, y: 280))
    tail.addCurve(to: CGPoint(x: 460, y: 352), control1: CGPoint(x: 360, y: 262), control2: CGPoint(x: 420, y: 300))
    tail.closeSubpath()
    let whole = shape.union(tail)
    softKey(ctx, whole, top: 0xFF9A5C, bottom: 0xFF7A2F, lip: 0xE2560F)
    bars(ctx, heights: [100, 190, 270, 190, 100], width: 46, gap: 32, center: CGPoint(x: 512, y: 550)) { _ in 0xFFF6EA }
    ctx.restoreGState()
    sprinkle(ctx, CGPoint(x: 230, y: 790), CGSize(width: 70, height: 26), 0xF6B93B, -30)
    sprinkle(ctx, CGPoint(x: 820, y: 800), CGSize(width: 40, height: 40), 0xA284F2, 0)
    sprinkle(ctx, CGPoint(x: 830, y: 300), CGSize(width: 72, height: 26), 0x56B37A, 35)
    sprinkle(ctx, CGPoint(x: 700, y: 210), CGSize(width: 32, height: 32), 0xEC4F5A, 0)
    end(ctx)
}

/// The alternate icon: a cast of five candy bars taking a bow, each a soft key.
func candyBow(_ ctx: CGContext) {
    begin(ctx)
    let heights: [CGFloat] = [250, 400, 540, 400, 250]
    let colors: [(UInt32, UInt32, UInt32)] = [
        (0xFFD06A, 0xF6B93B, 0xD39418), (0xFF9A5C, 0xFF7A2F, 0xE2560F), (0xFF7F88, 0xEC4F5A, 0xC23441),
        (0xBBA4F7, 0xA284F2, 0x7E5FD6), (0x7CCB98, 0x56B37A, 0x3C9160),
    ]
    let width: CGFloat = 104, gap: CGFloat = 34
    let total = 5 * width + 4 * gap
    var x = 512 - total / 2
    for (i, h) in heights.enumerated() {
        let r = CGRect(x: x, y: 512 - h / 2 + 10, width: width, height: h)
        let p = CGPath(roundedRect: r, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        softKey(ctx, p, top: colors[i].0, bottom: colors[i].1, lip: colors[i].2, lipDepth: 18)
        x += width + gap
    }
    end(ctx)
}

// MARK: Output

func render(_ draw: (CGContext) -> Void, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    gc.cgContext.interpolationQuality = .high
    gc.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(gc.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func writeContents(_ contents: [String: Any], to dir: URL) {
    let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try! json.write(to: dir.appendingPathComponent("Contents.json"))
}

// The app icons, every size macOS asks for: the main one and the alternate (listed in the target's
// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES).
for (setName, draw) in [("AppIcon", bubble), ("AppIconCandy", candyBow)] as [(String, (CGContext) -> Void)] {
    let dir = assets.appendingPathComponent("\(setName).appiconset")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try! render(draw, pixels: px).write(to: dir.appendingPathComponent(name))
            images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
        }
    }
    writeContents(["images": images, "info": ["author": "xcode", "version": 1]], to: dir)
}

// Both icons again as plain images: the app sets the chosen one as its Dock icon and shows them in Settings, and
// the Dock tile plug-in draws them while Encore is closed. (Reading the bundle's icon back goes through the system
// icon cache, which can lag behind a new build.)
for (setName, draw) in [("DockIconBubble", bubble), ("DockIconCandy", candyBow)] as [(String, (CGContext) -> Void)] {
    let dir = assets.appendingPathComponent("\(setName).imageset")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! render(draw, pixels: 512).write(to: dir.appendingPathComponent("icon_512.png"))
    try! render(draw, pixels: 1024).write(to: dir.appendingPathComponent("icon_1024.png"))
    writeContents(["images": [["idiom": "universal", "scale": "1x", "filename": "icon_512.png"],
                              ["idiom": "universal", "scale": "2x", "filename": "icon_1024.png"]],
                   "info": ["author": "xcode", "version": 1]], to: dir)
}
print("wrote the app icons")
