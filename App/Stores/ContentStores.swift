import CoupleDomain
import Foundation
import Observation

// MARK: - Memories

@MainActor
@Observable
final class MemoriesStore {
    private(set) var memories: [Memory] = []
    private(set) var totalCount = 0
    private(set) var loadState: LoadState = .idle
    private(set) var isLoadingMore = false
    private(set) var hasMore = false

    private let backend: Backend
    private var coupleID: UUID?
    private static let pageSize = 24

    init(backend: Backend) {
        self.backend = backend
    }

    func load(coupleID: UUID) async {
        if self.coupleID != coupleID { reset() }
        self.coupleID = coupleID
        if memories.isEmpty { loadState = .loading }
        do {
            async let page = backend.memories.memories(coupleID: coupleID, after: nil, limit: Self.pageSize)
            async let count = backend.memories.count(coupleID: coupleID)
            let (loaded, total) = try await (page, count)
            guard self.coupleID == coupleID else { return }
            memories = loaded
            totalCount = total
            hasMore = loaded.count == Self.pageSize
            loadState = .loaded
        } catch {
            Diagnostics.failure(Diagnostics.sync, "memories.load", error)
            if memories.isEmpty { loadState = .failed(appError(from: error)) }
        }
    }

    func loadMoreIfNeeded(after memory: Memory) async {
        guard let coupleID, hasMore, !isLoadingMore, memory.id == memories.last?.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await backend.memories.memories(coupleID: coupleID, after: MemoryCursor(after: memory), limit: Self.pageSize)
            let known = Set(memories.map(\.id))
            memories += page.filter { !known.contains($0.id) }
            hasMore = page.count == Self.pageSize
        } catch {
            Diagnostics.failure(Diagnostics.sync, "memories.loadMore", error)
        }
    }

    func isSaved(noteID: UUID) -> Bool {
        memories.contains { $0.sourceNoteID == noteID }
    }

    func saveNote(_ note: Note, caption: String = "") async throws {
        do {
            _ = try await backend.memories.saveNote(noteID: note.id, caption: caption)
        } catch {
            throw appError(from: error)
        }
        await load(coupleID: note.coupleID)
    }

    func add(_ moment: NewMoment, photo: Data?, media: MediaStore) async throws {
        guard let coupleID else { throw AppError.noSpace }
        var moment = moment
        do {
            if let photo {
                let path = MediaPath.photo(coupleID: coupleID)
                try await backend.media.upload(photo, to: path, contentType: "image/jpeg")
                media.prime(photo, for: path)
                moment.photoPath = path
            }
            _ = try await backend.memories.add(moment, coupleID: coupleID)
        } catch {
            throw appError(from: error)
        }
        await load(coupleID: coupleID)
    }

    func update(_ memory: Memory, title: String, caption: String, occurredOn: DayDate) async throws {
        do {
            let updated = try await backend.memories.update(id: memory.id, title: title, caption: caption, occurredOn: occurredOn)
            if let index = memories.firstIndex(where: { $0.id == memory.id }) { memories[index] = updated }
            memories.sort { ($0.occurredOn, $0.id.uuidString) > ($1.occurredOn, $1.id.uuidString) }
        } catch {
            throw appError(from: error)
        }
    }

    func delete(_ memory: Memory) async throws {
        do {
            try await backend.memories.deleteMemory(id: memory.id)
        } catch {
            throw appError(from: error)
        }
        memories.removeAll { $0.id == memory.id }
        totalCount = max(0, totalCount - 1)
    }

    func reset() {
        coupleID = nil
        memories = []
        totalCount = 0
        hasMore = false
        loadState = .idle
    }
}

// MARK: - Important dates

@MainActor
@Observable
final class DatesStore {
    private(set) var dates: [ImportantDate] = []
    private(set) var loadState: LoadState = .idle

    private let backend: Backend
    private var coupleID: UUID?

    init(backend: Backend) {
        self.backend = backend
    }

    func upcoming(limit: Int? = nil, today: DayDate = DayDate(Date())) -> [DateRules.Upcoming] {
        DateRules.upcoming(dates, today: today, limit: limit)
    }

    /// One-off dates that have already happened.
    func past(today: DayDate = DayDate(Date())) -> [ImportantDate] {
        dates.filter { DateRules.nextOccurrence(of: $0.startsOn, recurrence: $0.recurrence, onOrAfter: today) == nil }
            .sorted { $0.startsOn > $1.startsOn }
    }

    func load(coupleID: UUID) async {
        if self.coupleID != coupleID { reset() }
        self.coupleID = coupleID
        if dates.isEmpty { loadState = .loading }
        do {
            dates = try await backend.dates.dates(coupleID: coupleID)
            loadState = .loaded
        } catch {
            Diagnostics.failure(Diagnostics.sync, "dates.load", error)
            if dates.isEmpty { loadState = .failed(appError(from: error)) }
        }
    }

    func save(_ date: ImportantDate, isNew: Bool) async throws {
        do {
            let stored = isNew ? try await backend.dates.add(date) : try await backend.dates.update(date)
            dates.removeAll { $0.id == stored.id }
            dates.append(stored)
        } catch {
            throw appError(from: error)
        }
    }

    func delete(_ date: ImportantDate) async throws {
        do {
            try await backend.dates.deleteDate(id: date.id)
        } catch {
            throw appError(from: error)
        }
        dates.removeAll { $0.id == date.id }
    }

    func reset() {
        coupleID = nil
        dates = []
        loadState = .idle
    }
}

// MARK: - Scheduled messages

@MainActor
@Observable
final class ScheduleStore {
    private(set) var messages: [ScheduledMessage] = []
    private(set) var loadState: LoadState = .idle

    private let backend: Backend
    private let media: MediaStore

    init(backend: Backend, media: MediaStore) {
        self.backend = backend
        self.media = media
    }

    var pending: [ScheduledMessage] {
        messages.filter { $0.status == .pending }.sorted { $0.deliverAt < $1.deliverAt }
    }

    var history: [ScheduledMessage] {
        messages.filter { $0.status != .pending }.sorted { $0.deliverAt > $1.deliverAt }
    }

    func load() async {
        if messages.isEmpty { loadState = .loading }
        do {
            messages = try await backend.schedule.scheduledMessages()
            loadState = .loaded
        } catch {
            Diagnostics.failure(Diagnostics.sync, "schedule.load", error)
            if messages.isEmpty { loadState = .failed(appError(from: error)) }
        }
    }

    /// Hands a note to the server to deliver later. Throws unless the server
    /// has durably accepted it; delivery then no longer depends on this phone.
    func schedule(_ outgoing: OutgoingNote, coupleID: UUID, deliverAt: Date, id: UUID = UUID()) async throws {
        try ScheduleRules.validate(deliverAt: deliverAt, now: Date())
        do {
            let content = try await uploadMedia(for: outgoing, coupleID: coupleID)
            try InputRules.validate(content)
            let stored = try await backend.schedule.schedule(
                id: id, coupleID: coupleID, content: content, deliverAt: deliverAt, timeZone: TimeZone.current.identifier
            )
            messages.removeAll { $0.id == stored.id }
            messages.append(stored)
        } catch {
            throw appError(from: error)
        }
    }

    func update(_ message: ScheduledMessage, with outgoing: OutgoingNote, deliverAt: Date) async throws {
        try ScheduleRules.validate(deliverAt: deliverAt, now: Date())
        do {
            let content = try await uploadMedia(for: outgoing, coupleID: message.coupleID)
            try InputRules.validate(content)
            let stored = try await backend.schedule.update(
                id: message.id, expectedVersion: message.version, content: content,
                deliverAt: deliverAt, timeZone: TimeZone.current.identifier
            )
            if let index = messages.firstIndex(where: { $0.id == stored.id }) { messages[index] = stored }
        } catch {
            let failure = appError(from: error)
            if failure == .versionConflict || failure == .scheduleNotEditable { await load() }
            throw failure
        }
    }

    func cancel(_ message: ScheduledMessage) async throws {
        do {
            try await backend.schedule.cancel(id: message.id)
        } catch {
            let failure = appError(from: error)
            // Most likely it was delivered a moment ago: show the truth.
            if failure == .scheduleNotEditable { await load() }
            throw failure
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index].status = .cancelled }
    }

    private func uploadMedia(for outgoing: OutgoingNote, coupleID: UUID) async throws -> NoteContent {
        var content = outgoing.content
        if let photo = outgoing.photo {
            let path = MediaPath.photo(coupleID: coupleID)
            try await backend.media.upload(photo, to: path, contentType: "image/jpeg")
            media.prime(photo, for: path)
            content.photoPath = path
        }
        if let drawing = outgoing.drawing {
            let path = MediaPath.drawing(coupleID: coupleID)
            try await backend.media.upload(drawing, to: path, contentType: "image/png")
            media.prime(drawing, for: path)
            content.drawingPath = path
        }
        return content
    }

    func reset() {
        messages = []
        loadState = .idle
    }
}
