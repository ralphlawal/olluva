import CoupleDesign
import CoupleDomain
import CoupleWidgetUI
import SwiftUI
import WidgetKit

// The widget draws one snapshot from the shared App Group container. The app
// writes that snapshot whenever it runs; the widget also refreshes it itself
// from the server, using a narrow read-only token the app obtained for it.
// It never holds the app's session and can read nothing but what it displays.

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
        // Each time iOS asks for a timeline, first fetch the current state from
        // the server with the widget's own narrow credential. This is what
        // makes the widget correct itself with no help from the app: a note
        // that was deleted disappears, a new one appears, even if the app has
        // not run. How often iOS asks is up to iOS (typically every 15 minutes
        // or so, less under Low Power Mode); a notification arriving triggers
        // it sooner via the notification extension.
        let family = context.family
        let store = store
        Task {
            if let store { await WidgetRemoteRefresher.refresh(store: store, timeout: 8) }
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
            completion(Timeline(entries: [currentEntry(for: family)], policy: .after(next)))
        }
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
