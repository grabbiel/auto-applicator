// Draws the disk image window's background in the app's look: white, a heavy headline, and a green dotted arc from
// the app to Applications.
// usage: swift scripts/make_dmg_background.swift <output dir>   → background.png (660×420) and background@2x.png
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let width: CGFloat = 660, height: CGFloat = 420
/// Icon centers in Finder's top-left coordinates (package.sh places the icons at the same points).
let appCenter = CGPoint(x: 170, y: 210), appsCenter = CGPoint(x: 490, y: 210)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(scale: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Flip to top-left coordinates, like Finder's.
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)

    ctx.setFillColor(color(0xFFFFFF))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A faint green glow behind the app's spot.
    let glow = CGGradient(colorsSpace: cs, colors: [color(0x03C75A, 0.14), color(0x03C75A, 0)] as CFArray, locations: [0, 1])!
    // (Finder draws an icon a little below the point it's placed at.)
    let glowCenter = CGPoint(x: appCenter.x, y: appCenter.y + 30)
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 150, options: [])

    // Headline and hint, drawn with AppKit text (flipped context).
    let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let heavy = NSFont.systemFont(ofSize: 26, weight: .heavy)
    ("Drag to Applications to install" as NSString).draw(
        in: CGRect(x: 0, y: 44, width: width, height: 36),
        withAttributes: [.font: heavy, .foregroundColor: NSColor(cgColor: color(0x000000))!, .paragraphStyle: paragraph])
    ("Then open Auto Applicator from your Applications folder." as NSString).draw(
        in: CGRect(x: 0, y: 84, width: width, height: 22),
        withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(cgColor: color(0x737373))!, .paragraphStyle: paragraph])
    NSGraphicsContext.restoreGraphicsState()

    // The dotted flight path, arching over the gap between the two icons, ending in a small plane.
    let start = CGPoint(x: appCenter.x + 78, y: appCenter.y - 8), end = CGPoint(x: appsCenter.x - 84, y: appsCenter.y - 8)
    let control = CGPoint(x: (start.x + end.x) / 2, y: appCenter.y - 86)
    let path = CGMutablePath()
    path.move(to: start)
    path.addQuadCurve(to: end, control: control)
    ctx.addPath(path)
    ctx.setStrokeColor(color(0x03C75A))
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [0.1, 9])
    ctx.strokePath()

    // Paper plane at the end, pointing along the curve's final direction.
    let angle = atan2(end.y - control.y, end.x - control.x)
    ctx.saveGState()
    ctx.translateBy(x: end.x + 4, y: end.y + 2)
    ctx.rotate(by: angle)
    let plane = CGMutablePath()
    plane.move(to: CGPoint(x: 12, y: 0))
    plane.addLine(to: CGPoint(x: -9, y: -8))
    plane.addLine(to: CGPoint(x: -4, y: 0))
    plane.addLine(to: CGPoint(x: -9, y: 8))
    plane.closeSubpath()
    ctx.addPath(plane)
    ctx.setFillColor(color(0x03C75A))
    ctx.fillPath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    let rep = NSBitmapImageRep(cgImage: render(scale: scale))
    rep.size = NSSize(width: width, height: height)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("Wrote background.png and background@2x.png to \(out.path)")
