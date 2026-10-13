import CoupleDomain
import Foundation
import Observation

/// Today's shared question, the history of finished ones, and what this
/// person has typed but not yet sent.
///
/// The store only ever holds what the server returned for this person. It
/// never has a partner's answer before a moment is revealed, so there is
/// nothing here for a view to show too early.
@MainActor
@Observable
final class TogetherStore {
    private let backend: Backend
    private let defaults: UserDefaults

    private(set) var loadState: LoadState = .idle
    private(set) var today: TogetherMoment?
    /// Loaded, and the answer was that this person has no partner.
    private(set) var isUnpaired = false
    /// A refresh failed while an earlier copy is still on screen.
    private(set) var isStale = false

    private(set) var history: [TogetherMoment] = []
    private(set) var historyState: LoadState = .idle
    private(set) var hasMoreHistory = false
    private(set) var isLoadingMoreHistory = false

    /// Moments opened from elsewhere (a memory, say) that are in neither list.
    private var others: [UUID: TogetherMoment] = [:]

    private(set) var isSubmitting = false
    private(set) var isRevealing = false
    private(set) var isSavingMemory = false
    var actionError: AppError?

    private static let pageSize = 20
    private static let draftPrefix = "together.draft."
    private static let playedKey = "together.revealsPlayed"

    init(backend: Backend, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
    }

    // MARK: Reading

    func moment(id: UUID) -> TogetherMoment? {
        if today?.id == id { return today }
        return history.first { $0.id == id } ?? others[id]
    }

    func load() async {
        if today == nil, !isUnpaired { loadState = .loading }
        do {
            let moment = try await backend.together.today()
            today = moment
            isUnpaired = moment == nil
            isStale = false
            loadState = .loaded
            if let moment { fold(moment) }
        } catch {
            Diagnostics.failure(Diagnostics.sync, "together.load", error)
            // Keep what is on screen; only a blank screen becomes an error screen.
            if today == nil, !isUnpaired {
                loadState = .failed(appError(from: error))
            } else {
                isStale = true
            }
        }
    }

    func loadHistory() async {
        if history.isEmpty { historyState = .loading }
        do {
            let page = try await backend.together.history(before: nil, limit: Self.pageSize)
            history = page
            hasMoreHistory = page.count == Self.pageSize
            historyState = .loaded
        } catch {
            Diagnostics.failure(Diagnostics.sync, "together.history", error)
            if history.isEmpty { historyState = .failed(appError(from: error)) }
        }
    }

    func loadMoreHistory() async {
        guard hasMoreHistory, !isLoadingMoreHistory, let oldest = history.last else { return }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }
        guard let page = try? await backend.together.history(before: oldest.day, limit: Self.pageSize) else { return }
        let known = Set(history.map(\.id))
        history.append(contentsOf: page.filter { !known.contains($0.id) })
        hasMoreHistory = page.count == Self.pageSize
    }

    /// Fetches one moment that is not on screen yet. Returns nil if it is gone.
    func loadMoment(id: UUID) async -> TogetherMoment? {
        guard let moment = try? await backend.together.moment(id: id) else { return moment(id: id) }
        if !fold(moment) { others[id] = moment }
        return moment
    }

    /// Something changed on the server (the partner answered, or opened it).
    func refresh() async {
        await load()
        if historyState == .loaded { await loadHistory() }
    }

    // MARK: Drafts

    /// What has been typed and not sent. Kept on this phone only, and never
    /// treated as an answer: nothing is submitted until the person says so.
    func draft(for id: UUID) -> String {
        defaults.string(forKey: Self.draftPrefix + id.uuidString) ?? ""
    }

    func setDraft(_ text: String, for id: UUID) {
        let key = Self.draftPrefix + id.uuidString
        if text.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(text, forKey: key) }
    }

    // MARK: Acting

    /// Sends the answer. On failure the text stays as a draft and can be sent again.
    func submit(momentID: UUID, answer: String) async -> Bool {
        guard !isSubmitting else { return false }
        guard TogetherRules.isValid(answer) else {
            actionError = .invalidAnswer(limit: TogetherRules.answerLimit)
            return false
        }
        isSubmitting = true
        actionError = nil
        defer { isSubmitting = false }
        do {
            let moment = try await backend.together.submit(momentID: momentID, answer: answer)
            setDraft("", for: momentID)
            if !fold(moment) { others[momentID] = moment }
            return true
        } catch {
            setDraft(answer, for: momentID)
            let failure = appError(from: error)
            actionError = failure
            // It was opened on the other phone a moment ago: show that instead.
            if failure == .momentAlreadyRevealed { _ = await loadMoment(id: momentID) }
            return false
        }
    }

    func reveal(momentID: UUID) async -> Bool {
        guard !isRevealing else { return false }
        isRevealing = true
        actionError = nil
        defer { isRevealing = false }
        do {
            let moment = try await backend.together.reveal(momentID: momentID)
            if !fold(moment) { others[momentID] = moment }
            return true
        } catch {
            actionError = appError(from: error)
            return false
        }
    }

    func setSaved(_ saved: Bool, momentID: UUID) async {
        guard !isSavingMemory else { return }
        isSavingMemory = true
        actionError = nil
        defer { isSavingMemory = false }
        do {
            if saved {
                _ = try await backend.together.saveToMemories(momentID: momentID)
            } else {
                try await backend.together.removeFromMemories(momentID: momentID)
            }
            _ = await loadMoment(id: momentID)
        } catch {
            actionError = appError(from: error)
        }
    }

    // MARK: The reveal, once per phone

    /// The opening animation is played once on each phone, whichever of the
    /// two people opened the moment.
    func hasPlayedReveal(_ id: UUID) -> Bool {
        (defaults.stringArray(forKey: Self.playedKey) ?? []).contains(id.uuidString)
    }

    func markRevealPlayed(_ id: UUID) {
        var played = defaults.stringArray(forKey: Self.playedKey) ?? []
        guard !played.contains(id.uuidString) else { return }
        played.append(id.uuidString)
        defaults.set(Array(played.suffix(400)), forKey: Self.playedKey)
    }

    // MARK: Housekeeping

    /// Puts a fresh copy wherever that moment is already shown.
    @discardableResult
    private func fold(_ moment: TogetherMoment) -> Bool {
        var found = false
        if today?.id == moment.id {
            today = moment
            found = true
        }
        if let index = history.firstIndex(where: { $0.id == moment.id }) {
            history[index] = moment
            found = true
        }
        if others[moment.id] != nil {
            others[moment.id] = moment
            found = true
        }
        return found
    }

    /// The space ended or the person signed out: nothing of it stays here.
    func reset() {
        loadState = .idle
        today = nil
        isUnpaired = false
        isStale = false
        history = []
        historyState = .idle
        hasMoreHistory = false
        others = [:]
        actionError = nil
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.draftPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Self.playedKey)
    }
}
