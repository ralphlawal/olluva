import CoupleDesign
import CoupleDomain
import SwiftUI
import WidgetKit

// The widget faces. They are plain SwiftUI views with no WidgetKit dependency,
// so the app can show the very same views as previews in the composer and in
// personalisation: what a person sees there is what lands on the Home Screen.

public struct WidgetImages: Sendable {
    public var photo: CGImage?
    public var drawing: CGImage?

    public init(photo: CGImage? = nil, drawing: CGImage? = nil) {
        self.photo = photo
        self.drawing = drawing
    }

    public init(snapshot: WidgetSnapshot, store: WidgetSnapshotStore?, maxPixel: Int = 900) {
        photo = store?.image(named: snapshot.note?.photoFile, maxPixel: maxPixel)
        drawing = store?.image(named: snapshot.note?.drawingFile, maxPixel: maxPixel)
    }
}

/// Text for the states in which there is no note to show.
struct WidgetPlaceholderCopy {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String

    init?(state: WidgetSnapshot.State) {
        switch state {
        case .signedOut:
            title = "Notes from your person"
            detail = "Open the app to begin"
            symbol = "square.and.pencil"
        case .unpaired:
            title = "Waiting for your person"
            detail = "Send them your invitation"
            symbol = "person.2"
        case .empty:
            title = "A blank page"
            detail = "Write the first note"
            symbol = "pencil.line"
        case .note:
            return nil
        }
    }
}

// MARK: - Home Screen: small

public struct SmallNoteWidgetView: View {
    @Environment(\.colorScheme) private var scheme
    private let snapshot: WidgetSnapshot
    private let images: WidgetImages

    public init(snapshot: WidgetSnapshot, images: WidgetImages = WidgetImages()) {
        self.snapshot = snapshot
        self.images = images
    }

    private var palette: Palette {
        Palette(theme: Theme.find(snapshot.themeID), accentHex: snapshot.accentHex, scheme: scheme)
    }

    public var body: some View {
        Group {
            if let note = snapshot.note, snapshot.state == .note {
                noteFace(note)
            } else if let copy = WidgetPlaceholderCopy(state: snapshot.state) {
                WidgetPlaceholderView(copy: copy, palette: palette, compact: true)
            }
        }
        .environment(\.palette, palette)
    }

    @ViewBuilder
    private func noteFace(_ note: WidgetSnapshot.NoteSnapshot) -> some View {
        switch snapshot.style {
        case .note:
            NoteCardView(content: note.content, photo: images.photo, drawing: images.drawing)
                .overlay(alignment: .topTrailing) { unseenMark(note) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: scheme == .dark ? Paper.find(note.content.style.paper).darkHex : Paper.find(note.content.style.paper).hex))
        case .print:
            ZStack {
                palette.canvas
                NoteCardView(content: note.content, photo: images.photo, drawing: images.drawing)
                    .padding(14)
                    .paperShadow(palette, lifted: false)
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 4)
                    .rotationEffect(.degrees(-3))
            }
        case .minimal, .bold:
            WidgetTextFace(note: note, partnerName: snapshot.partnerName, palette: palette, bold: snapshot.style == .bold, compact: true)
        }
    }

    @ViewBuilder
    private func unseenMark(_ note: WidgetSnapshot.NoteSnapshot) -> some View {
        if note.isUnseen {
            Circle()
                .fill(palette.highlight)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .padding(12)
                .accessibilityLabel(Text("New"))
        }
    }
}

// MARK: - Home Screen: medium

public struct MediumNoteWidgetView: View {
    @Environment(\.colorScheme) private var scheme
    private let snapshot: WidgetSnapshot
    private let images: WidgetImages

    public init(snapshot: WidgetSnapshot, images: WidgetImages = WidgetImages()) {
        self.snapshot = snapshot
        self.images = images
    }

    private var palette: Palette {
        Palette(theme: Theme.find(snapshot.themeID), accentHex: snapshot.accentHex, scheme: scheme)
    }

    public var body: some View {
        Group {
            if let note = snapshot.note, snapshot.state == .note {
                face(note)
            } else if let copy = WidgetPlaceholderCopy(state: snapshot.state) {
                WidgetPlaceholderView(copy: copy, palette: palette, compact: false)
            }
        }
        .environment(\.palette, palette)
    }

    @ViewBuilder
    private func face(_ note: WidgetSnapshot.NoteSnapshot) -> some View {
        let bold = snapshot.style == .bold
        ZStack {
            (bold ? palette.accent : palette.canvas)
            HStack(spacing: 16) {
                NoteCardView(content: note.content, photo: images.photo, drawing: images.drawing)
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 4)
                    .rotationEffect(.degrees(snapshot.style == .minimal ? 0 : -2.5))
                    .padding(.vertical, 14)

                VStack(alignment: .leading, spacing: 4) {
                    if note.isUnseen {
                        Text("New")
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(bold ? palette.onAccent : palette.highlight)
                    }
                    Text(snapshot.partnerName.isEmpty ? String(localized: "Your person") : snapshot.partnerName)
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(bold ? palette.onAccent : palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(note.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(bold ? palette.onAccent.opacity(0.8) : palette.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(bold ? palette.onAccent : palette.accent)
                }
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
        }
    }
}

// MARK: - Home Screen: large

/// The note at close to full size, with who sent it above and a way to answer
/// below. The card stays square, as it is everywhere else in the app.
public struct LargeNoteWidgetView: View {
    @Environment(\.colorScheme) private var scheme
    private let snapshot: WidgetSnapshot
    private let images: WidgetImages

    public init(snapshot: WidgetSnapshot, images: WidgetImages = WidgetImages()) {
        self.snapshot = snapshot
        self.images = images
    }

    private var palette: Palette {
        Palette(theme: Theme.find(snapshot.themeID), accentHex: snapshot.accentHex, scheme: scheme)
    }

    public var body: some View {
        Group {
            if let note = snapshot.note, snapshot.state == .note {
                face(note)
            } else if let copy = WidgetPlaceholderCopy(state: snapshot.state) {
                WidgetPlaceholderView(copy: copy, palette: palette, compact: false)
            }
        }
        .environment(\.palette, palette)
    }

    private func face(_ note: WidgetSnapshot.NoteSnapshot) -> some View {
        let bold = snapshot.style == .bold
        return ZStack {
            (bold ? palette.accent : palette.canvas)
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.partnerName.isEmpty ? String(localized: "Your person") : snapshot.partnerName)
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(bold ? palette.onAccent : palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if note.isUnseen {
                        Text("New")
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(bold ? palette.onAccent : palette.highlight)
                    }
                    Spacer(minLength: 0)
                    Text(note.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(bold ? palette.onAccent.opacity(0.8) : palette.inkSecondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }

                NoteCardView(content: note.content, photo: images.photo, drawing: images.drawing)
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 5)
                    .rotationEffect(.degrees(snapshot.style == .minimal ? 0 : -1.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Spacer(minLength: 0)
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(bold ? palette.onAccent : palette.accent)
                }
            }
            .padding(18)
        }
    }
}

// MARK: - Shared faces

struct WidgetTextFace: View {
    let note: WidgetSnapshot.NoteSnapshot
    let partnerName: String
    let palette: Palette
    let bold: Bool
    let compact: Bool

    var body: some View {
        let body = note.content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        ZStack {
            bold ? palette.accent : palette.canvas
            VStack(alignment: .leading, spacing: 6) {
                Text(body.isEmpty ? fallback : body)
                    .font(NoteFont.font(note.content.style.typeface, size: body.count <= 40 ? 22 : 17))
                    .foregroundStyle(bold ? palette.onAccent : palette.ink)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(spacing: 5) {
                    if note.isUnseen {
                        Circle().fill(bold ? palette.onAccent : palette.highlight).frame(width: 6, height: 6)
                    }
                    Text(partnerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(bold ? palette.onAccent.opacity(0.85) : palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            .padding(compact ? 14 : 18)
        }
    }

    private var fallback: String {
        note.content.photoPath != nil ? String(localized: "Sent you a photo") : String(localized: "Drew you something")
    }
}

struct WidgetPlaceholderView: View {
    let copy: WidgetPlaceholderCopy
    let palette: Palette
    let compact: Bool

    var body: some View {
        ZStack {
            palette.canvas
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: copy.symbol)
                    .font(.system(size: compact ? 20 : 24, weight: .light))
                    .foregroundStyle(palette.inkTertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(copy.title)
                    .font(.system(compact ? .subheadline : .title3, design: .serif).weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .minimumScaleFactor(0.8)
                Text(copy.detail)
                    .font(.caption)
                    .foregroundStyle(palette.inkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(compact ? 14 : 18)
        }
    }
}

// MARK: - Lock Screen

/// What a Lock Screen widget may reveal. The Lock Screen is readable by anyone
/// who picks the phone up, so content is hidden unless the person opts in.
public enum LockScreenText {
    public static func headline(for snapshot: WidgetSnapshot) -> String {
        switch snapshot.state {
        case .signedOut: return String(localized: "Open to begin")
        case .unpaired: return String(localized: "Waiting for your person")
        case .empty: return String(localized: "No notes yet")
        case .note:
            let name = snapshot.partnerName.isEmpty ? String(localized: "Your person") : snapshot.partnerName
            return snapshot.note?.isUnseen == true
                ? String(localized: "New note from \(name)")
                : String(localized: "From \(name)")
        }
    }

    /// The note's words, or `nil` when they must not be shown.
    public static func body(for snapshot: WidgetSnapshot) -> String? {
        guard snapshot.state == .note, !snapshot.hidesContentOnLockScreen, let note = snapshot.note else { return nil }
        let text = note.content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return note.content.photoPath != nil ? String(localized: "Sent you a photo") : String(localized: "Drew you something")
    }

    public static func inline(for snapshot: WidgetSnapshot) -> String {
        if let body = body(for: snapshot), !snapshot.partnerName.isEmpty {
            return "\(snapshot.partnerName): \(body)"
        }
        return headline(for: snapshot)
    }
}

public struct LockScreenRectangularView: View {
    private let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label {
                Text(LockScreenText.headline(for: snapshot)).lineLimit(1)
            } icon: {
                Image(systemName: snapshot.note?.isUnseen == true ? "envelope.badge" : "envelope.open")
            }
            .font(.headline)
            .widgetAccentable()
            if let body = LockScreenText.body(for: snapshot) {
                Text(body).font(.subheadline).lineLimit(2)
            } else if snapshot.state == .note {
                Text("Open to read").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct LockScreenCircularView: View {
    private let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        let unseen = snapshot.note?.isUnseen == true
        ZStack {
            Image(systemName: unseen ? "envelope.badge.fill" : "envelope.open.fill")
                .font(.system(size: 22))
                .widgetAccentable()
        }
        .accessibilityLabel(Text(LockScreenText.headline(for: snapshot)))
    }
}
