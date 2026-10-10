import CoupleDomain
import Foundation
import Observation

/// A finished composition, ready to send: the content plus the bytes of any
/// media that still has to be uploaded.
struct OutgoingNote {
    var content: NoteContent
    var photo: Data?
    var drawing: Data?
}

/// The shared notes: what has been received and sent, live changes, and the
/// queue of notes still on their way to the server.
@MainActor
@Observable
final class NotesStore {
    private(set) var feed = NoteFeed()
    private(set) var reactions: [UUID: [Reaction]] = [:]
    private(set) var loadState: LoadState = .idle
    private(set) var pending: [PendingSend] = []
    private(set) var hasMoreHistory = true
    private(set) var isLoadingMore = false

    /// Called after any change that could alter what the widget shows.
    var onChanged: (() -> Void)?

    private let backend: Backend
    private let media: MediaStore
    private let outbox: OutboxStorage
    private var coupleID: UUID?
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private static let pageSize = 30

    init(backend: Backend, media: MediaStore, outbox: OutboxStorage = OutboxStorage()) {
        self.backend = backend
        self.media = media
        self.outbox = outbox
    }

    // MARK: - Reading

    func latestReceived(by userID: UUID?) -> Note? {
        userID.flatMap { feed.latestReceived(by: $0) }
    }

    func latestSent(by userID: UUID?) -> Note? {
        userID.flatMap { feed.latestSent(by: $0) }
    }

    func note(id: UUID) -> Note? {
        feed.notes.first { $0.id == id && !$0.isDeleted }
    }

    func reaction(on noteID: UUID, by userID: UUID?) -> ReactionKind? {
        reactions[noteID]?.first { $0.userID == userID }?.kind
    }

    /// Loads the newest notes for a space. Safe to call again to resynchronise.
    func load(coupleID: UUID) async {
        if self.coupleID != coupleID {
            reset()
            self.coupleID = coupleID
            pending = outbox.load().filter { $0.coupleID == coupleID }
            resumePending()
        }
        if feed.notes.isEmpty { loadState = .loading }
        do {
            async let notes = backend.notes.recentNotes(coupleID: coupleID, before: nil, limit: Self.pageSize)
            async let reactions = backend.notes.reactions(coupleID: coupleID)
            let (loadedNotes, loadedReactions) = try await (notes, reactions)
            guard self.coupleID == coupleID else { return }
            // The server's answer is the truth for the span it covers. Anything
            // held locally inside that span that the server no longer returns
            // has been removed there (an account deleted, a space purged) and
            // must not linger here or on the widget.
            let returned = Set(loadedNotes.map(\.id))
            let isWholeHistory = loadedNotes.count < Self.pageSize
            let oldestReturned = loadedNotes.map(\.createdAt).min()
            for stale in feed.notes where !returned.contains(stale.id) {
                if isWholeHistory || oldestReturned.map({ stale.createdAt >= $0 }) == true {
                    feed.remove(id: stale.id)
                }
            }
            for note in loadedNotes { feed.apply(note) }
            hasMoreHistory = loadedNotes.count == Self.pageSize
            self.reactions = Dictionary(grouping: loadedReactions, by: \.noteID)
            loadState = .loaded
            onChanged?()
        } catch {
            Diagnostics.failure(Diagnostics.sync, "notes.load", error)
            // Keep showing what we have; only an empty screen becomes an error screen.
            if feed.notes.isEmpty { loadState = .failed(appError(from: error)) }
        }
    }

    func loadMore() async {
        guard let coupleID, hasMoreHistory, !isLoadingMore, let oldest = feed.oldest else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let older = try await backend.notes.recentNotes(coupleID: coupleID, before: oldest.createdAt, limit: Self.pageSize)
            for note in older { feed.apply(note) }
            hasMoreHistory = older.count == Self.pageSize
        } catch {
            Diagnostics.failure(Diagnostics.sync, "notes.loadMore", error)
        }
    }

    func apply(_ event: SpaceEvent) async {
        switch event {
        case .note(let note):
            feed.apply(note)
            onChanged?()
        case .reactionsChanged:
            await reloadReactions()
        case .resynchronise:
            if let coupleID { await load(coupleID: coupleID) }
        default:
            break
        }
    }

    private func reloadReactions() async {
        guard let coupleID, let loaded = try? await backend.notes.reactions(coupleID: coupleID) else { return }
        reactions = Dictionary(grouping: loaded, by: \.noteID)
    }

    func reset() {
        for task in retryTasks.values { task.cancel() }
        retryTasks = [:]
        coupleID = nil
        feed = NoteFeed()
        reactions = [:]
        pending = []
        loadState = .idle
        hasMoreHistory = true
    }

    /// Forgets everything, including unsent notes on disk: for sign-out,
    /// unlinking and account deletion.
    func purge() {
        reset()
        outbox.removeAll()
    }

    // MARK: - Sending

    /// Sends a note and returns only once the server has accepted it. The
    /// caller is told the truth: this throws if the note was not stored.
    ///
    /// The note is written to the outbox first, so if the app is closed
    /// mid-send it is picked up again on next launch. Its id never changes
    /// across attempts, which is what makes a retry safe.
    @discardableResult
    func send(_ outgoing: OutgoingNote, coupleID: UUID, id: UUID = UUID()) async throws -> Note {
        // The composer retrying the same note: continue it, do not queue a twin.
        if pending.contains(where: { $0.id == id }) {
            retryTasks[id]?.cancel()
            return try await attempt(id)
        }
        try InputRules.validate(NoteContent(
            body: outgoing.content.body, style: outgoing.content.style,
            photoPath: outgoing.photo == nil ? nil : "pending", drawingPath: outgoing.drawing == nil ? nil : "pending"
        ))
        var content = outgoing.content
        content.photoPath = outgoing.photo == nil ? nil : MediaPath.photo(coupleID: coupleID)
        content.drawingPath = outgoing.drawing == nil ? nil : MediaPath.drawing(coupleID: coupleID)

        var item = PendingSend(id: id, coupleID: coupleID, content: content, createdAt: Date())
        outbox.save(item, photo: outgoing.photo, drawing: outgoing.drawing)
        item.photoFile = outgoing.photo == nil ? nil : OutboxStorage.photoName
        item.drawingFile = outgoing.drawing == nil ? nil : OutboxStorage.drawingName
        pending.append(item)
        return try await attempt(item.id)
    }

    func retry(_ id: UUID) async throws {
        retryTasks[id]?.cancel()
        _ = try await attempt(id)
    }

    func discard(_ id: UUID) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        pending.removeAll { $0.id == id }
        outbox.remove(id)
    }

    private func setState(_ state: PendingSend.State, for id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].state = state
    }

    private func attempt(_ id: UUID) async throws -> Note {
        guard let item = pending.first(where: { $0.id == id }) else { throw AppError.noteNotFound }
        do {
            setState(.uploading, for: id)
            if let path = item.content.photoPath, let data = outbox.media(id, OutboxStorage.photoName) {
                try await backend.media.upload(data, to: path, contentType: "image/jpeg")
                media.prime(data, for: path)
            }
            if let path = item.content.drawingPath, let data = outbox.media(id, OutboxStorage.drawingName) {
                try await backend.media.upload(data, to: path, contentType: "image/png")
                media.prime(data, for: path)
            }
            setState(.sending, for: id)
            let note = try await backend.notes.send(id: item.id, coupleID: item.coupleID, content: item.content)

            pending.removeAll { $0.id == id }
            outbox.remove(id)
            retryTasks[id] = nil
            feed.apply(note)
            onChanged?()
            return note
        } catch {
            let failure = appError(from: error)
            Diagnostics.failure(Diagnostics.sync, "notes.send", failure)
            if let index = pending.firstIndex(where: { $0.id == id }) {
                pending[index].state = .failed
                pending[index].attempts += 1
                outbox.update(pending[index])
                if failure.isRetryable, pending[index].shouldRetryAutomatically {
                    scheduleRetry(pending[index])
                } else if !failure.isRetryable {
                    // The server will never accept this; do not leave it queued.
                    discard(id)
                }
            }
            throw failure
        }
    }

    private func scheduleRetry(_ item: PendingSend) {
        retryTasks[item.id]?.cancel()
        retryTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(item.retryDelay))
            guard !Task.isCancelled else { return }
            _ = try? await self?.attempt(item.id)
        }
    }

    private func resumePending() {
        for item in pending {
            setState(.waiting, for: item.id)
            scheduleRetry(PendingSend(
                id: item.id, coupleID: item.coupleID, content: item.content, attempts: 0, createdAt: item.createdAt
            ))
        }
    }

    /// Tries everything in the queue now: called when the app returns to the
    /// foreground or the network comes back.
    func retryAllPending() {
        for item in pending where item.state == .failed || item.state == .waiting {
            retryTasks[item.id]?.cancel()
            retryTasks[item.id] = Task { [weak self] in _ = try? await self?.attempt(item.id) }
        }
    }

    // MARK: - Changing

    /// Replaces a note's content. If the note changed elsewhere in the
    /// meantime the edit is refused and the latest version is loaded, so the
    /// person can see what they would have overwritten.
    func update(_ note: Note, with outgoing: OutgoingNote) async throws -> Note {
        var content = outgoing.content
        do {
            if let photo = outgoing.photo {
                let path = MediaPath.photo(coupleID: note.coupleID)
                try await backend.media.upload(photo, to: path, contentType: "image/jpeg")
                media.prime(photo, for: path)
                content.photoPath = path
            }
            if let drawing = outgoing.drawing {
                let path = MediaPath.drawing(coupleID: note.coupleID)
                try await backend.media.upload(drawing, to: path, contentType: "image/png")
                media.prime(drawing, for: path)
                content.drawingPath = path
            }
            try InputRules.validate(content)
            let updated = try await backend.notes.update(noteID: note.id, expectedVersion: note.version, content: content)
            feed.apply(updated)
            onChanged?()
            return updated
        } catch {
            let failure = appError(from: error)
            if failure == .versionConflict, let coupleID { await load(coupleID: coupleID) }
            throw failure
        }
    }

    func delete(_ note: Note) async throws {
        do {
            try await backend.notes.delete(noteID: note.id)
        } catch {
            throw appError(from: error)
        }
        var tombstone = note
        tombstone.deletedAt = Date()
        tombstone.version += 1
        feed.apply(tombstone)
        reactions[note.id] = nil
        onChanged?()
    }

    /// Marks a received note as read. Quiet: failing to acknowledge is not
    /// something to interrupt anyone about, and it is retried on next view.
    func markSeen(_ note: Note, by userID: UUID?) async {
        guard note.seenAt == nil, note.authorID != userID else { return }
        do {
            try await backend.notes.markSeen(noteID: note.id)
            var seen = note
            seen.seenAt = Date()
            feed.apply(seen)
            onChanged?()
        } catch {
            Diagnostics.failure(Diagnostics.sync, "notes.markSeen", error)
        }
    }

    /// Sets or clears a reaction. Shown immediately and rolled back if the
    /// server refuses, so a tap never feels laggy and never lies for long.
    func setReaction(_ kind: ReactionKind?, on note: Note, by userID: UUID) async throws {
        let previous = reactions[note.id]
        var updated = (previous ?? []).filter { $0.userID != userID }
        if let kind { updated.append(Reaction(noteID: note.id, userID: userID, kind: kind)) }
        reactions[note.id] = updated
        do {
            try await backend.notes.setReaction(noteID: note.id, kind: kind)
        } catch {
            reactions[note.id] = previous
            throw appError(from: error)
        }
    }
}

/// Unsent notes on disk: one folder per note holding its description and media.
struct OutboxStorage {
    static let photoName = "photo.jpg"
    static let drawingName = "drawing.png"
    private static let manifest = "send.json"

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Outbox", isDirectory: true)
    }

    private func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func save(_ item: PendingSend, photo: Data?, drawing: Data?) {
        let folder = folder(item.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let photo { write(photo, to: folder.appendingPathComponent(Self.photoName)) }
        if let drawing { write(drawing, to: folder.appendingPathComponent(Self.drawingName)) }
        update(item)
    }

    func update(_ item: PendingSend) {
        guard let data = try? JSONEncoder().encode(item) else { return }
        write(data, to: folder(item.id).appendingPathComponent(Self.manifest))
    }

    func media(_ id: UUID, _ name: String) -> Data? {
        try? Data(contentsOf: folder(id).appendingPathComponent(name))
    }

    func load() -> [PendingSend] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent(Self.manifest)) }
            .compactMap { try? JSONDecoder().decode(PendingSend.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
