import AppKit
// 元の Tera Term のアイコン (teraterm/common/teraterm.ico) から AppIcon.iconset を作る
//   swift scripts/make_icon.swift ../teraterm/common/teraterm.ico <出力.iconset>
let ico = CommandLine.arguments[1], out = CommandLine.arguments[2]
guard let img = NSImage(contentsOfFile: ico) else { fatalError("ico を読めません") }
// いちばん大きい絵 (256px) を元にする。小さいサイズは ico の中の同じ大きさの絵があればそれを使う
let reps = img.representations.compactMap { $0 as? NSBitmapImageRep }
func best(_ px: Int) -> NSBitmapImageRep {
    if let exact = reps.filter({ $0.pixelsWide == px && $0.bitsPerPixel >= 32 }).first { return exact }
    return reps.max(by: { $0.pixelsWide < $1.pixelsWide })!
}
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let src = best(px)
    let dst = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: dst)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    src.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()
    try! dst.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
