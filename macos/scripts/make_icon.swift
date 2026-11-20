import AppKit
// アイコンを描いて AppIcon.icns の元になる PNG 群を作る
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(x: s*0.1, y: s*0.1, width: s*0.8, height: s*0.8)
    let body = NSBezierPath(roundedRect: r, xRadius: s*0.16, yRadius: s*0.16)
    NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.16, blue: 0.30, alpha: 1), ending: NSColor(srgbRed: 0.02, green: 0.04, blue: 0.10, alpha: 1))!.draw(in: body, angle: -90)
    NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 1).setStroke()
    body.lineWidth = max(1, s*0.02); body.stroke()
    let green = NSColor(srgbRed: 0.35, green: 1.0, blue: 0.55, alpha: 1)
    let p = NSBezierPath()
    p.lineWidth = s*0.06; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: s*0.25, y: s*0.62)); p.line(to: NSPoint(x: s*0.40, y: s*0.50)); p.line(to: NSPoint(x: s*0.25, y: s*0.38))
    green.setStroke(); p.stroke()
    green.setFill()
    NSRect(x: s*0.46, y: s*0.34, width: s*0.26, height: s*0.06).fill()
    let t = "TT" as NSString
    let f = NSFont.boldSystemFont(ofSize: s*0.13)
    t.draw(at: NSPoint(x: s*0.62, y: s*0.68), withAttributes: [.font: f, .foregroundColor: NSColor(srgbRed: 0.6, green: 0.75, blue: 1, alpha: 1)])
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
