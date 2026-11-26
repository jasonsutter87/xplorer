// Renders a simple app icon (blue rounded square + folder + tree lines) into an .iconset folder.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.55, blue: 1, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.27, blue: 0.75, alpha: 1))!.draw(in: bg, angle: -90)
    // folder
    let y = NSColor(calibratedRed: 1, green: 0.8, blue: 0.25, alpha: 1)
    y.setFill()
    NSBezierPath(roundedRect: NSRect(x: s*0.36, y: s*0.52, width: s*0.16, height: s*0.08), xRadius: s*0.02, yRadius: s*0.02).fill()
    NSBezierPath(roundedRect: NSRect(x: s*0.36, y: s*0.28, width: s*0.42, height: s*0.29), xRadius: s*0.03, yRadius: s*0.03).fill()
    // tree lines
    NSColor.white.withAlphaComponent(0.9).setStroke()
    let p = NSBezierPath(); p.lineWidth = s * 0.03; p.lineCapStyle = .round
    p.move(to: NSPoint(x: s*0.24, y: s*0.76)); p.line(to: NSPoint(x: s*0.24, y: s*0.42)); p.line(to: NSPoint(x: s*0.32, y: s*0.42))
    p.move(to: NSPoint(x: s*0.24, y: s*0.68)); p.line(to: NSPoint(x: s*0.40, y: s*0.68))
    p.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: s*0.19, y: s*0.71, width: s*0.1, height: s*0.1)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
