// Draws the App Store product page header: three notes resting on the
// app's plum field. Decorative only, with nothing near the edges, because the
// store lays its own text and controls over the image.
// Usage: swift scripts/make_store_header.swift <output.png> <width> <height>
import AppKit

let args = CommandLine.arguments
let width = args.count > 2 ? Int(args[2]) ?? 3840 : 3840
let height = args.count > 3 ? Int(args[3]) ?? 1646 : 1646
let output = args.count > 1 ? args[1] : "header.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

context.setFillColor(color(0x302238))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

// A soft lighter pool behind the notes, so they do not sit on a flat colour.
let glow = CGGradient(colorsSpace: space, colors: [color(0x4A3657, 0.9), color(0x302238, 0)] as CFArray, locations: [0, 1])!
let centre = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
context.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: CGFloat(height) * 0.95, options: [])

let side = CGFloat(height) * 0.5
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

func note(dx: CGFloat, dy: CGFloat, degrees: CGFloat, paper: UInt32, ink: UInt32, text: String, font: String, size: CGFloat, heart: Bool = false) {
    context.saveGState()
    context.translateBy(x: centre.x + dx * side, y: centre.y + dy * side)
    context.rotate(by: degrees * .pi / 180)
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.035), blur: side * 0.09, color: color(0x000000, 0.4))
    let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.02, cornerHeight: side * 0.02, transform: nil))
    context.setFillColor(color(paper))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineSpacing = side * 0.012
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: font, size: side * size) ?? NSFont.systemFont(ofSize: side * size),
        .foregroundColor: NSColor(cgColor: color(ink))!,
        .paragraphStyle: paragraph,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let box = string.boundingRect(with: CGSize(width: side * 0.78, height: side), options: [.usesLineFragmentOrigin])
    string.draw(with: CGRect(x: -side * 0.39, y: -box.height / 2, width: side * 0.78, height: box.height), options: [.usesLineFragmentOrigin])

    if heart {
        let s = side * 0.055
        context.translateBy(x: side * 0.3, y: -side * 0.3)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -s * 0.78))
        path.addCurve(to: CGPoint(x: -s, y: s * 0.18), control1: CGPoint(x: -s * 0.55, y: -s * 0.42), control2: CGPoint(x: -s, y: -s * 0.2))
        path.addArc(center: CGPoint(x: -s * 0.5, y: s * 0.22), radius: s * 0.5, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addArc(center: CGPoint(x: s * 0.5, y: s * 0.22), radius: s * 0.5, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addCurve(to: CGPoint(x: 0, y: -s * 0.78), control1: CGPoint(x: s, y: -s * 0.2), control2: CGPoint(x: s * 0.55, y: -s * 0.42))
        context.addPath(path)
        context.setFillColor(color(0xC9566B))
        context.fillPath()
    }
    context.restoreGState()
}

note(dx: -1.02, dy: 0.04, degrees: 8, paper: 0xE9E2F5, ink: 0x302238, text: "Dinner at ours\ntonight?", font: "Iowan Old Style", size: 0.085)
note(dx: 1.02, dy: 0.06, degrees: -7, paper: 0xF9E4E4, ink: 0xB4566A, text: "Good luck today.\nYou’ve got this.", font: "Bradley Hand", size: 0.095)
note(dx: 0, dy: -0.05, degrees: 2, paper: 0xFFF9EC, ink: 0x302238, text: "Thinking\nof you", font: "Bradley Hand", size: 0.13, heart: true)

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output) \(width)x\(height)")
