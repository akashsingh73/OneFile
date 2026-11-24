// Draws OneFile's app icon at every size macOS uses and writes OneFile/AppIcon.icns.
// The icon is many small tiles, an arrow, and one file with the same tiles packed inside it.
//
// Run it from the repository folder after changing the design:
//     swift Tools/make-icon.swift
import AppKit
import SwiftUI

let output = "OneFile/AppIcon.icns"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    Path(roundedRect: rect, cornerRadius: radius, style: .continuous).cgPath
}

/// Draws the icon into a square context `side` pixels wide, in Apple's 1024-point icon grid.
func drawIcon(in ctx: CGContext, side: CGFloat) {
    let u = side / 1024
    let top = rgb(0.17, 0.70, 0.88)
    let bottom = rgb(0.10, 0.30, 0.72)

    // The body: a rounded square of 824 points centred in 1024, with a soft shadow.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let bodyPath = rounded(body, 185 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 28 * u, color: rgb(0, 0, 0, 0.30))
    ctx.addPath(bodyPath)
    ctx.setFillColor(bottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([top, bottom], [0, 1]), start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])
    // A soft light from the top left.
    ctx.drawRadialGradient(gradient([rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)], [0, 1]),
                           startCenter: CGPoint(x: 300 * u, y: 860 * u), startRadius: 0,
                           endCenter: CGPoint(x: 300 * u, y: 860 * u), endRadius: 620 * u, options: [])

    // Many files: a 3 × 3 grid of tiles.
    let tile = 84 * u, gap = 18 * u
    let gridOrigin = CGPoint(x: 168 * u, y: 368 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 14 * u, color: rgb(0, 0, 0, 0.22))
    for row in 0..<3 {
        for column in 0..<3 {
            let rect = CGRect(x: gridOrigin.x + CGFloat(column) * (tile + gap),
                              y: gridOrigin.y + CGFloat(row) * (tile + gap), width: tile, height: tile)
            ctx.addPath(rounded(rect, 18 * u))
            ctx.setFillColor(rgb(1, 1, 1, 0.92))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()

    // The arrow.
    ctx.saveGState()
    ctx.setStrokeColor(rgb(1, 1, 1, 0.95))
    ctx.setLineWidth(30 * u)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 506 * u, y: 576 * u))
    ctx.addLine(to: CGPoint(x: 548 * u, y: 512 * u))
    ctx.addLine(to: CGPoint(x: 506 * u, y: 448 * u))
    ctx.strokePath()
    ctx.restoreGState()

    // One file, its top right corner folded over, with the tiles packed inside.
    let file = CGRect(x: 592 * u, y: 340 * u, width: 264 * u, height: 344 * u)
    let fold = 78 * u
    let radius = 30 * u
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: file.minX + radius, y: file.minY))
    outline.addLine(to: CGPoint(x: file.maxX - radius, y: file.minY))
    outline.addArc(tangent1End: CGPoint(x: file.maxX, y: file.minY), tangent2End: CGPoint(x: file.maxX, y: file.minY + radius), radius: radius)
    outline.addLine(to: CGPoint(x: file.maxX, y: file.maxY - fold))
    outline.addLine(to: CGPoint(x: file.maxX - fold, y: file.maxY))
    outline.addLine(to: CGPoint(x: file.minX + radius, y: file.maxY))
    outline.addArc(tangent1End: CGPoint(x: file.minX, y: file.maxY), tangent2End: CGPoint(x: file.minX, y: file.maxY - radius), radius: radius)
    outline.addLine(to: CGPoint(x: file.minX, y: file.minY + radius))
    outline.addArc(tangent1End: CGPoint(x: file.minX, y: file.minY), tangent2End: CGPoint(x: file.minX + radius, y: file.minY), radius: radius)
    outline.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 22 * u, color: rgb(0, 0, 0, 0.28))
    ctx.addPath(outline)
    ctx.setFillColor(rgb(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1), rgb(0.90, 0.94, 0.98)], [0, 1]),
                           start: CGPoint(x: 0, y: file.maxY), end: CGPoint(x: 0, y: file.minY), options: [])
    ctx.restoreGState()
    // The fold.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: file.maxX - fold, y: file.maxY))
    flap.addLine(to: CGPoint(x: file.maxX - fold, y: file.maxY - fold + 14 * u))
    flap.addQuadCurve(to: CGPoint(x: file.maxX - fold + 14 * u, y: file.maxY - fold),
                      control: CGPoint(x: file.maxX - fold, y: file.maxY - fold))
    flap.addLine(to: CGPoint(x: file.maxX, y: file.maxY - fold))
    flap.closeSubpath()
    ctx.addPath(flap)
    ctx.setFillColor(rgb(0.76, 0.84, 0.93))
    ctx.fillPath()

    // The same tiles, small, packed inside the file.
    let small = 40 * u, smallGap = 12 * u
    let packed = 3 * small + 2 * smallGap
    let packedOrigin = CGPoint(x: file.midX - packed / 2, y: file.minY + 64 * u)
    for row in 0..<3 {
        for column in 0..<3 {
            let rect = CGRect(x: packedOrigin.x + CGFloat(column) * (small + smallGap),
                              y: packedOrigin.y + CGFloat(row) * (small + smallGap), width: small, height: small)
            ctx.saveGState()
            ctx.addPath(rounded(rect, 9 * u))
            ctx.clip()
            ctx.drawLinearGradient(gradient([top, bottom], [0, 1]), start: CGPoint(x: 0, y: rect.maxY),
                                   end: CGPoint(x: 0, y: rect.minY), options: [])
            ctx.restoreGState()
        }
    }

    ctx.restoreGState()
}

func png(side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    drawIcon(in: context.cgContext, side: CGFloat(side))
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("OneFileIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, side) in variants {
    try png(side: side).write(to: iconset.appendingPathComponent(name + ".png"))
}
if CommandLine.arguments.count > 1 {
    // `swift Tools/make-icon.swift preview.png` also writes the 1024-pixel image, to look at.
    try png(side: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed")
    exit(1)
}
print("Wrote \(output)")
