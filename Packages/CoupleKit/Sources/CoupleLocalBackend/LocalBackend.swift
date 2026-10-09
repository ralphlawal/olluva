import CoupleDomain
import Foundation

/// One signed-in device talking to a `LocalWorld`.
public final class LocalBackend: @unchecked Sendable {
    public let world: LocalWorld
    private let lock = NSLock()
    private var sessionUser: UUID?
    private var authListeners: [UUID: AsyncStream<AuthState>.Continuation] = [:]

    public init(world: LocalWorld, signedInAs userID: UUID? = nil) {
        self.world = world
        sessionUser = userID
    }

    /// The repositories, bundled the way the app consumes them.
    public func makeBackend() -> Backend {
        Backend(
            auth: self, profiles: self, couples: self, notes: self, realtime: self, media: self,
            memories: self, dates: self, schedule: self, notifications: self, entitlements: self,
            isDemo: true
        )
    }

    public var currentUserID: UUID? {
        lock.withLock { sessionUser }
    }

    /// Simulates the server ending the session (expiry, remote sign-out).
    public func expireSession() {
        setSession(nil)
    }

    private func setSession(_ userID: UUID?) {
        let (listeners, state): ([AsyncStream<AuthState>.Continuation], AuthState) = lock.withLock {
            sessionUser = userID
            return (Array(authListeners.values), authStateLocked())
        }
        for listener in listeners { listener.yield(state) }
    }

    private func authStateLocked() -> AuthState {
        guard let id = sessionUser else { return .signedOut }
        let email = try? world.read { state, _ in state.accounts[id]?.email }
        return .signedIn(userID: id, email: email ?? nil)
    }

    private func user() throws -> UUID {
        guard let id = currentUserID else { throw AppError.sessionExpired }
        return id
    }

    private func pause() async {
        if world.latency > .zero { try? await Task.sleep(for: world.latency) }
    }
}

// MARK: - Auth

extension LocalBackend: AuthRepository {
    public func restoreSession() async -> AuthState {
        lock.withLock { authStateLocked() }
    }

    public func stateChanges() -> AsyncStream<AuthState> {
        AsyncStream { continuation in
            let token = UUID()
            lock.withLock { authListeners[token] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.authListeners[token] = nil }
            }
        }
    }

    public func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        await pause()
        guard InputRules.isAcceptablePassword(password) else { throw AppError.weakPassword }
        let address = email.lowercased().trimmingCharacters(in: .whitespaces)
        let needsConfirmation = world.requiresEmailConfirmation
        let id: UUID = try world.mutate { state, _ in
            if state.accounts.values.contains(where: { $0.email == address }) {
                throw AppError.emailAlreadyRegistered
            }
            let id = UUID()
            state.accounts[id] = LocalWorld.Account(
                id: id, email: address, password: password, confirmed: !needsConfirmation,
                pendingCode: needsConfirmation ? LocalWorld.verificationCode : nil
            )
            state.profiles[id] = Profile(id: id, displayName: InputRules.cleanedDisplayName(displayName), timeZone: TimeZone.current.identifier)
            state.preferences[id] = NotificationPreferences()
            return id
        }
        if needsConfirmation { return .confirmationRequired }
        setSession(id)
        return .signedIn
    }

    public func confirmSignUp(email: String, code: String) async throws {
        await pause()
        let address = email.lowercased()
        let id: UUID = try world.mutate { state, _ in
            guard let account = state.accounts.values.first(where: { $0.email == address }),
                  account.pendingCode == code
            else { throw AppError.invalidCode }
            state.accounts[account.id]?.confirmed = true
            state.accounts[account.id]?.pendingCode = nil
            return account.id
        }
        setSession(id)
    }

    public func resendConfirmation(email: String) async throws {
        await pause()
        _ = try world.read { _, _ in () }
    }

    public func signIn(email: String, password: String) async throws {
        await pause()
        let address = email.lowercased().trimmingCharacters(in: .whitespaces)
        let id: UUID = try world.read { state, _ in
            guard let account = state.accounts.values.first(where: { $0.email == address }),
                  account.password == password
            else { throw AppError.invalidCredentials }
            guard account.confirmed else { throw AppError.emailNotConfirmed }
            return account.id
        }
        setSession(id)
    }

    public func signInWithApple(idToken: String, nonce: String, displayName: String?) async throws {
        // There is no Apple identity to verify against in memory.
        throw AppError.appleSignInUnavailable
    }

    public func requestPasswordReset(email: String) async throws {
        await pause()
        let address = email.lowercased()
        // Succeeds whether or not the address exists, as the real service does.
        try world.mutate { state, _ in
            if let account = state.accounts.values.first(where: { $0.email == address }) {
                state.accounts[account.id]?.pendingCode = LocalWorld.verificationCode
            }
        }
    }

    public func resetPassword(email: String, code: String, newPassword: String) async throws {
        await pause()
        guard InputRules.isAcceptablePassword(newPassword) else { throw AppError.weakPassword }
        let address = email.lowercased()
        let id: UUID = try world.mutate { state, _ in
            guard let account = state.accounts.values.first(where: { $0.email == address }),
                  account.pendingCode == code
            else { throw AppError.invalidCode }
            state.accounts[account.id]?.password = newPassword
            state.accounts[account.id]?.pendingCode = nil
            state.accounts[account.id]?.confirmed = true
            return account.id
        }
        setSession(id)
    }

    public func changePassword(to newPassword: String) async throws {
        await pause()
        let uid = try user()
        guard InputRules.isAcceptablePassword(newPassword) else { throw AppError.weakPassword }
        try world.mutate { state, _ in state.accounts[uid]?.password = newPassword }
    }

    public func signOut() async throws {
        await pause()
        setSession(nil)
    }

    public func deleteAccount() async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in
            if let coupleID = state.activeCoupleID(of: uid) { state.endCouple(coupleID) }
            state.notes.removeAll { $0.authorID == uid }
            state.memories.removeAll { $0.createdBy == uid }
            state.dates.removeAll { $0.createdBy == uid }
            state.scheduled.removeAll { $0.authorID == uid }
            state.reactions.removeAll { $0.userID == uid }
            state.invitations.removeAll { $0.createdBy == uid }
            state.deviceTokens = state.deviceTokens.filter { $0.value != uid }
            state.preferences[uid] = nil
            state.premiumUsers.remove(uid)
            state.profiles[uid] = nil
            state.accounts[uid] = nil
        }
        setSession(nil)
    }

    public func exportData() async throws -> Data {
        await pause()
        let uid = try user()
        let document: [String: Any] = try world.read { state, now in
            let iso = ISO8601DateFormatter()
            return [
                "exported_at": iso.string(from: now),
                "format_version": 1,
                "profile": ["display_name": state.profiles[uid]?.displayName ?? ""],
                "notes": state.notes.filter { $0.authorID == uid && !$0.isDeleted }.map {
                    ["id": $0.id.uuidString, "body": $0.body, "created_at": iso.string(from: $0.createdAt)]
                },
                "memories": state.memories.filter { $0.createdBy == uid }.map {
                    ["id": $0.id.uuidString, "title": $0.title, "caption": $0.caption, "occurred_on": $0.occurredOn.description]
                },
                "important_dates": state.dates.filter { $0.createdBy == uid }.map {
                    ["title": $0.title, "starts_on": $0.startsOn.description]
                },
            ]
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - Profile

extension LocalBackend: ProfileRepository {
    public func myProfile() async throws -> Profile {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            guard let profile = state.profiles[uid] else { throw AppError.sessionExpired }
            return profile
        }
    }

    public func updateProfile(displayName: String?, timeZone: String?) async throws -> Profile {
        await pause()
        let uid = try user()
        return try world.mutate { state, _ in
            guard var profile = state.profiles[uid] else { throw AppError.sessionExpired }
            if let displayName { profile.displayName = InputRules.cleanedDisplayName(displayName) }
            if let timeZone { profile.timeZone = timeZone }
            state.profiles[uid] = profile
            if let coupleID = state.activeCoupleID(of: uid) { state.pendingEvents.append((coupleID, .spaceChanged)) }
            return profile
        }
    }

    public func setAvatar(jpeg: Data) async throws -> Profile {
        await pause()
        let uid = try user()
        guard jpeg.count <= MediaPath.maximumAvatarBytes else { throw AppError.mediaTooLarge }
        return try world.mutate { state, _ in
            let path = MediaPath.avatar(userID: uid)
            state.media[path] = jpeg
            state.profiles[uid]?.avatarPath = path
            if let coupleID = state.activeCoupleID(of: uid) { state.pendingEvents.append((coupleID, .spaceChanged)) }
            return state.profiles[uid]!
        }
    }

    public func removeAvatar() async throws -> Profile {
        await pause()
        let uid = try user()
        return try world.mutate { state, _ in
            state.media[MediaPath.avatar(userID: uid)] = nil
            state.profiles[uid]?.avatarPath = nil
            return state.profiles[uid]!
        }
    }
}

// MARK: - Couples and pairing

extension LocalBackend: CoupleRepository {
    public func spaceState() async throws -> SpaceState {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            guard let coupleID = state.activeCoupleID(of: uid), let couple = state.couples[coupleID] else {
                return .none
            }
            if let partnerID = couple.members.first(where: { $0 != uid }), let partner = state.profiles[partnerID] {
                return .paired(couple.space, partner: partner)
            }
            return .waiting(couple.space)
        }
    }

    public func createSpace() async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, now in
            guard state.activeCoupleID(of: uid) == nil else { throw AppError.alreadyInSpace }
            let id = UUID()
            state.couples[id] = LocalWorld.Couple(space: CoupleSpace(id: id, createdAt: now), members: [uid])
        }
    }

    public func createInvitation() async throws -> IssuedInvitation {
        await pause()
        let uid = try user()
        return try world.mutate { state, now in
            guard let coupleID = state.activeCoupleID(of: uid) else { throw AppError.noSpace }
            guard state.couples[coupleID]?.members.count == 1 else { throw AppError.alreadyPaired }
            let recent = state.invitations.filter { $0.createdBy == uid && $0.createdAt > now.addingTimeInterval(-86_400) }
            guard recent.count < 10 else { throw AppError.rateLimited }
            for index in state.invitations.indices where state.invitations[index].coupleID == coupleID && state.invitations[index].status == .pending {
                state.invitations[index].status = .revoked
            }
            let alphabet = Array(InviteCode.alphabet).sorted()
            let code = String((0..<InviteCode.length).map { _ in alphabet.randomElement()! })
            let invitation = LocalWorld.Invitation(
                id: UUID(), coupleID: coupleID, createdBy: uid, code: code, status: .pending,
                expiresAt: now.addingTimeInterval(48 * 3600), createdAt: now
            )
            state.invitations.append(invitation)
            return IssuedInvitation(id: invitation.id, code: code, expiresAt: invitation.expiresAt)
        }
    }

    public func revokeInvitation(id: UUID) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in
            guard let index = state.invitations.firstIndex(where: { $0.id == id && $0.createdBy == uid && $0.status == .pending }) else {
                throw AppError.invitationUnavailable
            }
            state.invitations[index].status = .revoked
        }
    }

    /// Finds a usable invitation, recording a failed attempt when there is
    /// none. The attempt is recorded outside the failing transaction so that
    /// it survives, exactly as the database functions arrange.
    private func resolve(code: String, uid: UUID) throws -> LocalWorld.Invitation {
        let normalized = InviteCode.normalize(code)
        do {
            return try world.read { state, now in
                if state.isRateLimited(uid, now: now) { throw AppError.rateLimited }
                guard let invitation = state.invitations.first(where: { $0.code == normalized }),
                      invitation.status == .pending,
                      !state.isBlocked(uid, invitation.createdBy)
                else { throw AppError.invitationUnavailable }
                if invitation.expiresAt <= now { throw AppError.invitationExpired }
                if invitation.createdBy == uid { throw AppError.ownInvitation }
                return invitation
            }
        } catch let error as AppError where error == .invitationUnavailable || error == .invitationExpired {
            world.arrange { state, now in state.failedAttempts[uid, default: []].append(now) }
            throw error
        }
    }

    public func previewInvitation(code: String) async throws -> InvitationPreview {
        await pause()
        let uid = try user()
        let invitation = try resolve(code: code, uid: uid)
        return try world.read { state, _ in
            InvitationPreview(inviterName: state.profiles[invitation.createdBy]?.displayName ?? "", expiresAt: invitation.expiresAt)
        }
    }

    public func acceptInvitation(code: String) async throws {
        await pause()
        let uid = try user()
        let invitation = try resolve(code: code, uid: uid)
        try world.mutate { state, now in
            if let mine = state.activeCoupleID(of: uid) {
                guard state.couples[mine]?.members.count == 1 else { throw AppError.alreadyPaired }
                state.endCouple(mine)
            }
            guard let index = state.invitations.firstIndex(where: { $0.id == invitation.id && $0.status == .pending }),
                  var couple = state.couples[invitation.coupleID], !couple.ended, couple.members == [invitation.createdBy]
            else { throw AppError.invitationUnavailable }
            couple.members.append(uid)
            couple.space.pairedAt = now
            state.couples[couple.space.id] = couple
            state.invitations[index].status = .accepted
            state.pendingEvents.append((couple.space.id, .spaceChanged))
        }
    }

    public func declineInvitation(code: String) async throws {
        await pause()
        let uid = try user()
        let invitation = try resolve(code: code, uid: uid)
        try world.mutate { state, _ in
            guard let index = state.invitations.firstIndex(where: { $0.id == invitation.id }) else { return }
            state.invitations[index].status = .declined
            state.pendingEvents.append((invitation.coupleID, .spaceChanged))
        }
    }

    public func leaveSpace(blockPartner: Bool) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in
            guard let coupleID = state.activeCoupleID(of: uid), let couple = state.couples[coupleID] else {
                throw AppError.noSpace
            }
            if blockPartner, let partner = couple.members.first(where: { $0 != uid }) {
                state.blocks.insert([uid, partner])
            }
            state.endCouple(coupleID)
        }
    }

    public func setTheme(id: String, accentHex: String?) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in
            guard let coupleID = state.activeCoupleID(of: uid) else { throw AppError.noSpace }
            guard let theme = Theme.all.first(where: { $0.id == id }) else { throw AppError.unexpected(code: "unknown_theme") }
            if (theme.isPremium || accentHex != nil) && !state.isPremium(coupleID: coupleID) {
                throw AppError.premiumRequired
            }
            state.couples[coupleID]?.space.themeID = id
            state.couples[coupleID]?.space.accentHex = accentHex
            state.pendingEvents.append((coupleID, .spaceChanged))
        }
    }
}

// MARK: - Notes

extension LocalBackend: NoteRepository {
    public func recentNotes(coupleID: UUID, before: Date?, limit: Int) async throws -> [Note] {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            guard state.couples[coupleID]?.members.contains(uid) == true else { return [] }
            return Array(
                state.notes
                    .filter { $0.coupleID == coupleID && (before == nil || $0.createdAt < before!) }
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(limit)
            )
        }
    }

    public func send(id: UUID, coupleID: UUID, content: NoteContent) async throws -> Note {
        await pause()
        let uid = try user()
        try InputRules.validate(content)
        return try world.mutate { state, now in
            try state.requireMember(uid, of: coupleID)
            // Idempotent on the client-chosen id.
            if let existing = state.notes.first(where: { $0.id == id }) {
                guard existing.authorID == uid else { throw AppError.noteNotFound }
                return existing
            }
            let note = Note(
                id: id, coupleID: coupleID, authorID: uid, body: content.body, style: content.style,
                photoPath: content.photoPath, drawingPath: content.drawingPath, createdAt: now
            )
            state.notes.append(note)
            state.pendingEvents.append((coupleID, .note(note)))
            return note
        }
    }

    public func update(noteID: UUID, expectedVersion: Int, content: NoteContent) async throws -> Note {
        await pause()
        let uid = try user()
        try InputRules.validate(content)
        return try world.mutate { state, now in
            guard let index = state.notes.firstIndex(where: { $0.id == noteID }), !state.notes[index].isDeleted else {
                throw AppError.noteNotFound
            }
            try state.requireMember(uid, of: state.notes[index].coupleID)
            guard state.notes[index].authorID == uid else { throw AppError.notAuthor }
            guard state.notes[index].version == expectedVersion else { throw AppError.versionConflict }
            state.notes[index].body = content.body
            state.notes[index].style = content.style
            state.notes[index].photoPath = content.photoPath
            state.notes[index].drawingPath = content.drawingPath
            state.notes[index].version += 1
            state.notes[index].updatedAt = now
            state.pendingEvents.append((state.notes[index].coupleID, .note(state.notes[index])))
            return state.notes[index]
        }
    }

    public func delete(noteID: UUID) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, now in
            guard let index = state.notes.firstIndex(where: { $0.id == noteID }) else { throw AppError.noteNotFound }
            try state.requireMember(uid, of: state.notes[index].coupleID)
            guard state.notes[index].authorID == uid else { throw AppError.notAuthor }
            guard !state.notes[index].isDeleted else { return }
            state.notes[index].deletedAt = now
            state.notes[index].body = ""
            state.notes[index].style = NoteStyle()
            state.notes[index].photoPath = nil
            state.notes[index].drawingPath = nil
            state.notes[index].version += 1
            state.reactions.removeAll { $0.noteID == noteID }
            state.pendingEvents.append((state.notes[index].coupleID, .note(state.notes[index])))
        }
    }

    public func markSeen(noteID: UUID) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, now in
            guard let index = state.notes.firstIndex(where: { $0.id == noteID }),
                  state.couples[state.notes[index].coupleID]?.members.contains(uid) == true,
                  state.notes[index].authorID != uid, state.notes[index].seenAt == nil, !state.notes[index].isDeleted
            else { return }
            state.notes[index].seenAt = now
            state.pendingEvents.append((state.notes[index].coupleID, .note(state.notes[index])))
        }
    }

    public func reactions(coupleID: UUID) async throws -> [Reaction] {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            guard state.couples[coupleID]?.members.contains(uid) == true else { return [] }
            let ids = Set(state.notes.filter { $0.coupleID == coupleID }.map(\.id))
            return state.reactions.filter { ids.contains($0.noteID) }
        }
    }

    public func setReaction(noteID: UUID, kind: ReactionKind?) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in
            guard let note = state.notes.first(where: { $0.id == noteID }), !note.isDeleted else { throw AppError.noteNotFound }
            try state.requireMember(uid, of: note.coupleID)
            guard note.authorID != uid else { throw AppError.notAuthor }
            state.reactions.removeAll { $0.noteID == noteID && $0.userID == uid }
            if let kind { state.reactions.append(Reaction(noteID: noteID, userID: uid, kind: kind)) }
            state.pendingEvents.append((note.coupleID, .reactionsChanged))
        }
    }
}

// MARK: - Realtime and media

extension LocalBackend: RealtimeRepository {
    public func events(coupleID: UUID) -> AsyncStream<SpaceEvent> {
        world.events(coupleID: coupleID)
    }
}

extension LocalBackend: MediaRepository {
    public func upload(_ data: Data, to path: String, contentType: String) async throws {
        await pause()
        let uid = try user()
        guard data.count <= MediaPath.maximumMediaBytes else { throw AppError.mediaTooLarge }
        try world.mutate { state, _ in
            // Same rule as the storage policy: only into your own couple's folder.
            guard let coupleID = state.activeCoupleID(of: uid),
                  path.hasPrefix("couples/\(coupleID.uuidString.lowercased())/"),
                  state.media[path] == nil
            else { throw AppError.uploadFailed }
            state.media[path] = data
        }
    }

    public func download(path: String) async throws -> Data {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            guard let coupleID = state.activeCoupleID(of: uid),
                  path.hasPrefix("couples/\(coupleID.uuidString.lowercased())/"),
                  let data = state.media[path]
            else { throw AppError.mediaUnreadable }
            return data
        }
    }

    public func downloadAvatar(path: String) async throws -> Data {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            let partner = state.activeCoupleID(of: uid).flatMap { state.couples[$0]?.members.first { $0 != uid } }
            let allowed = [uid, partner].compactMap { $0 }.map(MediaPath.avatar(userID:))
            guard allowed.contains(path), let data = state.media[path] else { throw AppError.mediaUnreadable }
            return data
        }
    }
}

// MARK: - Memories

extension LocalBackend: MemoryRepository {
    public func memories(coupleID: UUID, after cursor: MemoryCursor?, limit: Int) async throws -> [Memory] {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            guard state.couples[coupleID]?.members.contains(uid) == true else { return [] }
            let key: (Memory) -> (DayDate, Date, String) = { ($0.occurredOn, $0.createdAt, $0.id.uuidString) }
            let sorted = state.memories.filter { $0.coupleID == coupleID }.sorted { key($0) > key($1) }
            guard let cursor else { return Array(sorted.prefix(limit)) }
            let boundary = (cursor.occurredOn, cursor.createdAt, cursor.id.uuidString)
            return Array(sorted.filter { key($0) < boundary }.prefix(limit))
        }
    }

    public func count(coupleID: UUID) async throws -> Int {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            guard state.couples[coupleID]?.members.contains(uid) == true else { return 0 }
            return state.memories.filter { $0.coupleID == coupleID }.count
        }
    }

    private static func requireRoom(in state: LocalWorld.State, coupleID: UUID) throws {
        let limit = state.isPremium(coupleID: coupleID) ? ProductConfiguration.premium.memories : ProductConfiguration.free.memories
        guard state.memories.filter({ $0.coupleID == coupleID }).count < limit else { throw AppError.memoryLimitReached }
    }

    public func saveNote(noteID: UUID, caption: String) async throws -> UUID {
        await pause()
        let uid = try user()
        return try world.mutate { state, now in
            guard let note = state.notes.first(where: { $0.id == noteID }), !note.isDeleted else { throw AppError.noteNotFound }
            try state.requireMember(uid, of: note.coupleID)
            if let existing = state.memories.first(where: { $0.sourceNoteID == noteID }) { return existing.id }
            try Self.requireRoom(in: state, coupleID: note.coupleID)
            let memory = Memory(
                id: UUID(), coupleID: note.coupleID, createdBy: uid, kind: .note,
                caption: String(caption.prefix(Validation.memoryCaptionLimit)), content: note.content,
                sourceNoteID: noteID, occurredOn: DayDate(note.createdAt), createdAt: now
            )
            state.memories.append(memory)
            state.pendingEvents.append((note.coupleID, .memoriesChanged))
            return memory.id
        }
    }

    public func add(_ moment: NewMoment, coupleID: UUID) async throws -> Memory {
        await pause()
        let uid = try user()
        return try world.mutate { state, now in
            try state.requireMember(uid, of: coupleID)
            try Self.requireRoom(in: state, coupleID: coupleID)
            let memory = Memory(
                id: moment.id, coupleID: coupleID, createdBy: uid, kind: moment.kind,
                title: moment.title, caption: moment.caption,
                content: NoteContent(photoPath: moment.photoPath, drawingPath: moment.drawingPath),
                occurredOn: moment.occurredOn, createdAt: now
            )
            state.memories.append(memory)
            state.pendingEvents.append((coupleID, .memoriesChanged))
            return memory
        }
    }

    public func update(id: UUID, title: String, caption: String, occurredOn: DayDate) async throws -> Memory {
        await pause()
        let uid = try user()
        return try world.mutate { state, _ in
            guard let index = state.memories.firstIndex(where: { $0.id == id }) else { throw AppError.noteNotFound }
            try state.requireMember(uid, of: state.memories[index].coupleID)
            state.memories[index].title = title
            state.memories[index].caption = caption
            state.memories[index].occurredOn = occurredOn
            state.pendingEvents.append((state.memories[index].coupleID, .memoriesChanged))
            return state.memories[index]
        }
    }

    public func deleteMemory(id: UUID) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in
            guard let memory = state.memories.first(where: { $0.id == id }) else { return }
            try state.requireMember(uid, of: memory.coupleID)
            state.memories.removeAll { $0.id == id }
            state.pendingEvents.append((memory.coupleID, .memoriesChanged))
        }
    }
}

// MARK: - Important dates

extension LocalBackend: DatesRepository {
    public func dates(coupleID: UUID) async throws -> [ImportantDate] {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            guard state.couples[coupleID]?.members.contains(uid) == true else { return [] }
            return state.dates.filter { $0.coupleID == coupleID && ($0.visibility == .shared || $0.createdBy == uid) }
        }
    }

    public func add(_ date: ImportantDate) async throws -> ImportantDate {
        await pause()
        let uid = try user()
        return try world.mutate { state, _ in
            try state.requireMember(uid, of: date.coupleID)
            guard state.dates.filter({ $0.coupleID == date.coupleID }).count < ProductConfiguration.importantDatesLimit else {
                throw AppError.dateLimitReached
            }
            var stored = date
            stored.createdBy = uid
            stored.remindDaysBefore = DateRules.sanitizedReminders(date.remindDaysBefore)
            state.dates.append(stored)
            state.pendingEvents.append((date.coupleID, .datesChanged))
            return stored
        }
    }

    public func update(_ date: ImportantDate) async throws -> ImportantDate {
        await pause()
        let uid = try user()
        return try world.mutate { state, _ in
            guard let index = state.dates.firstIndex(where: { $0.id == date.id }) else { throw AppError.noteNotFound }
            let existing = state.dates[index]
            try state.requireMember(uid, of: existing.coupleID)
            guard existing.visibility == .shared || existing.createdBy == uid else { throw AppError.noteNotFound }
            if date.visibility != existing.visibility, existing.createdBy != uid { throw AppError.notAuthor }
            var stored = date
            stored.createdBy = existing.createdBy
            stored.remindDaysBefore = DateRules.sanitizedReminders(date.remindDaysBefore)
            state.dates[index] = stored
            state.pendingEvents.append((existing.coupleID, .datesChanged))
            return stored
        }
    }

    public func deleteDate(id: UUID) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in
            guard let date = state.dates.first(where: { $0.id == id }) else { return }
            try state.requireMember(uid, of: date.coupleID)
            guard date.visibility == .shared || date.createdBy == uid else { return }
            state.dates.removeAll { $0.id == id }
            state.pendingEvents.append((date.coupleID, .datesChanged))
        }
    }
}

// MARK: - Scheduled messages

extension LocalBackend: ScheduleRepository {
    public func scheduledMessages() async throws -> [ScheduledMessage] {
        await pause()
        let uid = try user()
        return try world.read { state, _ in
            // Author-only, like the RLS policy: a surprise stays a surprise.
            state.scheduled.filter { $0.authorID == uid }.map(\.message).sorted { $0.deliverAt < $1.deliverAt }
        }
    }

    public func schedule(id: UUID, coupleID: UUID, content: NoteContent, deliverAt: Date, timeZone: String) async throws -> ScheduledMessage {
        await pause()
        let uid = try user()
        try InputRules.validate(content)
        return try world.mutate { state, now in
            try state.requireMember(uid, of: coupleID)
            if let existing = state.scheduled.first(where: { $0.message.id == id && $0.authorID == uid }) {
                return existing.message
            }
            guard deliverAt >= now.addingTimeInterval(60) else { throw AppError.deliveryTooSoon }
            guard deliverAt <= now.addingTimeInterval(ScheduleRules.maximumLead) else { throw AppError.deliveryTooFar }
            let limit = state.isPremium(coupleID: coupleID)
                ? ProductConfiguration.premium.pendingScheduledMessages
                : ProductConfiguration.free.pendingScheduledMessages
            let pending = state.scheduled.filter { $0.authorID == uid && $0.message.coupleID == coupleID && $0.message.status == .pending }
            guard pending.count < limit else { throw AppError.scheduledLimitReached }
            let message = ScheduledMessage(id: id, coupleID: coupleID, content: content, deliverAt: deliverAt, timeZone: timeZone, createdAt: now)
            state.scheduled.append(LocalWorld.Scheduled(message: message, authorID: uid))
            return message
        }
    }

    public func update(id: UUID, expectedVersion: Int, content: NoteContent, deliverAt: Date, timeZone: String) async throws -> ScheduledMessage {
        await pause()
        let uid = try user()
        try InputRules.validate(content)
        return try world.mutate { state, now in
            guard let index = state.scheduled.firstIndex(where: { $0.message.id == id && $0.authorID == uid }) else {
                throw AppError.noteNotFound
            }
            guard state.scheduled[index].message.status == .pending else { throw AppError.scheduleNotEditable }
            guard state.scheduled[index].message.version == expectedVersion else { throw AppError.versionConflict }
            guard deliverAt >= now.addingTimeInterval(60) else { throw AppError.deliveryTooSoon }
            state.scheduled[index].message.content = content
            state.scheduled[index].message.deliverAt = deliverAt
            state.scheduled[index].message.timeZone = timeZone
            state.scheduled[index].message.version += 1
            return state.scheduled[index].message
        }
    }

    public func cancel(id: UUID) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in
            guard let index = state.scheduled.firstIndex(where: { $0.message.id == id && $0.authorID == uid }) else {
                throw AppError.noteNotFound
            }
            switch state.scheduled[index].message.status {
            case .cancelled: return
            case .pending: state.scheduled[index].message.status = .cancelled
            default: throw AppError.scheduleNotEditable
            }
        }
    }
}

// MARK: - Notifications and entitlement

extension LocalBackend: NotificationRepository {
    public func preferences() async throws -> NotificationPreferences {
        await pause()
        let uid = try user()
        return try world.read { state, _ in state.preferences[uid] ?? NotificationPreferences() }
    }

    public func update(_ preferences: NotificationPreferences) async throws {
        await pause()
        let uid = try user()
        try world.mutate { state, _ in state.preferences[uid] = preferences }
    }

    public func registerDevice(token: String, environment: PushEnvironment) async throws {
        let uid = try user()
        try world.mutate { state, _ in state.deviceTokens[token.lowercased()] = uid }
    }

    public func unregisterDevice(token: String) async throws {
        let uid = try user()
        try world.mutate { state, _ in
            if state.deviceTokens[token.lowercased()] == uid { state.deviceTokens[token.lowercased()] = nil }
        }
    }
}

extension LocalBackend: EntitlementRepository {
    public func entitlement() async throws -> Entitlement {
        await pause()
        let uid = try user()
        return try world.read { state, _ in state.entitlement(for: uid) }
    }

    /// The in-memory world has no way to verify Apple's signature, so it never
    /// grants anything from a submitted transaction. Premium is only ever
    /// switched on here explicitly, via `LocalWorld.setPremium`.
    public func submitTransaction(jws: String) async throws -> Entitlement {
        await pause()
        return try await entitlement()
    }
}
