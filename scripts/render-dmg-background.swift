#!/usr/bin/env swift
// Renders the background of the release DMG's window into Config/dmg-background.tiff (1x and 2x in one file).
//
//     swift scripts/render-dmg-background.swift            (run from the repo root)
//
// The window is the stage after dark: a call to places in the display serif, and the next step (drag Encore to
// Applications) as the one lit thing. Finder draws the two icons and their names on top; the names sit on
// mid-tone capsules so they read in both appearances (Finder draws them black in light mode, white in dark).
// The positions here and in Config/dmg-settings.py go together: change both.

import AppKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = repo.appendingPathComponent("Config/dmg-background.tiff")

// The window's content, in points. Config/dmg-settings.py: window_rect, icon_locations, icon_size, text_size.
let size = CGSize(width: 660, height: 400)
let appCenter = CGPoint(x: 190, y: 262)          // from the top-left, like Finder's icon_locations
let applicationsCenter = CGPoint(x: 470, y: 262)
let iconSize: CGFloat = 112
let labelTop: CGFloat = appCenter.y + iconSize / 2 + 7     // where Finder starts the name, below the icon
let capsules = [(appCenter.x, CGFloat(84)), (applicationsCenter.x, CGFloat(118))]   // center x, width

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func font(_ names: [String], _ size: CGFloat, fallback: NSFont) -> NSFont {
    names.lazy.compactMap { NSFont(name: $0, size: size) }.first ?? fallback
}

let backdrop: UInt32 = 0x0E0C0B, stage: UInt32 = 0x1A1612
let textPrimary: UInt32 = 0xF4EDE4, textSecondary: UInt32 = 0xA99E92, textTertiary: UInt32 = 0x8F857A
let tungsten: UInt32 = 0xFFB648
// About 4.5:1 against both black and white text: Finder's label color depends on the appearance.
let capsule: UInt32 = 0x7D736A

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // Flip so y runs down from the top, like Finder's coordinates.
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current = flipped

    // Ground: the backdrop, a breath warmer toward the top, where the light comes from.
    let ground = NSGradient(colors: [color(stage), color(backdrop)], atLocations: [0, 0.75],
                            colorSpace: .sRGB)!
    ground.draw(in: CGRect(origin: .zero, size: size), angle: 90)

    // The kicker: the name and what it is, plain, in mono capitals.
    let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    let kicker = NSMutableAttributedString()
    kicker.append(NSAttributedString(string: "ENCORE  ·", attributes: [
        .font: mono, .foregroundColor: color(textSecondary), .kern: 2.2]))
    kicker.append(NSAttributedString(string: "  LOCAL VOICE AI FOR THE MAC", attributes: [
        .font: mono, .foregroundColor: color(textTertiary), .kern: 2.2]))
    kicker.draw(at: CGPoint(x: 48, y: 38))

    // The call, in the display serif.
    let display = font(["BodoniSvtyTwoITCTT-Book", "Didot"], 84, fallback: .systemFont(ofSize: 84))
    NSAttributedString(string: "Places, please.", attributes: [
        .font: display, .foregroundColor: color(textPrimary), .kern: -1.6,
    ]).draw(at: CGPoint(x: 42, y: 50))

    // The next step, lit: an arrow from Encore to Applications.
    let arrowY = appCenter.y
    let start = appCenter.x + iconSize / 2 + 34, end = applicationsCenter.x - iconSize / 2 - 34
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: start, y: arrowY))
    arrow.line(to: CGPoint(x: end, y: arrowY))
    arrow.move(to: CGPoint(x: end - 11, y: arrowY - 10))
    arrow.line(to: CGPoint(x: end, y: arrowY))
    arrow.line(to: CGPoint(x: end - 11, y: arrowY + 10))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(tungsten).setStroke()
    arrow.stroke()

    // Capsules under the names.
    for (centerX, width) in capsules {
        let rect = CGRect(x: centerX - width / 2, y: labelTop - 3, width: width, height: 23)
        color(capsule).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11.5, yRadius: 11.5).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(draw(scale: 1))
image.addRepresentation(draw(scale: 2))
guard let tiff = image.tiffRepresentation(using: .lzw, factor: 0) else { fatalError("couldn't encode the TIFF") }
try tiff.write(to: output)
print("Wrote \(output.path)")
