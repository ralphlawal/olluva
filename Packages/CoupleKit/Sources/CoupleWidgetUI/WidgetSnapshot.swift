import CoupleDomain
import CoreGraphics
import Foundation
import ImageIO

/// Everything a widget needs to draw, written by the app into the shared App
/// Group container. The widget never talks to the network and never holds a
/// session: it can only show what the signed-in app has already been
/// authorised to read and chosen to put here.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case signedOut, unpaired, empty, note
    }

    public struct NoteSnapshot: Codable, Equatable, Sendable {
        public var id: UUID
        public var content: NoteContent
        public var createdAt: Date
        public var isUnseen: Bool
        public var photoFile: String?
        public var drawingFile: String?

        public init(id: UUID, content: NoteContent, createdAt: Date, isUnseen: Bool, photoFile: String? = nil, drawingFile: String? = nil) {
            self.id = id
            self.content = content
            self.createdAt = createdAt
            self.isUnseen = isUnseen
            self.photoFile = photoFile
            self.drawingFile = drawingFile
        }
    }

    public var state: State
    public var partnerName: String
    public var themeID: String
    public var accentHex: String?
    public var style: WidgetStyle
    /// When true, Lock Screen widgets say that a note is waiting but not what it says.
    public var hidesContentOnLockScreen: Bool
    public var note: NoteSnapshot?
    public var updatedAt: Date

    public init(
        state: State, partnerName: String = "", themeID: String = Theme.defaultID, accentHex: String? = nil,
        style: WidgetStyle = .note, hidesContentOnLockScreen: Bool = true, note: NoteSnapshot? = nil, updatedAt: Date = Date()
    ) {
        self.state = state
        self.partnerName = partnerName
        self.themeID = themeID
        self.accentHex = accentHex
        self.style = style
        self.hidesContentOnLockScreen = hidesContentOnLockScreen
        self.note = note
        self.updatedAt = updatedAt
    }

    public static let signedOut = WidgetSnapshot(state: .signedOut)

    /// Where tapping the widget should take the person.
    public var deepLink: URL {
        switch state {
        case .signedOut: DeepLink.home.url
        case .unpaired: DeepLink.pair.url
        case .empty: DeepLink.compose.url
        case .note: note.map { DeepLink.note($0.id).url } ?? DeepLink.home.url
        }
    }
}

public enum DeepLink: Equatable, Sendable {
    case home
    case pair
    case compose
    case note(UUID)
    case join(code: String)

    public var url: URL {
        switch self {
        case .home: URL(string: "\(InviteCode.scheme)://home")!
        case .pair: URL(string: "\(InviteCode.scheme)://pair")!
        case .compose: URL(string: "\(InviteCode.scheme)://compose")!
        case .note(let id): URL(string: "\(InviteCode.scheme)://note/\(id.uuidString.lowercased())")!
        case .join(let code): InviteCode.link(for: code)
        }
    }

    public init?(url: URL) {
        guard url.scheme == InviteCode.scheme else { return nil }
        switch url.host {
        case "home": self = .home
        case "pair": self = .pair
        case "compose": self = .compose
        case "note":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            self = .note(id)
        case "join":
            guard let code = InviteCode.extract(from: url) else { return nil }
            self = .join(code: code)
        default:
            return nil
        }
    }
}

/// Reads and writes the snapshot and its image files.
public struct WidgetSnapshotStore: Sendable {
    public let directory: URL

    private static let snapshotFile = "snapshot.json"

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store in the shared App Group container, or `nil` when the App
    /// Group is not configured for this build.
    public init?(appGroupID: String) {
        guard !appGroupID.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return nil }
        self.init(directory: container.appendingPathComponent("Library/Application Support/Widget", isDirectory: true))
    }

    public func load() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.snapshotFile)),
              let snapshot = try? Self.decoder.decode(WidgetSnapshot.self, from: data)
        else { return .signedOut }
        return snapshot
    }

    /// Replaces the snapshot. Image data, when given, is stored beside it and
    /// any image belonging to an earlier snapshot is removed, so the container
    /// only ever holds the one note currently on display.
    public func save(_ snapshot: WidgetSnapshot, photo: Data? = nil, drawing: Data? = nil) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var stored = snapshot
        var keep: Set<String> = [Self.snapshotFile, Self.remoteConfigFile]
        if var note = stored.note {
            if let photo {
                let name = "\(note.id.uuidString.lowercased())-photo.jpg"
                try write(photo, to: name)
                note.photoFile = name
            }
            if let drawing {
                let name = "\(note.id.uuidString.lowercased())-drawing.png"
                try write(drawing, to: name)
                note.drawingFile = name
            }
            for name in [note.photoFile, note.drawingFile].compactMap({ $0 }) { keep.insert(name) }
            stored.note = note
        }
        try write(try Self.encoder.encode(stored), to: Self.snapshotFile)

        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(name) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Removes every trace of note content: used on sign-out, unlinking and
    /// account deletion.
    public func clear(to snapshot: WidgetSnapshot = .signedOut) {
        // Removes the remote credential too: after this, neither the widget
        // nor the notification extension can fetch anything.
        try? FileManager.default.removeItem(at: directory)
        try? save(snapshot)
    }

    /// Decodes an image at no more than `maxPixel` on its longest side.
    /// Widgets run under a tight memory limit; a full-size photo would kill them.
    public func image(named name: String?, maxPixel: Int = 900) -> CGImage? {
        guard let name else { return nil }
        return Self.downsampledImage(at: directory.appendingPathComponent(name), maxPixel: maxPixel)
    }

    public static func downsampledImage(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return downsample(source, maxPixel: maxPixel)
    }

    public static func downsampledImage(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return downsample(source, maxPixel: maxPixel)
    }

    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bakes the EXIF orientation in, so portrait photos stay upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func write(_ data: Data, to name: String) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        // Readable once the phone has been unlocked after a restart, so widgets
        // can draw on the Lock Screen, but encrypted at rest before that.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path
        )
        #endif
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
