import CoupleDomain
import SwiftUI

/// Renders a note exactly as its author composed it.
///
/// Everything is laid out in proportion to the card's side, so the same note
/// looks the same full-size in the app, small in the scrapbook, and in a
/// widget. This one view is used in all three places.
public struct NoteCardView: View {
    @Environment(\.colorScheme) private var scheme

    private let content: NoteContent
    private let photo: CGImage?
    private let drawing: CGImage?
    private let showsText: Bool
    private let dimsInDarkMode: Bool

    /// - Parameters:
    ///   - showsText: `false` while the composer overlays its own editable text.
    ///   - dimsInDarkMode: use the softer paper tone in dark appearance.
    public init(
        content: NoteContent, photo: CGImage? = nil, drawing: CGImage? = nil,
        showsText: Bool = true, dimsInDarkMode: Bool = true
    ) {
        self.content = content
        self.photo = photo
        self.drawing = drawing
        self.showsText = showsText
        self.dimsInDarkMode = dimsInDarkMode
    }

    private var paper: Paper { Paper.find(content.style.paper) }
    private var hasPhoto: Bool { photo != nil || content.photoPath != nil }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                paperFill
                PaperPatternView(pattern: paper.pattern, isDark: paper.isDark)
                photoLayer(side: side)
                if showsText {
                    textLayer(side: side)
                }
                if let drawing {
                    Image(decorative: drawing, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .accessibilityHidden(true)
                }
                ForEach(content.style.stickers) { placement in
                    StickerView(placement: placement, side: side)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.016, style: .continuous))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NoteCardView.spokenDescription(of: content)))
    }

    private var paperColor: Color {
        Color(hex: scheme == .dark && dimsInDarkMode ? paper.darkHex : paper.hex)
    }

    @ViewBuilder
    private var paperFill: some View {
        if let end = paper.gradientHex {
            LinearGradient(colors: [paperColor, Color(hex: end)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            paperColor
        }
    }

    @ViewBuilder
    private func photoLayer(side: CGFloat) -> some View {
        if hasPhoto {
            switch content.style.photoLayout {
            case .full:
                photoImage
                    .frame(width: side, height: side)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if showsText, !content.body.isEmpty {
                            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                                .frame(height: side * 0.5)
                        }
                    }
            case .framed:
                let inset = side * 0.07
                let frameSide = side * NoteCardMetrics.framedPhotoFraction
                VStack(spacing: 0) {
                    photoImage
                        .frame(width: side - inset * 2, height: frameSide)
                        .clipped()
                        .overlay(Rectangle().strokeBorder(.black.opacity(0.06), lineWidth: 1))
                        .padding(.top, inset)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var photoImage: some View {
        if let photo {
            Image(decorative: photo, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            // The file is still on its way: hold the space quietly.
            Rectangle().fill(.black.opacity(0.06))
        }
    }

    @ViewBuilder
    private func textLayer(side: CGFloat) -> some View {
        let layout = NoteCardMetrics.textLayout(for: content, hasPhoto: hasPhoto)
        let text = Text(content.body)
            .font(NoteFont.font(content.style.typeface, size: side * layout.fontFraction))
            .foregroundStyle(layout.onPhoto ? Color.white : Color(hex: Ink.find(content.style.ink).hex))
            .multilineTextAlignment(.center)
            .lineSpacing(side * 0.008)
            .minimumScaleFactor(0.45)
            .padding(.horizontal, side * 0.09)

        switch layout.region {
        case .whole:
            text.frame(width: side, height: side * 0.84)
        case .belowFrame:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                text.frame(width: side, height: side * (1 - NoteCardMetrics.framedPhotoFraction - 0.1))
            }
            .padding(.bottom, side * 0.015)
        case .overPhoto:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                text
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .frame(width: side, height: side * 0.34)
            }
            .padding(.bottom, side * 0.03)
        }
    }

    /// What VoiceOver says for a note: the words, then what else is on it.
    public static func spokenDescription(of content: NoteContent) -> String {
        var parts: [String] = []
        let body = content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { parts.append(body) }
        if content.photoPath != nil { parts.append(String(localized: "Includes a photo")) }
        if content.drawingPath != nil { parts.append(String(localized: "Includes a drawing")) }
        return parts.isEmpty ? String(localized: "Empty note") : parts.joined(separator: ". ")
    }
}

/// The proportions of a note card, shared with the composer so that the text
/// someone types sits exactly where it will be rendered.
public enum NoteCardMetrics {
    public static let framedPhotoFraction = 0.62

    public enum TextRegion: Equatable, Sendable {
        case whole, belowFrame, overPhoto
    }

    public struct TextLayout: Equatable, Sendable {
        public let region: TextRegion
        public let fontFraction: Double
        public let onPhoto: Bool
    }

    public static func textLayout(for content: NoteContent, hasPhoto: Bool) -> TextLayout {
        let length = content.body.count
        guard hasPhoto else {
            return TextLayout(region: .whole, fontFraction: wholeCardFraction(length: length), onPhoto: false)
        }
        switch content.style.photoLayout {
        case .framed:
            return TextLayout(region: .belowFrame, fontFraction: length <= 40 ? 0.066 : length <= 90 ? 0.05 : 0.04, onPhoto: false)
        case .full:
            return TextLayout(region: .overPhoto, fontFraction: length <= 40 ? 0.07 : length <= 100 ? 0.054 : 0.044, onPhoto: true)
        }
    }

    /// Short notes are written large; longer ones settle to a reading size.
    public static func wholeCardFraction(length: Int) -> Double {
        switch length {
        case ...18: 0.118
        case ...45: 0.096
        case ...90: 0.078
        case ...150: 0.064
        case ...220: 0.055
        default: 0.049
        }
    }
}

struct StickerView: View {
    let placement: StickerPlacement
    let side: CGFloat

    var body: some View {
        if let sticker = Sticker.find(placement.sticker) {
            StickerGlyph(sticker: sticker, size: side * 0.13 * placement.scale)
                .rotationEffect(.degrees(placement.rotation))
                .position(x: side * placement.x, y: side * placement.y)
                .accessibilityHidden(true)
        }
    }
}

/// One sticker at a given size: the same drawing on a note, in the picker and
/// in a widget.
public struct StickerGlyph: View {
    private let sticker: Sticker
    private let size: CGFloat

    public init(sticker: Sticker, size: CGFloat) {
        self.sticker = sticker
        self.size = size
    }

    public var body: some View {
        if let emoji = sticker.emoji {
            // A die-cut sticker: the picture on a white border that follows
            // its outline, lifted slightly off the paper. The border is the
            // picture itself, whitened and nudged in eight directions.
            let border = size * 0.075
            ZStack {
                ForEach(0..<8, id: \.self) { step in
                    let angle = Double(step) * .pi / 4
                    Text(emoji)
                        .brightness(1)
                        .offset(x: cos(angle) * border, y: sin(angle) * border)
                }
                Text(emoji)
            }
            .font(.system(size: size * 1.05))
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.03)
        } else {
            Image(systemName: sticker.symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Color(hex: sticker.hex))
        }
    }
}

/// Ruled, squared or dotted paper, drawn in proportion to the sheet.
public struct PaperPatternView: View {
    private let pattern: Paper.Pattern
    private let isDark: Bool

    public init(pattern: Paper.Pattern, isDark: Bool = false) {
        self.pattern = pattern
        self.isDark = isDark
    }

    public var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let line = (isDark ? Color.white : Color(hex: "#302238")).opacity(isDark ? 0.14 : 0.11)
            let step = side / 9
            switch pattern {
            case .plain:
                break
            case .lined:
                var y = step * 1.6
                while y < size.height - step * 0.5 {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(line), lineWidth: max(0.5, side / 500))
                    y += step
                }
            case .grid:
                let cell = side / 14
                var position = cell
                while position < side {
                    var path = Path()
                    path.move(to: CGPoint(x: position, y: 0))
                    path.addLine(to: CGPoint(x: position, y: size.height))
                    path.move(to: CGPoint(x: 0, y: position))
                    path.addLine(to: CGPoint(x: size.width, y: position))
                    context.stroke(path, with: .color(line.opacity(0.7)), lineWidth: max(0.5, side / 600))
                    position += cell
                }
            case .hearts, .stars:
                // Scattered rather than gridded, but from a fixed sequence so
                // the same sheet always looks the same.
                let symbol = context.resolveSymbol(id: pattern.rawValue)
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat((seed >> 33) % 10_000) / 10_000
                }
                let columns = 5
                let cell = side / CGFloat(columns)
                for row in 0..<columns {
                    for column in 0..<columns {
                        let x = (CGFloat(column) + 0.2 + next() * 0.6) * cell
                        let y = (CGFloat(row) + 0.2 + next() * 0.6) * cell
                        let scale = 0.55 + next() * 0.6
                        guard let symbol else { continue }
                        var layer = context
                        layer.opacity = isDark ? 0.5 : 0.36
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .degrees(Double(next() * 40 - 20)))
                        layer.scaleBy(x: scale * side / 400, y: scale * side / 400)
                        layer.draw(symbol, at: .zero)
                    }
                }
            case .stripes:
                let band = side / 12
                var x = -side
                while x < side * 2 {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + band, y: 0))
                    path.addLine(to: CGPoint(x: x + band - side * 0.5, y: side))
                    path.addLine(to: CGPoint(x: x - side * 0.5, y: side))
                    path.closeSubpath()
                    context.fill(path, with: .color(Color(hex: "#E8B4A0").opacity(0.28)))
                    x += band * 2
                }
            case .dotted:
                let cell = side / 14
                let radius = max(0.6, side / 320)
                var y = cell
                while y < side {
                    var x = cell
                    while x < side {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(line.opacity(1.6))
                        )
                        x += cell
                    }
                    y += cell
                }
            }
        } symbols: {
            Image(systemName: "heart.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color(hex: "#E58FA0"))
                .tag(Paper.Pattern.hearts.rawValue)
            Image(systemName: "sparkle")
                .font(.system(size: 18))
                .foregroundStyle(Color(hex: "#F4E3B0"))
                .tag(Paper.Pattern.stars.rawValue)
        }
        .accessibilityHidden(true)
    }
}

/// A note lying on the page: slightly turned, casting the only real shadow in
/// the interface.
public struct PaperNote<Content: View>: View {
    @Environment(\.palette) private var palette
    private let tilt: Double
    private let lifted: Bool
    private let content: Content

    public init(tilt: Double = -1.4, lifted: Bool = true, @ViewBuilder content: () -> Content) {
        self.tilt = tilt
        self.lifted = lifted
        self.content = content()
    }

    public var body: some View {
        content
            .paperShadow(palette, lifted: lifted)
            .rotationEffect(.degrees(tilt))
    }
}
