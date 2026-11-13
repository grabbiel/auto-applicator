// Draws the app icon: a résumé sheet on a green squircle (the app's #03C75A), with a white paper plane taking off from it.
// usage: swift scripts/make_icon.swift <output dir>   → AppIcon.icns (+ AppIcon-1024.png for the README)
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.setShouldAntialias(true)

    // Squircle tile (macOS grid: 824 pt body, 100 pt margin) with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x03C75A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let green = CGGradient(colorsSpace: cs, colors: [color(0x1FD46E), color(0x03C75A), color(0x00A84C)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(green, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // soft light where the plane leaves
    let glow = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.1), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 700, y: 690), startRadius: 0, endCenter: CGPoint(x: 700, y: 690), endRadius: 420, options: [])
    // fine top highlight
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.setLineWidth(3)
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    // The sheet, tilted a little.
    ctx.saveGState()
    ctx.translateBy(x: 430, y: 470)
    ctx.rotate(by: -0.07)
    let sheet = CGRect(x: -190, y: -245, width: 380, height: 490)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x00451F, 0.4))
    ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // header: an avatar dot and a name bar
    ctx.setFillColor(color(0x03C75A))
    ctx.fillEllipse(in: CGRect(x: -140, y: 128, width: 72, height: 72))
    ctx.setFillColor(color(0x1E1E23))
    ctx.addPath(CGPath(roundedRect: CGRect(x: -48, y: 168, width: 190, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(color(0xB5B8BD))
    ctx.addPath(CGPath(roundedRect: CGRect(x: -48, y: 132, width: 130, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.fillPath()
    // body lines
    for (i, w) in [280.0, 240, 262, 200, 250, 150].enumerated() {
        ctx.setFillColor(color(i % 3 == 0 ? 0xD3D6DA : 0xE5E7EA))
        ctx.addPath(CGPath(roundedRect: CGRect(x: -140, y: 60 - Double(i) * 46, width: w, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Dotted flight trail from the sheet to the plane.
    ctx.saveGState()
    let trail = CGMutablePath()
    trail.move(to: CGPoint(x: 545, y: 440))
    trail.addCurve(to: CGPoint(x: 690, y: 655), control1: CGPoint(x: 640, y: 450), control2: CGPoint(x: 600, y: 610))
    ctx.addPath(trail)
    ctx.setStrokeColor(color(0xFFFFFF, 0.9))
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [1, 30])
    ctx.strokePath()
    ctx.restoreGState()

    // The paper plane.
    ctx.saveGState()
    ctx.translateBy(x: 735, y: 700)
    ctx.rotate(by: 0.42)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x003A1A, 0.6))
    let plane = CGMutablePath()
    plane.move(to: CGPoint(x: 150, y: 0))        // nose
    plane.addLine(to: CGPoint(x: -130, y: 112))   // left wing tip
    plane.addLine(to: CGPoint(x: -62, y: 6))      // fold
    plane.addLine(to: CGPoint(x: -130, y: -96))   // right wing tip
    plane.closeSubpath()
    ctx.addPath(plane)  // first a plain fill, which casts the shadow (a clip alone doesn't)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.addPath(plane)
    ctx.clip()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let paper = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF), color(0xF4F6F8), color(0xE3E7EB)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: -130, y: 112), end: CGPoint(x: 150, y: -60), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // the lower wing in shade, for depth
    let lower = CGMutablePath()
    lower.move(to: CGPoint(x: 150, y: 0))
    lower.addLine(to: CGPoint(x: -62, y: 6))
    lower.addLine(to: CGPoint(x: -130, y: -96))
    lower.closeSubpath()
    ctx.addPath(lower)
    ctx.setFillColor(color(0x0A5C30, 0.3))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(draw(size: base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(draw(size: base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(draw(size: 1024)).write(to: out.appendingPathComponent("AppIcon-1024.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote \(out.path)/AppIcon.icns" : "iconutil failed")
