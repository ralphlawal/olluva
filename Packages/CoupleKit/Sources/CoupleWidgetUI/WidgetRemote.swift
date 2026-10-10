import CoupleDomain
import Foundation

/// Where and how the widget fetches what it shows, written by the app into the
/// App Group container. The token is a narrow, revocable credential that can
/// read the widget's content and nothing else; it is not the app's session.
public struct WidgetRemoteConfig: Codable, Equatable, Sendable {
    public var endpoint: URL
    public var apiKey: String
    public var token: String

    public init(endpoint: URL, apiKey: String, token: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.token = token
    }
}

public extension WidgetSnapshotStore {
    static let remoteConfigFile = "remote.json"

    func loadRemoteConfig() -> WidgetRemoteConfig? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.remoteConfigFile)) else { return nil }
        return try? JSONDecoder().decode(WidgetRemoteConfig.self, from: data)
    }

    func saveRemoteConfig(_ config: WidgetRemoteConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.remoteConfigFile)
        try JSONEncoder().encode(config).write(to: url, options: .atomic)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path
        )
        #endif
    }
}

/// Fetches the current widget content straight from the server and writes it
/// to the App Group. Runs inside the widget extension and the notification
/// extension, so the widget stays current whether or not the app is running.
public enum WidgetRemoteRefresher {
    public enum Outcome: Equatable, Sendable {
        case updated
        case unchanged
        /// The app has not set the widget up yet (or the person signed out).
        case notConfigured
        /// The server no longer accepts the token: stop showing content.
        case revoked
        case failed
    }

    /// The server's answer. Mirrors `public.widget_snapshot` plus signed URLs.
    public struct Payload: Decodable, Sendable {
        public struct RemoteNote: Decodable, Sendable {
            public let id: UUID
            public let body: String
            public let style: NoteStyle
            public let photo_path: String?
            public let drawing_path: String?
            public let created_at: Date
            public let is_unseen: Bool
        }

        public let state: String
        public let partner_name: String?
        public let theme_id: String?
        public let accent_hex: String?
        public let note: RemoteNote?
        public let photo_url: URL?
        public let drawing_url: URL?
    }

    /// Combines the server's answer with what only this device knows (the
    /// chosen widget style and the Lock Screen privacy setting).
    public static func snapshot(from payload: Payload, keeping existing: WidgetSnapshot, now: Date = Date()) -> WidgetSnapshot {
        var snapshot = WidgetSnapshot(
            state: WidgetSnapshot.State(rawValue: payload.state) ?? .unpaired,
            partnerName: payload.partner_name ?? "",
            themeID: payload.theme_id ?? Theme.defaultID,
            accentHex: payload.accent_hex,
            style: existing.style,
            hidesContentOnLockScreen: existing.hidesContentOnLockScreen,
            updatedAt: now
        )
        if snapshot.state == .note, let note = payload.note {
            snapshot.note = .init(
                id: note.id,
                content: NoteContent(body: note.body, style: note.style, photoPath: note.photo_path, drawingPath: note.drawing_path),
                createdAt: note.created_at, isUnseen: note.is_unseen
            )
        } else if snapshot.state == .note {
            snapshot.state = .empty
        }
        return snapshot
    }

    public static func decode(_ data: Data) throws -> Payload {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: raw) ?? plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date"))
        }
        return try decoder.decode(Payload.self, from: data)
    }

    @discardableResult
    public static func refresh(store: WidgetSnapshotStore, timeout: TimeInterval = 10) async -> Outcome {
        guard let config = store.loadRemoteConfig() else { return .notConfigured }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue(config.token, forHTTPHeaderField: "x-widget-token")
        request.setValue(config.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 {
                // Signed out or unlinked elsewhere: nothing may stay on screen.
                store.clear()
                return .revoked
            }
            guard status == 200 else { return .failed }

            let payload = try decode(data)
            let existing = store.load()
            var snapshot = snapshot(from: payload, keeping: existing)

            var comparable = snapshot
            comparable.updatedAt = existing.updatedAt
            comparable.note?.photoFile = existing.note?.photoFile
            comparable.note?.drawingFile = existing.note?.drawingFile
            let imagesPresent = existing.note?.id == snapshot.note?.id
                && (snapshot.note?.content.photoPath == nil || existing.note?.photoFile != nil)
                && (snapshot.note?.content.drawingPath == nil || existing.note?.drawingFile != nil)
            if comparable == existing, imagesPresent { return .unchanged }

            // Same note as before: keep the image files already on disk.
            if imagesPresent {
                snapshot.note?.photoFile = existing.note?.photoFile
                snapshot.note?.drawingFile = existing.note?.drawingFile
                try store.save(snapshot)
                return .updated
            }
            async let photo = download(payload.photo_url, with: session)
            async let drawing = download(payload.drawing_url, with: session)
            try store.save(snapshot, photo: await photo, drawing: await drawing)
            return .updated
        } catch {
            return .failed
        }
    }

    private static func download(_ url: URL?, with session: URLSession) async -> Data? {
        guard let url, let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 6 * 1024 * 1024
        else { return nil }
        return data
    }
}
