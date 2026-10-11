// Builds the App Store screenshots: a headline over the app shown in a phone.
// Usage: swift scripts/make_store_screenshots.swift <raw screenshots dir> <widgets dir> <output dir>
// The raw screenshots come from the UI tests (see TESTING.md); the output
// keeps their exact pixel size, which is what App Store Connect checks.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fatalError("usage: <raw dir> <widgets dir> <output dir>") }
let rawDirectory = URL(fileURLWithPath: arguments[1])
let widgetDirectory = URL(fileURLWithPath: arguments[2])
let outputDirectory = URL(fileURLWithPath: arguments[3])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("cannot read \(url.path)") }
    return image
}

func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

struct Look {
    let top: UInt32, bottom: UInt32, lead: UInt32, headline: UInt32
    static let paper = Look(top: 0xFAF7F2, bottom: 0xF1E3E4, lead: 0x8A8290, headline: 0x302238)
    static let plum = Look(top: 0x3B2A45, bottom: 0x241A2B, lead: 0xC9BCD6, headline: 0xFFF9EC)
    static let lilac = Look(top: 0xF4F0FA, bottom: 0xE2D8F2, lead: 0x8A8290, headline: 0x302238)
}

/// Starts a canvas with the background and the two-line headline drawn.
/// Returns the context and the y coordinate (from the top) where content may start.
func canvas(width: Int, height: Int, look: Look, lead: String, headline: String) -> (CGContext, CGFloat) {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let gradient = CGGradient(colorsSpace: space, colors: [color(look.top), color(look.bottom)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])

    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let unit = CGFloat(width) / 1206
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineHeightMultiple = 0.95
    let text = NSMutableAttributedString(string: lead + "\n", attributes: [
        .font: serif(62 * unit, .regular), .foregroundColor: NSColor(cgColor: color(look.lead))!, .paragraphStyle: paragraph,
    ])
    text.append(NSAttributedString(string: headline, attributes: [
        .font: serif(104 * unit, .bold), .foregroundColor: NSColor(cgColor: color(look.headline))!, .paragraphStyle: paragraph,
    ]))
    let textWidth = CGFloat(width) - 150 * unit
    let box = text.boundingRect(with: CGSize(width: textWidth, height: 2000), options: [.usesLineFragmentOrigin])
    let topMargin = 150 * unit
    text.draw(with: CGRect(x: 75 * unit, y: CGFloat(height) - topMargin - box.height, width: textWidth, height: box.height), options: [.usesLineFragmentOrigin])
    return (context, topMargin + box.height + 90 * unit)
}

func save(_ context: CGContext, _ name: String) {
    let url = outputDirectory.appendingPathComponent(name)
    try! NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent)")
}

/// The app in a phone, running off the bottom edge.
func framed(_ source: String, _ name: String, look: Look, lead: String, headline: String) {
    let screen = load(rawDirectory.appendingPathComponent(source))
    let (context, contentTop) = canvas(width: screen.width, height: screen.height, look: look, lead: lead, headline: headline)
    let width = CGFloat(screen.width), height = CGFloat(screen.height), unit = width / 1206

    let bezel = 20 * unit
    let phoneWidth = 940 * unit
    let screenWidth = phoneWidth - bezel * 2
    let screenHeight = screenWidth * height / width
    let phoneHeight = screenHeight + bezel * 2
    let phone = CGRect(x: (width - phoneWidth) / 2, y: height - contentTop - phoneHeight, width: phoneWidth, height: phoneHeight)
    let radius = 150 * unit

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -30 * unit), blur: 90 * unit, color: color(0x241A2B, 0.35))
    context.addPath(CGPath(roundedRect: phone, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color(0x15101A))
    context.fillPath()
    context.restoreGState()

    let glass = phone.insetBy(dx: bezel, dy: bezel)
    context.saveGState()
    context.addPath(CGPath(roundedRect: glass, cornerWidth: radius - bezel, cornerHeight: radius - bezel, transform: nil))
    context.clip()
    context.interpolationQuality = .high
    context.draw(screen, in: glass)
    context.restoreGState()
    save(context, name)
}

/// The widgets on their own, as they sit on a Home Screen.
func widgets(_ name: String, width: Int, height: Int, lead: String, headline: String) {
    let (context, contentTop) = canvas(width: width, height: height, look: .plum, lead: lead, headline: headline)
    let unit = CGFloat(width) / 1206
    let column = 900 * unit, gap = 44 * unit
    let left = (CGFloat(width) - column) / 2
    var y = CGFloat(height) - contentTop

    func place(_ file: String, x: CGFloat, width: CGFloat) -> CGFloat {
        let image = load(widgetDirectory.appendingPathComponent(file))
        let drawHeight = width * CGFloat(image.height) / CGFloat(image.width)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18 * unit), blur: 50 * unit, color: color(0x000000, 0.4))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: x, y: y - drawHeight, width: width, height: drawHeight))
        context.restoreGState()
        return drawHeight
    }

    y -= place("large.png", x: left, width: column) + gap
    y -= place("medium.png", x: left, width: column) + gap
    let half = (column - gap) / 2
    _ = place("small.png", x: left, width: half)
    _ = place("small-bold.png", x: left + half + gap, width: half)
    save(context, name)
}

let sample = load(rawDirectory.appendingPathComponent("01-today.png"))
framed("01-today.png", "01-notes.png", look: .paper, lead: "A private space for two", headline: "Little notes from\nyour person")
widgets("02-widgets.png", width: sample.width, height: sample.height, lead: "No need to open the app", headline: "Right on their\nHome Screen")
framed("02-write.png", "03-write.png", look: .lilac, lead: "Paper, ink and handwriting", headline: "Say it\nyour way")
framed("03-draw.png", "04-draw.png", look: .paper, lead: "When words won’t do", headline: "Or just\ndraw it")
framed("04-memories.png", "05-memories.png", look: .plum, lead: "A scrapbook for you both", headline: "Keep the ones\nyou love")
framed("05-dates.png", "06-dates.png", look: .lilac, lead: "Birthdays, anniversaries, firsts", headline: "Never miss a date\nthat matters")
