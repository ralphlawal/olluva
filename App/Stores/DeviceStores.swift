import CoupleDomain
import CoupleWidgetUI
import Foundation
import Observation
import SwiftUI
import WidgetKit

// MARK: - Local settings

/// Preferences that belong to this device rather than to the account.
@MainActor
@Observable
final class LocalSettings {
    enum Appearance: String, CaseIterable {
        case system, light, dark

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    private let defaults: UserDefaults

    var widgetStyle: WidgetStyle {
        didSet { defaults.set(widgetStyle.rawValue, forKey: LocalPreferenceKey.widgetStyle) }
    }

    /// Lock Screen widgets hide what a note says unless this is turned off.
    var hidesContentOnLockScreen: Bool {
        didSet { defaults.set(hidesContentOnLockScreen, forKey: LocalPreferenceKey.hideOnLockScreen) }
    }

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: LocalPreferenceKey.appearance) }
    }

    var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: LocalPreferenceKey.hasSeenWelcome) }
    }

    var notificationPrimingShown: Bool {
        didSet { defaults.set(notificationPrimingShown, forKey: LocalPreferenceKey.notificationPrimingShown) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        widgetStyle = defaults.string(forKey: LocalPreferenceKey.widgetStyle).flatMap(WidgetStyle.init) ?? .note
        hidesContentOnLockScreen = defaults.object(forKey: LocalPreferenceKey.hideOnLockScreen) as? Bool ?? true
        appearance = defaults.string(forKey: LocalPreferenceKey.appearance).flatMap(Appearance.init) ?? .system
        hasSeenWelcome = defaults.bool(forKey: LocalPreferenceKey.hasSeenWelcome)
        notificationPrimingShown = defaults.bool(forKey: LocalPreferenceKey.notificationPrimingShown)
    }

    /// Clears what is tied to an account; keeps device-level choices.
    func resetForSignOut() {
        notificationPrimingShown = false
    }
}

// MARK: - Navigation

/// Where the app should be, driven by taps, widgets, links and notifications.
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable {
        case today, memories, us
    }

    var tab: Tab = .today
    var presentedNoteID: UUID?
    var isComposing = false
    var isShowingPaywall = false
    /// An invitation code that arrived through a link, waiting to be previewed.
    var pendingInviteCode: String?

    func open(_ link: DeepLink) {
        switch link {
        case .home:
            tab = .today
        case .pair:
            break
        case .compose:
            tab = .today
            isComposing = true
        case .note(let id):
            tab = .today
            presentedNoteID = id
        case .join(let code):
            pendingInviteCode = code
        }
    }

    func reset() {
        tab = .today
        presentedNoteID = nil
        isComposing = false
        isShowingPaywall = false
    }
}

// MARK: - Widget bridge

/// Publishes the latest authorised note to the widgets.
///
/// The app is the only writer. It writes a small snapshot into the App Group
/// container and asks WidgetKit to reload. iOS decides when a widget is
/// actually redrawn; this guarantees only that the next redraw is current.
@MainActor
final class WidgetBridge {
    private let store: WidgetSnapshotStore?
    private let media: MediaStore
    private let settings: LocalSettings
    private var lastWritten: WidgetSnapshot?
    private var writeTask: Task<Void, Never>?

    init(store: WidgetSnapshotStore?, media: MediaStore, settings: LocalSettings) {
        self.store = store
        self.media = media
        self.settings = settings
        if store == nil {
            Diagnostics.widget.notice("App Group container unavailable: widgets will show their placeholder")
        }
    }

    var isAvailable: Bool { store != nil }

    /// Builds what the widget should show for the current state.
    func snapshot(session: SessionStore, notes: NotesStore) -> WidgetSnapshot {
        let space = session.space.space
        var snapshot = WidgetSnapshot(
            state: .signedOut,
            partnerName: session.partner?.displayName ?? "",
            themeID: space?.themeID ?? Theme.defaultID,
            accentHex: space?.accentHex,
            style: settings.widgetStyle,
            hidesContentOnLockScreen: settings.hidesContentOnLockScreen
        )
        guard session.userID != nil else { return snapshot }
        guard session.partner != nil else {
            snapshot.state = .unpaired
            return snapshot
        }
        guard let note = notes.latestReceived(by: session.userID) else {
            snapshot.state = .empty
            return snapshot
        }
        snapshot.state = .note
        snapshot.note = .init(id: note.id, content: note.content, createdAt: note.createdAt, isUnseen: note.seenAt == nil)
        return snapshot
    }

    func publish(session: SessionStore, notes: NotesStore) {
        guard let store else { return }
        var snapshot = snapshot(session: session, notes: notes)
        // Skip the write (and the reload budget it spends) when nothing visible changed.
        var comparable = snapshot
        comparable.updatedAt = lastWritten?.updatedAt ?? comparable.updatedAt
        guard comparable != lastWritten else { return }
        lastWritten = snapshot

        writeTask?.cancel()
        writeTask = Task {
            let photo = await media.data(path: snapshot.note?.content.photoPath)
            let drawing = await media.data(path: snapshot.note?.content.drawingPath)
            guard !Task.isCancelled else { return }
            snapshot.updatedAt = Date()
            do {
                try store.save(snapshot, photo: photo, drawing: drawing)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                Diagnostics.failure(Diagnostics.widget, "publish", error)
            }
        }
    }

    /// Removes all note content from the shared container.
    func clear() {
        writeTask?.cancel()
        lastWritten = nil
        store?.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Drafts

/// The note being written, kept on disk so closing the composer, a phone call
/// or the app being evicted never loses it.
struct ComposerDraft: Codable, Equatable {
    var content = NoteContent()
    var hasPhoto = false
    var hasDrawing = false
    var savedAt = Date()
}

struct DraftStorage {
    private let directory: URL
    private static let manifest = "draft.json"
    static let photoName = "photo.jpg"
    static let photoSourceName = "photo-source.jpg"
    static let drawingName = "drawing.pkdrawing"

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Draft", isDirectory: true)
    }

    func load() -> ComposerDraft? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.manifest)) else { return nil }
        return try? JSONDecoder().decode(ComposerDraft.self, from: data)
    }

    func file(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    func save(_ draft: ComposerDraft, files: [String: Data?]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files {
            let url = directory.appendingPathComponent(name)
            if let data {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if let data = try? JSONEncoder().encode(draft) {
            try? data.write(
                to: directory.appendingPathComponent(Self.manifest),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
