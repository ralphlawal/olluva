// Draws the app icon: two sheets of paper, one resting on the other.
// Usage: swift scripts/make_app_icon.swift <output.png>
//        swift scripts/make_app_icon.swift <output.png> <pixels>
// With a pixel size it writes the icon as iOS shows it on the Home Screen
// (rounded corners, transparent outside them) for the launch screen.
import AppKit
import CoreGraphics

let side = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
    )!
}

// Deep plum field.
context.setFillColor(color(0x302238))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))

func sheet(center: CGPoint, size: CGFloat, degrees: CGFloat, fill: UInt32, shadow: Bool) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: degrees * .pi / 180)
    if shadow {
        context.setShadow(offset: CGSize(width: 0, height: -22), blur: 48, color: color(0x000000, 0.38))
    }
    let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.045, cornerHeight: size * 0.045, transform: nil))
    context.setFillColor(color(fill))
    context.fillPath()
    context.restoreGState()
}

sheet(center: CGPoint(x: 566, y: 556), size: 520, degrees: -10, fill: 0xB7A8D8, shadow: false)
sheet(center: CGPoint(x: 476, y: 478), size: 520, degrees: 7, fill: 0xFFF9EC, shadow: true)

// A small heart, drawn on the front sheet.
context.saveGState()
context.translateBy(x: 476, y: 478)
context.rotate(by: 7 * .pi / 180)
let s: CGFloat = 92
let heart = CGMutablePath()
heart.move(to: CGPoint(x: 0, y: -s * 0.78))
heart.addCurve(to: CGPoint(x: -s, y: s * 0.18), control1: CGPoint(x: -s * 0.55, y: -s * 0.42), control2: CGPoint(x: -s, y: -s * 0.2))
heart.addArc(center: CGPoint(x: -s * 0.5, y: s * 0.22), radius: s * 0.5, startAngle: .pi, endAngle: 0, clockwise: true)
heart.addArc(center: CGPoint(x: s * 0.5, y: s * 0.22), radius: s * 0.5, startAngle: .pi, endAngle: 0, clockwise: true)
heart.addCurve(to: CGPoint(x: 0, y: -s * 0.78), control1: CGPoint(x: s, y: -s * 0.2), control2: CGPoint(x: s * 0.55, y: -s * 0.42))
heart.closeSubpath()
context.addPath(heart)
context.setFillColor(color(0xC9566B))
context.fillPath()
context.restoreGState()

var image = context.makeImage()!
if CommandLine.arguments.count > 2, let pixels = Int(CommandLine.arguments[2]) {
    let tile = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let radius = CGFloat(pixels) * 0.2237
    tile.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    tile.clip()
    tile.interpolationQuality = .high
    tile.draw(image, in: rect)
    image = tile.makeImage()!
}
let bitmap = NSBitmapImageRep(cgImage: image)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
