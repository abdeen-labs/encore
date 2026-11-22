#!/usr/bin/env swift
// Renders the background of the release DMG's window into Config/dmg-background.tiff (1x and 2x in one file).
//
//     swift scripts/render-dmg-background.swift            (run from the repo root)
//
// The window is the app's cream: a call to places in round Allo, a peach blush, and the next step (drag Encore
// to Applications) as the one tangerine thing. Finder draws the two icons and their names on top; the names sit on
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
/// Allo (bundled with the app, SIL OFL 1.1) at a weight and roundness; the system font if it can't be loaded.
func allo(_ size: CGFloat, weight: CGFloat, roundness: CGFloat) -> NSFont {
    let url = repo.appendingPathComponent("Encore/Resources/Fonts/AlloVariable.ttf")
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    func tag(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontNameAttribute: "AlloVariable-Regular",
        kCTFontVariationAttribute: [tag("wght"): weight, tag("opsz"): min(max(size, 9), 32), tag("ROND"): roundness] as [UInt32: CGFloat],
    ] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    return font.fontName.hasPrefix("Allo") ? font : .systemFont(ofSize: size, weight: .bold)
}

let backdrop: UInt32 = 0xF3E9D9, stage: UInt32 = 0xFCF7EF, peach: UInt32 = 0xFFCBA6
let textPrimary: UInt32 = 0x2B1D14, textSecondary: UInt32 = 0x6B5546, textTertiary: UInt32 = 0x7D6757
let tangerine: UInt32 = 0xFF7A2F
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

    // Ground: milk at the top fading to cream, with a peach blush in the top-right corner.
    let ground = NSGradient(colors: [color(stage), color(backdrop)], atLocations: [0, 0.8],
                            colorSpace: .sRGB)!
    ground.draw(in: CGRect(origin: .zero, size: size), angle: -90)
    let blush = NSGradient(colors: [color(peach, 0.55), color(peach, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
    blush.draw(fromCenter: CGPoint(x: size.width, y: 0), radius: 0, toCenter: CGPoint(x: size.width, y: 0), radius: 380,
               options: [])

    // The kicker: the name and what it is, plain.
    let kicker = NSMutableAttributedString()
    kicker.append(NSAttributedString(string: "Encore  ·", attributes: [
        .font: allo(13, weight: 700, roundness: 50), .foregroundColor: color(textSecondary)]))
    kicker.append(NSAttributedString(string: "  Local voice AI for the Mac", attributes: [
        .font: allo(13, weight: 500, roundness: 50), .foregroundColor: color(textTertiary)]))
    kicker.draw(at: CGPoint(x: 48, y: 40))

    // The call, in round Allo.
    NSAttributedString(string: "Places, please.", attributes: [
        .font: allo(64, weight: 800, roundness: 100), .foregroundColor: color(textPrimary), .kern: -1.4,
    ]).draw(at: CGPoint(x: 44, y: 62))

    // The next step, in tangerine: an arrow from Encore to Applications.
    let arrowY = appCenter.y
    let start = appCenter.x + iconSize / 2 + 34, end = applicationsCenter.x - iconSize / 2 - 34
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: start, y: arrowY))
    arrow.line(to: CGPoint(x: end, y: arrowY))
    arrow.move(to: CGPoint(x: end - 11, y: arrowY - 10))
    arrow.line(to: CGPoint(x: end, y: arrowY))
    arrow.line(to: CGPoint(x: end - 11, y: arrowY + 10))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(tangerine).setStroke()
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
