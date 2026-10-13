import CoupleDomain
import Foundation

/// An in-memory stand-in for the server, shared by any number of signed-in
/// `LocalBackend` sessions. It applies the same product rules as the database
/// (single couple per person, two members per couple, version checks, limits,
/// privacy of scheduled messages) so tests and the DEBUG demo mode exercise
/// real behaviour.
///
/// It is not a production backend: nothing is persisted and nothing leaves the
/// process.
public final class LocalWorld: @unchecked Sendable {
    struct Account {
        var id: UUID
        /// The Apple ID that backs this identity up, if any.
        var appleSubject: String?
    }

    struct Couple {
        var space: CoupleSpace
        var members: [UUID]
        var ended = false
    }

    /// One day's question for a couple, with who has said what.
    struct Together {
        var id: UUID
        var coupleID: UUID
        var day: DayDate
        var questionIndex: Int
        var answers: [UUID: String] = [:]
        var revealedAt: Date?
    }

    struct Invitation {
        enum Status { case pending, accepted, declined, revoked }
        var id: UUID
        var coupleID: UUID
        var createdBy: UUID
        var code: String
        var status: Status
        var expiresAt: Date
        var createdAt: Date
    }

    struct Scheduled {
        var message: ScheduledMessage
        var authorID: UUID
    }

    struct State {
        var accounts: [UUID: Account] = [:]
        var profiles: [UUID: Profile] = [:]
        var couples: [UUID: Couple] = [:]
        var invitations: [Invitation] = []
        var failedAttempts: [UUID: [Date]] = [:]
        var blocks: Set<[UUID]> = []
        var notes: [Note] = []
        var reactions: [Reaction] = []
        var memories: [Memory] = []
        var together: [Together] = []
        var dates: [ImportantDate] = []
        var scheduled: [Scheduled] = []
        var preferences: [UUID: NotificationPreferences] = [:]
        var deviceTokens: [String: UUID] = [:]
        var premiumUsers: Set<UUID> = []
        var media: [String: Data] = [:]
        var pendingEvents: [(UUID, SpaceEvent)] = []
    }

    private let lock = NSLock()
    private var state = State()
    private var listeners: [UUID: [UUID: AsyncStream<SpaceEvent>.Continuation]] = [:]
    private var _now: @Sendable () -> Date
    private var _failure: AppError?
    private var _sendFailure: AppError?

    /// Artificial delay applied to every call, so loading states are visible
    /// in demo mode. Zero in tests.
    public let latency: Duration

    public init(
        latency: Duration = .zero, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.latency = latency
        _now = now
    }

    public var now: Date {
        lock.withLock { _now() }
    }

    public func setClock(_ clock: @escaping @Sendable () -> Date) {
        lock.withLock { _now = clock }
    }

    /// While set, every backend call fails with this error (e.g. `.offline`).
    public func setFailure(_ error: AppError?) {
        lock.withLock { _failure = error }
    }

    /// While set, only sending and uploading fail: reading still works. Models
    /// a connection that drops at the moment someone presses Send.
    public func setSendFailure(_ error: AppError?) {
        lock.withLock { _sendFailure = error }
    }

    var sendFailure: AppError? {
        lock.withLock { _sendFailure }
    }

    // MARK: - State access

    func read<T>(_ body: (State, Date) throws -> T) throws -> T {
        try lock.withLock {
            if let failure = _failure { throw failure }
            return try body(state, _now())
        }
    }

    func mutate<T>(_ body: (inout State, Date) throws -> T) throws -> T {
        let (result, events): (T, [(UUID, SpaceEvent)]) = try lock.withLock {
            if let failure = _failure { throw failure }
            var draft = state
            let result = try body(&draft, _now())
            let events = draft.pendingEvents
            draft.pendingEvents = []
            state = draft
            return (result, events)
        }
        for (coupleID, event) in events { publish(event, to: coupleID) }
        return result
    }

    /// Bypasses the failure switch: for arranging state in tests and demos.
    func arrange<T>(_ body: (inout State, Date) throws -> T) rethrows -> T {
        let (result, events): (T, [(UUID, SpaceEvent)]) = try lock.withLock {
            let result = try body(&state, _now())
            let events = state.pendingEvents
            state.pendingEvents = []
            return (result, events)
        }
        for (coupleID, event) in events { publish(event, to: coupleID) }
        return result
    }

    // MARK: - Events

    func events(coupleID: UUID) -> AsyncStream<SpaceEvent> {
        AsyncStream { continuation in
            let token = UUID()
            lock.withLock { listeners[coupleID, default: [:]][token] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.listeners[coupleID]?[token] = nil }
            }
        }
    }

    private func publish(_ event: SpaceEvent, to coupleID: UUID) {
        let targets = lock.withLock { listeners[coupleID].map { Array($0.values) } ?? [] }
        for target in targets { target.yield(event) }
    }

    // MARK: - Arranging state (tests, previews, demo mode)

    /// Creates an identity and returns its id. Pass `appleID` for one that
    /// has been backed up.
    @discardableResult
    public func addAccount(name: String, appleID: String? = nil) -> UUID {
        arrange { state, _ in
            let id = UUID()
            state.accounts[id] = Account(id: id, appleSubject: appleID)
            state.profiles[id] = Profile(id: id, displayName: name)
            state.preferences[id] = NotificationPreferences()
            return id
        }
    }

    /// Pairs two existing accounts directly.
    @discardableResult
    public func pair(_ first: UUID, _ second: UUID, pairedAt: Date? = nil) -> UUID {
        arrange { state, now in
            let id = UUID()
            let when = pairedAt ?? now
            state.couples[id] = Couple(space: CoupleSpace(id: id, pairedAt: when, createdAt: when), members: [first, second])
            return id
        }
    }

    /// Puts `owner` alone in a new space with a pending invitation of a known
    /// code, so a demo or test has something to join.
    public func addWaitingSpace(owner: UUID, invitationCode: String) {
        arrange { state, now in
            let id = UUID()
            state.couples[id] = Couple(space: CoupleSpace(id: id, createdAt: now), members: [owner])
            state.invitations.append(Invitation(
                id: UUID(), coupleID: id, createdBy: owner, code: InviteCode.normalize(invitationCode),
                status: .pending, expiresAt: now.addingTimeInterval(48 * 3600), createdAt: now
            ))
        }
    }

    public func setPremium(_ premium: Bool, for userID: UUID) {
        arrange { state, _ in
            if premium { state.premiumUsers.insert(userID) } else { state.premiumUsers.remove(userID) }
            for (id, couple) in state.couples where couple.members.contains(userID) && !couple.ended {
                state.pendingEvents.append((id, .spaceChanged))
            }
        }
    }

    /// A note arriving from `author`, as if sent from their own phone.
    @discardableResult
    public func deliverNote(from author: UUID, content: NoteContent, at date: Date? = nil, seen: Bool = false) -> Note? {
        arrange { state, now in
            guard let coupleID = state.activeCoupleID(of: author) else { return nil }
            let created = date ?? now
            let note = Note(
                id: UUID(), coupleID: coupleID, authorID: author, body: content.body, style: content.style,
                photoPath: content.photoPath, drawingPath: content.drawingPath,
                seenAt: seen ? created : nil, createdAt: created
            )
            state.notes.append(note)
            state.pendingEvents.append((coupleID, .note(note)))
            return note
        }
    }

    /// Has `user` answer today's question, as their own phone would. Used to
    /// play the partner in demo mode and in tests.
    @discardableResult
    public func answerTogether(as user: UUID, _ answer: String) -> Bool {
        arrange { state, now in
            guard let coupleID = state.activeCoupleID(of: user) else { return false }
            let index = state.togetherIndex(coupleID: coupleID, day: DayDate(now))
            guard state.together[index].revealedAt == nil else { return false }
            state.together[index].answers[user] = answer
            state.pendingEvents.append((coupleID, .togetherChanged))
            return true
        }
    }

    /// Opens today's moment, as either person tapping "Open together" would.
    @discardableResult
    public func revealTogether(as user: UUID) -> Bool {
        arrange { state, now in
            guard let coupleID = state.activeCoupleID(of: user) else { return false }
            let index = state.togetherIndex(coupleID: coupleID, day: DayDate(now))
            guard state.together[index].answers.count == 2 else { return false }
            if state.together[index].revealedAt == nil { state.together[index].revealedAt = now }
            state.pendingEvents.append((coupleID, .togetherChanged))
            return true
        }
    }

    /// Moves every moment `days` into the past, as if that long had gone by.
    public func ageTogether(days: Int) {
        arrange { state, _ in
            for index in state.together.indices {
                let day = state.together[index].day
                var components = DateComponents()
                components.year = day.year
                components.month = day.month
                components.day = day.day - days
                if let date = Calendar.current.date(from: components) { state.together[index].day = DayDate(date) }
            }
        }
    }

    public func addMemory(_ memory: Memory) {
        arrange { state, _ in state.memories.append(memory) }
    }

    public func addDate(_ date: ImportantDate) {
        arrange { state, _ in state.dates.append(date) }
    }

    public func storeMedia(_ data: Data, at path: String) {
        arrange { state, _ in state.media[path] = data }
    }

    public func setReaction(_ kind: ReactionKind, on noteID: UUID, by userID: UUID) {
        arrange { state, _ in
            state.reactions.removeAll { $0.noteID == noteID && $0.userID == userID }
            state.reactions.append(Reaction(noteID: noteID, userID: userID, kind: kind))
            if let coupleID = state.notes.first(where: { $0.id == noteID })?.coupleID {
                state.pendingEvents.append((coupleID, .reactionsChanged))
            }
        }
    }

    /// Runs the scheduled-message worker once. Returns how many were delivered.
    /// Mirrors `deliver_due_scheduled_messages`: the note takes the message's
    /// id, so a repeat run cannot deliver twice.
    @discardableResult
    public func deliverDueScheduledMessages() -> Int {
        arrange { state, now in
            var delivered = 0
            for index in state.scheduled.indices {
                let entry = state.scheduled[index]
                guard entry.message.status == .pending, entry.message.deliverAt <= now else { continue }
                guard let couple = state.couples[entry.message.coupleID], !couple.ended,
                      couple.members.count == 2, couple.members.contains(entry.authorID)
                else {
                    state.scheduled[index].message.status = .failed
                    state.scheduled[index].message.failureReason = "not_paired"
                    continue
                }
                if !state.notes.contains(where: { $0.id == entry.message.id }) {
                    let content = entry.message.content
                    let note = Note(
                        id: entry.message.id, coupleID: couple.space.id, authorID: entry.authorID,
                        body: content.body, style: content.style, photoPath: content.photoPath,
                        drawingPath: content.drawingPath, origin: .scheduled, createdAt: now
                    )
                    state.notes.append(note)
                    state.pendingEvents.append((couple.space.id, .note(note)))
                }
                state.scheduled[index].message.status = .delivered
                delivered += 1
            }
            return delivered
        }
    }

    /// Test inspection.
    public func noteCount(coupleID: UUID) -> Int {
        lock.withLock { state.notes.filter { $0.coupleID == coupleID && !$0.isDeleted }.count }
    }

    public func deviceTokens(for userID: UUID) -> [String] {
        lock.withLock { state.deviceTokens.filter { $0.value == userID }.map(\.key).sorted() }
    }

    public func hasAccount(_ userID: UUID) -> Bool {
        lock.withLock { state.accounts[userID] != nil }
    }
}

extension LocalWorld.State {
    /// The questions the in-memory backend asks. The real library lives in the
    /// database; this is only so demo mode and tests have something to show.
    static let togetherQuestions: [(category: String, body: String)] = [
        ("appreciation", "What’s one little thing I did recently that made you happy?"),
        ("memories", "What’s a memory of us that always makes you smile?"),
        ("future", "What’s something new you’d love us to try together?"),
        ("memories", "When did you feel especially close to me?"),
        ("everyday", "What’s one small thing we could do to make this week better?"),
        ("appreciation", "What’s something about us that you’re grateful for?"),
    ]

    /// The paired couple a person is in, as the Together functions require.
    func togetherCoupleID(of user: UUID) -> UUID? {
        guard let id = activeCoupleID(of: user), couples[id]?.members.count == 2 else { return nil }
        return id
    }

    /// Finds the couple's moment for a day, creating it on first asking.
    mutating func togetherIndex(coupleID: UUID, day: DayDate) -> Int {
        if let index = together.firstIndex(where: { $0.coupleID == coupleID && $0.day == day }) { return index }
        let asked = together.filter { $0.coupleID == coupleID }.count
        together.append(LocalWorld.Together(
            id: UUID(), coupleID: coupleID, day: day, questionIndex: asked % Self.togetherQuestions.count
        ))
        return together.count - 1
    }

    /// One person's view of a moment: the same rule the server applies.
    func togetherView(_ moment: LocalWorld.Together, for user: UUID) -> TogetherMoment {
        let mine = moment.answers[user]
        let theirs = moment.answers.first { $0.key != user }?.value
        let revealed = moment.revealedAt != nil
        let status: TogetherMoment.Status = revealed ? .revealed
            : (mine != nil && theirs != nil) ? .ready
            : mine != nil ? .waiting : .open
        let question = Self.togetherQuestions[moment.questionIndex]
        return TogetherMoment(
            id: moment.id, day: moment.day,
            question: .init(id: moment.questionIndex + 1, category: question.category, body: question.body),
            status: status, myAnswer: mine, partnerAnswered: theirs != nil,
            partnerAnswer: revealed ? theirs : nil, revealedAt: moment.revealedAt,
            memoryID: memories.first { $0.togetherMomentID == moment.id }?.id
        )
    }

    func activeCoupleID(of user: UUID) -> UUID? {
        couples.values.first { !$0.ended && $0.members.contains(user) }?.space.id
    }

    func isPremium(coupleID: UUID) -> Bool {
        guard let couple = couples[coupleID], !couple.ended else { return false }
        return couple.members.contains(where: premiumUsers.contains)
    }

    func entitlement(for user: UUID) -> Entitlement {
        if premiumUsers.contains(user) {
            return Entitlement(isPremium: true, source: .own)
        }
        if let coupleID = activeCoupleID(of: user), isPremium(coupleID: coupleID) {
            return Entitlement(isPremium: true, source: .partner)
        }
        return .free
    }

    /// Throws unless `user` is a current member of `coupleID`.
    func requireMember(_ user: UUID, of coupleID: UUID) throws {
        guard let couple = couples[coupleID], !couple.ended, couple.members.contains(user) else {
            throw AppError.noteNotFound
        }
    }

    func isBlocked(_ a: UUID, _ b: UUID) -> Bool {
        blocks.contains([a, b]) || blocks.contains([b, a])
    }

    func isRateLimited(_ user: UUID, now: Date) -> Bool {
        (failedAttempts[user] ?? []).filter { $0 > now.addingTimeInterval(-15 * 60) }.count >= 5
    }

    mutating func endCouple(_ coupleID: UUID) {
        couples[coupleID]?.ended = true
        couples[coupleID]?.members = []
        for index in invitations.indices where invitations[index].coupleID == coupleID && invitations[index].status == .pending {
            invitations[index].status = .revoked
        }
        pendingEvents.append((coupleID, .spaceChanged))
    }
}
