import CoupleDesign
import CoupleDomain
import CoupleWidgetUI
import SwiftUI
import WidgetKit

// The widget extension is deliberately thin. It reads one snapshot that the
// app wrote into the shared App Group container and draws it. It has no
// network access to the backend and no session, so it cannot show anything
// the signed-in app was not already authorised to read.

struct NoteEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let images: WidgetImages
}

struct NoteTimelineProvider: TimelineProvider {
    private var store: WidgetSnapshotStore? {
        WidgetSnapshotStore(appGroupID: Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "")
    }

    /// Shown in the widget gallery and while a real entry loads. Never
    /// contains anything of the person's own.
    func placeholder(in context: Context) -> NoteEntry {
        NoteEntry(date: .now, snapshot: Self.gallerySample, images: WidgetImages())
    }

    func getSnapshot(in context: Context, completion: @escaping (NoteEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteEntry>) -> Void) {
        // The app reloads timelines whenever the note changes. This fallback
        // refresh only matters if the app has not run for a while; iOS treats
        // it as a hint and schedules the actual reload itself.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1800)
        completion(Timeline(entries: [currentEntry(for: context.family)], policy: .after(next)))
    }

    private func currentEntry(for family: WidgetFamily) -> NoteEntry {
        let snapshot = store?.load() ?? .signedOut
        // Lock Screen families draw no images; skip decoding them entirely.
        let needsImages = family == .systemSmall || family == .systemMedium
        let pixels = family == .systemSmall ? 500 : 700
        let images = needsImages ? WidgetImages(snapshot: snapshot, store: store, maxPixel: pixels) : WidgetImages()
        return NoteEntry(date: .now, snapshot: snapshot, images: images)
    }

    static let gallerySample = WidgetSnapshot(
        state: .note,
        partnerName: String(localized: "Your person"),
        note: .init(
            id: UUID(),
            content: NoteContent(
                body: String(localized: "Thinking of you"),
                style: NoteStyle(
                    paper: "blush", ink: "rose", typeface: .hand,
                    stickers: [StickerPlacement(sticker: "heart", x: 0.8, y: 0.82, scale: 0.9, rotation: -10)]
                )
            ),
            createdAt: .now, isUnseen: false
        )
    )
}

struct LatestNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LatestNote", provider: NoteTimelineProvider()) { entry in
            LatestNoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Latest note")
        .description("The newest note from your partner, right where you’ll see it.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct LatestNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NoteEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                MediumNoteWidgetView(snapshot: entry.snapshot, images: entry.images)
            default:
                SmallNoteWidgetView(snapshot: entry.snapshot, images: entry.images)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(entry.snapshot.deepLink)
    }
}

struct LockScreenNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LockScreenNote", provider: NoteTimelineProvider()) { entry in
            LockScreenNoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Note on your Lock Screen")
        .description("Know when a new note is waiting. What it says stays hidden unless you choose to show it.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct LockScreenNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NoteEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                LockScreenCircularView(snapshot: entry.snapshot)
            case .accessoryInline:
                Label(LockScreenText.inline(for: entry.snapshot), systemImage: "envelope")
            default:
                LockScreenRectangularView(snapshot: entry.snapshot)
            }
        }
        // Even with previews on, the system redacts this while the device is
        // locked if the person has asked iOS to hide sensitive content.
        .privacySensitive()
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(entry.snapshot.deepLink)
    }
}
