// Draws the Caret app icon (Ember) into Glide/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift   (from the repo root)
import AppKit

let canvas = 1024.0
let inset = 100.0  // Apple's macOS icon grid: an 824 pt shape on a 1024 pt canvas
let side = canvas - 2 * inset

func squircle(_ rect: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let (a, b) = (rect.width / 2, rect.height / 2)
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let (c, s) = (cos(t), sin(t))
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let shape = squircle(CGRect(x: inset, y: inset + 12, width: side, height: side))

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0.3))
ctx.addPath(shape); ctx.setFillColor(color(0xEC4A12)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let top = CGPoint(x: 0, y: inset + 12 + side), bottom = CGPoint(x: 0, y: inset + 12)
let fill = CGGradient(colorsSpace: nil, colors: [color(0xFF9254), color(0xEC4A12)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fill, start: top, end: bottom, options: [])
let shine = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.26), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: top, end: CGPoint(x: 0, y: inset + 12 + side / 2), options: [])
ctx.restoreGState()

// The mark on its 64-unit grid, at 37/64 of the shape, centred; y flips because CG's origin is bottom-left.
let unit = side * 37 / 64 / 64
let origin = CGPoint(x: inset + side * 13.5 / 64, y: inset + 12 + side * 13.5 / 64)
ctx.setFillColor(color(0xFFFFFF))
for (x, y, w, h) in [(8.5, 24.0, 8.0, 16.0), (21.5, 11, 8, 42), (34.5, 19, 8, 26), (50, 8, 5.5, 48)] {
    let rect = CGRect(x: origin.x + x * unit, y: origin.y + (64 - y - h) * unit, width: w * unit, height: h * unit)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: w * unit / 2, cornerHeight: w * unit / 2, transform: nil))
}
ctx.fillPath()

let dir = URL(fileURLWithPath: "Glide/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let master = NSBitmapImageRep(cgImage: ctx.makeImage()!)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents = ["images": images, "info": ["author": "xcode", "version": 1]] as [String: Any]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: dir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icon sizes")
