import CoupleDomain
import Foundation
import Supabase

public enum SupabaseBackendFactory {
    /// Builds the production backend. `anonKey` is the project's public key:
    /// it identifies the app and grants nothing by itself; every request is
    /// authorised by the signed-in user's token against Row Level Security.
    /// The service-role key is never present in the app.
    public static func make(url: URL, anonKey: String) -> Backend {
        let client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
        let repositories = SupabaseRepositories(client: client)
        return Backend(
            auth: repositories, profiles: repositories, couples: repositories, notes: repositories,
            realtime: repositories, media: repositories, memories: repositories, dates: repositories,
            schedule: repositories, notifications: repositories, entitlements: repositories, isDemo: false
        )
    }
}

/// Every repository, implemented over one Supabase client.
///
/// The session lives in the Keychain (the SDK's default storage) and is
/// refreshed automatically. All writes that carry rules go through database
/// functions; the client is never trusted to enforce anything.
final class SupabaseRepositories: Sendable {
    static let mediaBucket = "couple-media"
    static let avatarBucket = "avatars"

    let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// Runs a call, translating whatever it throws.
    func run<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func userID() throws -> UUID {
        guard let id = client.auth.currentUser?.id else { throw AppError.sessionExpired }
        return id
    }

    var decoder: JSONDecoder { PostgrestClient.Configuration.jsonDecoder }
}

// MARK: - Auth

extension SupabaseRepositories: AuthRepository {
    func restoreSession() async -> AuthState {
        // Reading `session` refreshes an expired token; if that is impossible
        // the stored session is unusable and the person is signed out.
        guard let session = try? await client.auth.session else { return .signedOut }
        return .signedIn(userID: session.user.id, email: session.user.email)
    }

    func stateChanges() -> AsyncStream<AuthState> {
        AsyncStream { continuation in
            let task = Task {
                for await change in client.auth.authStateChanges {
                    switch change.event {
                    case .initialSession:
                        continue
                    case .signedOut, .userDeleted:
                        continuation.yield(.signedOut)
                    default:
                        if let session = change.session {
                            continuation.yield(.signedIn(userID: session.user.id, email: session.user.email))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        try await run {
            let response = try await client.auth.signUp(
                email: email, password: password,
                data: ["display_name": .string(InputRules.cleanedDisplayName(displayName))]
            )
            if case .session = response { return .signedIn }
            return .confirmationRequired
        }
    }

    func confirmSignUp(email: String, code: String) async throws {
        try await run { _ = try await client.auth.verifyOTP(email: email, token: code, type: .signup) }
    }

    func resendConfirmation(email: String) async throws {
        try await run { try await client.auth.resend(email: email, type: .signup) }
    }

    func signIn(email: String, password: String) async throws {
        try await run { _ = try await client.auth.signIn(email: email, password: password) }
    }

    func signInWithApple(idToken: String, nonce: String, displayName: String?) async throws {
        try await run {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )
            // Apple only shares the name on the very first authorisation, and
            // not inside the token, so it is saved here if the profile lacks one.
            if let name = displayName.map(InputRules.cleanedDisplayName), !name.isEmpty {
                let existing: ProfileRow? = try? await client.from("profiles").select()
                    .eq("id", value: session.user.id).single().execute().value
                if existing?.display_name.isEmpty ?? true {
                    _ = try? await client.from("profiles").update(["display_name": name])
                        .eq("id", value: session.user.id).execute()
                }
            }
        }
    }

    func requestPasswordReset(email: String) async throws {
        try await run { try await client.auth.resetPasswordForEmail(email) }
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws {
        try await run {
            _ = try await client.auth.verifyOTP(email: email, token: code, type: .recovery)
            _ = try await client.auth.update(user: UserAttributes(password: newPassword))
        }
    }

    func changePassword(to newPassword: String) async throws {
        try await run { _ = try await client.auth.update(user: UserAttributes(password: newPassword)) }
    }

    func signOut() async throws {
        do {
            try await client.auth.signOut(scope: .local)
        } catch {
            // The local session must end even if the server cannot be told.
            let mapped = SupabaseErrorMapper.map(error)
            if mapped != .sessionExpired, mapped != .offline, mapped != .timedOut { throw mapped }
        }
    }

    func deleteAccount() async throws {
        // Deleting an auth user needs the service role, so it happens in an
        // Edge Function that authenticates the caller from their own token.
        try await run { try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(method: .post)) }
        try? await client.auth.signOut(scope: .local)
    }

    func exportData() async throws -> Data {
        try await run {
            let raw = try await client.rpc("export_my_data").execute().data
            guard let object = try? JSONSerialization.jsonObject(with: raw),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            else { return raw }
            return pretty
        }
    }
}

// MARK: - Profile

extension SupabaseRepositories: ProfileRepository {
    func myProfile() async throws -> Profile {
        try await run {
            let row: ProfileRow = try await client.from("profiles").select("id, display_name, avatar_path, time_zone")
                .eq("id", value: try userID()).single().execute().value
            return row.model
        }
    }

    func updateProfile(displayName: String?, timeZone: String?) async throws -> Profile {
        try await run {
            var changes: [String: String] = [:]
            if let displayName { changes["display_name"] = InputRules.cleanedDisplayName(displayName) }
            if let timeZone { changes["time_zone"] = timeZone }
            guard !changes.isEmpty else { return try await myProfile() }
            let row: ProfileRow = try await client.from("profiles").update(changes)
                .eq("id", value: try userID()).select("id, display_name, avatar_path, time_zone").single().execute().value
            return row.model
        }
    }

    func setAvatar(jpeg: Data) async throws -> Profile {
        guard jpeg.count <= MediaPath.maximumAvatarBytes else { throw AppError.mediaTooLarge }
        return try await run {
            let path = MediaPath.avatar(userID: try userID())
            try await client.storage.from(Self.avatarBucket).upload(
                path, data: jpeg, options: FileOptions(cacheControl: "0", contentType: "image/jpeg", upsert: true)
            )
            let row: ProfileRow = try await client.from("profiles").update(["avatar_path": path])
                .eq("id", value: try userID()).select("id, display_name, avatar_path, time_zone").single().execute().value
            return row.model
        }
    }

    func removeAvatar() async throws -> Profile {
        try await run {
            let id = try userID()
            _ = try? await client.storage.from(Self.avatarBucket).remove(paths: [MediaPath.avatar(userID: id)])
            let row: ProfileRow = try await client.from("profiles").update(["avatar_path": String?.none])
                .eq("id", value: id).select("id, display_name, avatar_path, time_zone").single().execute().value
            return row.model
        }
    }
}

// MARK: - Couples and pairing

extension SupabaseRepositories: CoupleRepository {
    func spaceState() async throws -> SpaceState {
        try await run {
            let me = try userID()
            // RLS returns only the space the caller is an active member of.
            let spaces: [CoupleSpaceRow] = try await client.from("couple_spaces")
                .select("id, theme_id, accent_hex, paired_at, created_at").limit(1).execute().value
            guard let space = spaces.first else { return .none }

            let members: [MemberRow] = try await client.from("couple_members")
                .select("user_id, profile:profiles(id, display_name, avatar_path, time_zone)")
                .eq("couple_id", value: space.id).execute().value
            if let partner = members.first(where: { $0.user_id != me })?.profile {
                return .paired(space.model, partner: partner.model)
            }
            return .waiting(space.model)
        }
    }

    func createSpace() async throws {
        try await run { _ = try await client.rpc("create_couple_space").execute() }
    }

    func createInvitation() async throws -> IssuedInvitation {
        try await run {
            let payload: IssuedInvitationPayload = try await client.rpc("create_invitation").execute().value
            return IssuedInvitation(id: payload.id, code: payload.code, expiresAt: payload.expires_at)
        }
    }

    func revokeInvitation(id: UUID) async throws {
        try await run { _ = try await client.rpc("revoke_invitation", params: InvitationIDParams(p_invitation_id: id)).execute() }
    }

    func previewInvitation(code: String) async throws -> InvitationPreview {
        try await run {
            let result: PairingResult = try await client.rpc(
                "preview_invitation", params: CodeParams(p_code: InviteCode.normalize(code))
            ).execute().value
            try result.requireSuccess()
            return InvitationPreview(inviterName: result.inviter_name ?? "", expiresAt: result.expires_at ?? Date())
        }
    }

    func acceptInvitation(code: String) async throws {
        try await run {
            let result: PairingResult = try await client.rpc(
                "accept_invitation", params: CodeParams(p_code: InviteCode.normalize(code))
            ).execute().value
            try result.requireSuccess()
        }
    }

    func declineInvitation(code: String) async throws {
        try await run {
            let result: PairingResult = try await client.rpc(
                "decline_invitation", params: CodeParams(p_code: InviteCode.normalize(code))
            ).execute().value
            try result.requireSuccess()
        }
    }

    func leaveSpace(blockPartner: Bool) async throws {
        try await run { _ = try await client.rpc("leave_couple", params: LeaveParams(p_block_partner: blockPartner)).execute() }
    }

    func setTheme(id: String, accentHex: String?) async throws {
        try await run {
            _ = try await client.rpc("set_couple_theme", params: ThemeParams(p_theme_id: id, p_accent_hex: accentHex)).execute()
        }
    }
}

// MARK: - Notes

extension SupabaseRepositories: NoteRepository {
    func recentNotes(coupleID: UUID, before: Date?, limit: Int) async throws -> [Note] {
        try await run {
            var query = client.from("notes").select().eq("couple_id", value: coupleID)
            if let before {
                query = query.lt("created_at", value: ISO8601DateFormatter.fractional.string(from: before))
            }
            let rows: [NoteRow] = try await query
                .order("created_at", ascending: false).order("id", ascending: false).limit(limit).execute().value
            return rows.map(\.model)
        }
    }

    func send(id: UUID, coupleID: UUID, content: NoteContent) async throws -> Note {
        try InputRules.validate(content)
        let insert = NoteInsert(
            id: id, couple_id: coupleID, author_id: try userID(), body: content.body, style: content.style,
            photo_path: content.photoPath, drawing_path: content.drawingPath
        )
        do {
            let row: NoteRow = try await client.from("notes").insert(insert).select().single().execute().value
            return row.model
        } catch where SupabaseErrorMapper.isDuplicate(error) {
            // An earlier attempt did reach the server; its response was lost.
            // Return what is stored rather than reporting a failure that did
            // not happen, or creating a second note.
            return try await run {
                let row: NoteRow = try await client.from("notes").select().eq("id", value: id).single().execute().value
                return row.model
            }
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func update(noteID: UUID, expectedVersion: Int, content: NoteContent) async throws -> Note {
        try InputRules.validate(content)
        return try await run {
            let row: NoteRow = try await client.rpc("update_note", params: UpdateNoteParams(
                p_note_id: noteID, p_expected_version: expectedVersion, p_body: content.body, p_style: content.style,
                p_photo_path: content.photoPath, p_drawing_path: content.drawingPath
            )).execute().value
            return row.model
        }
    }

    func delete(noteID: UUID) async throws {
        try await run { _ = try await client.rpc("delete_note", params: NoteIDParams(p_note_id: noteID)).execute() }
    }

    func markSeen(noteID: UUID) async throws {
        try await run { _ = try await client.rpc("mark_note_seen", params: NoteIDParams(p_note_id: noteID)).execute() }
    }

    func reactions(coupleID: UUID) async throws -> [Reaction] {
        try await run {
            let rows: [ReactionRow] = try await client.from("note_reactions")
                .select("note_id, user_id, kind").eq("couple_id", value: coupleID).execute().value
            return rows.compactMap(\.model)
        }
    }

    func setReaction(noteID: UUID, kind: ReactionKind?) async throws {
        try await run {
            _ = try await client.rpc("set_reaction", params: ReactionParams(p_note_id: noteID, p_kind: kind?.rawValue)).execute()
        }
    }
}

// MARK: - Realtime

extension SupabaseRepositories: RealtimeRepository {
    func events(coupleID: UUID) -> AsyncStream<SpaceEvent> {
        AsyncStream { continuation in
            let task = Task {
                let id = coupleID.uuidString.lowercased()
                let channel = client.channel("space-\(id)")
                let byCouple = RealtimePostgresFilter.eq("couple_id", value: id)

                // Realtime applies the same RLS SELECT policies as the API, so
                // a subscriber only ever receives rows they could have read.
                let notes = channel.postgresChange(AnyAction.self, schema: "public", table: "notes", filter: byCouple)
                let reactions = channel.postgresChange(AnyAction.self, schema: "public", table: "note_reactions", filter: byCouple)
                let memories = channel.postgresChange(AnyAction.self, schema: "public", table: "memories", filter: byCouple)
                let dates = channel.postgresChange(AnyAction.self, schema: "public", table: "important_dates", filter: byCouple)
                let members = channel.postgresChange(AnyAction.self, schema: "public", table: "couple_members", filter: byCouple)
                let spaces = channel.postgresChange(AnyAction.self, schema: "public", table: "couple_spaces", filter: .eq("id", value: id))
                let status = channel.statusChange

                // If the live connection cannot be opened the app still works:
                // it re-reads on every foreground and on every push.
                try? await channel.subscribeWithError()
                let decoder = self.decoder

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await action in notes {
                            switch action {
                            case .insert(let change):
                                if let row = try? change.decodeRecord(as: NoteRow.self, decoder: decoder) {
                                    continuation.yield(.note(row.model))
                                } else {
                                    continuation.yield(.resynchronise)
                                }
                            case .update(let change):
                                if let row = try? change.decodeRecord(as: NoteRow.self, decoder: decoder) {
                                    continuation.yield(.note(row.model))
                                } else {
                                    continuation.yield(.resynchronise)
                                }
                            case .delete:
                                continuation.yield(.resynchronise)
                            }
                        }
                    }
                    group.addTask { for await _ in reactions { continuation.yield(.reactionsChanged) } }
                    group.addTask { for await _ in memories { continuation.yield(.memoriesChanged) } }
                    group.addTask { for await _ in dates { continuation.yield(.datesChanged) } }
                    group.addTask { for await _ in members { continuation.yield(.spaceChanged) } }
                    group.addTask { for await _ in spaces { continuation.yield(.spaceChanged) } }
                    group.addTask {
                        // After a dropped connection comes back, changes made in
                        // the gap were never delivered: tell the app to re-read.
                        var hasSubscribedBefore = false
                        for await state in status where state == .subscribed {
                            if hasSubscribedBefore { continuation.yield(.resynchronise) }
                            hasSubscribedBefore = true
                        }
                    }
                }
                await client.removeChannel(channel)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Media

extension SupabaseRepositories: MediaRepository {
    func upload(_ data: Data, to path: String, contentType: String) async throws {
        guard data.count <= MediaPath.maximumMediaBytes else { throw AppError.mediaTooLarge }
        do {
            try await client.storage.from(Self.mediaBucket).upload(
                path, data: data, options: FileOptions(cacheControl: "31536000", contentType: contentType, upsert: false)
            )
        } catch where SupabaseErrorMapper.isDuplicate(error) {
            // Files are write-once and paths are unique per attempt, so "already
            // exists" can only mean our own earlier try succeeded.
            return
        } catch {
            let mapped = SupabaseErrorMapper.map(error)
            throw mapped == .mediaUnreadable ? AppError.uploadFailed : mapped
        }
    }

    /// An authenticated download: the request carries the user's token and
    /// Storage checks the bucket's SELECT policy. No URL that could be copied
    /// or leaked is ever created.
    func download(path: String) async throws -> Data {
        try await run { try await client.storage.from(Self.mediaBucket).download(path: path) }
    }

    func downloadAvatar(path: String) async throws -> Data {
        try await run { try await client.storage.from(Self.avatarBucket).download(path: path) }
    }
}

// MARK: - Memories

extension SupabaseRepositories: MemoryRepository {
    func memories(coupleID: UUID, after cursor: MemoryCursor?, limit: Int) async throws -> [Memory] {
        try await run {
            var query = client.from("memories").select().eq("couple_id", value: coupleID)
            if let cursor {
                let day = cursor.occurredOn.description
                let id = cursor.id.uuidString.lowercased()
                query = query.or("occurred_on.lt.\(day),and(occurred_on.eq.\(day),id.lt.\(id))")
            }
            let rows: [MemoryRow] = try await query
                .order("occurred_on", ascending: false).order("id", ascending: false).limit(limit).execute().value
            return rows.map(\.model)
        }
    }

    func count(coupleID: UUID) async throws -> Int {
        try await run {
            try await client.from("memories").select("id", head: true, count: .exact)
                .eq("couple_id", value: coupleID).execute().count ?? 0
        }
    }

    func saveNote(noteID: UUID, caption: String) async throws -> UUID {
        try await run {
            try await client.rpc("save_note_to_memories", params: SaveNoteParams(p_note_id: noteID, p_caption: caption)).execute().value
        }
    }

    func add(_ moment: NewMoment, coupleID: UUID) async throws -> Memory {
        try await run {
            let insert = MemoryInsert(
                id: moment.id, couple_id: coupleID, created_by: try userID(), kind: moment.kind.rawValue,
                title: moment.title, caption: moment.caption, photo_path: moment.photoPath,
                drawing_path: moment.drawingPath, occurred_on: moment.occurredOn
            )
            let row: MemoryRow = try await client.from("memories").insert(insert).select().single().execute().value
            return row.model
        }
    }

    func update(id: UUID, title: String, caption: String, occurredOn: DayDate) async throws -> Memory {
        try await run {
            let row: MemoryRow = try await client.from("memories")
                .update(MemoryUpdate(title: title, caption: caption, occurred_on: occurredOn))
                .eq("id", value: id).select().single().execute().value
            return row.model
        }
    }

    func deleteMemory(id: UUID) async throws {
        try await run { _ = try await client.from("memories").delete().eq("id", value: id).execute() }
    }
}

// MARK: - Important dates

extension SupabaseRepositories: DatesRepository {
    func dates(coupleID: UUID) async throws -> [ImportantDate] {
        try await run {
            let rows: [ImportantDateRow] = try await client.from("important_dates").select()
                .eq("couple_id", value: coupleID).order("starts_on").execute().value
            return rows.map(\.model)
        }
    }

    func add(_ date: ImportantDate) async throws -> ImportantDate {
        try await run {
            let row: ImportantDateRow = try await client.from("important_dates")
                .insert(ImportantDateRow(date, createdBy: try userID())).select().single().execute().value
            return row.model
        }
    }

    func update(_ date: ImportantDate) async throws -> ImportantDate {
        try await run {
            let rows: [ImportantDateRow] = try await client.from("important_dates")
                .update(ImportantDateUpdate(date)).eq("id", value: date.id).select().execute().value
            // No row back means RLS hid it: it is private to the other person, or gone.
            guard let row = rows.first else { throw AppError.noteNotFound }
            return row.model
        }
    }

    func deleteDate(id: UUID) async throws {
        try await run { _ = try await client.from("important_dates").delete().eq("id", value: id).execute() }
    }
}

// MARK: - Scheduled messages

extension SupabaseRepositories: ScheduleRepository {
    private static let scheduledColumns =
        "id, couple_id, body, style, photo_path, drawing_path, deliver_at, time_zone, status, failure_reason, version, created_at"

    func scheduledMessages() async throws -> [ScheduledMessage] {
        try await run {
            let rows: [ScheduledRow] = try await client.from("scheduled_messages").select(Self.scheduledColumns)
                .order("deliver_at").limit(200).execute().value
            return rows.map(\.model)
        }
    }

    func schedule(id: UUID, coupleID: UUID, content: NoteContent, deliverAt: Date, timeZone: String) async throws -> ScheduledMessage {
        try InputRules.validate(content)
        let insert = ScheduledInsert(
            id: id, couple_id: coupleID, author_id: try userID(), body: content.body, style: content.style,
            photo_path: content.photoPath, drawing_path: content.drawingPath, deliver_at: deliverAt, time_zone: timeZone
        )
        do {
            let row: ScheduledRow = try await client.from("scheduled_messages").insert(insert)
                .select(Self.scheduledColumns).single().execute().value
            return row.model
        } catch where SupabaseErrorMapper.isDuplicate(error) {
            return try await run {
                let row: ScheduledRow = try await client.from("scheduled_messages").select(Self.scheduledColumns)
                    .eq("id", value: id).single().execute().value
                return row.model
            }
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func update(id: UUID, expectedVersion: Int, content: NoteContent, deliverAt: Date, timeZone: String) async throws -> ScheduledMessage {
        try InputRules.validate(content)
        return try await run {
            let row: ScheduledRow = try await client.rpc("update_scheduled_message", params: UpdateScheduledParams(
                p_id: id, p_expected_version: expectedVersion, p_body: content.body, p_style: content.style,
                p_photo_path: content.photoPath, p_drawing_path: content.drawingPath,
                p_deliver_at: deliverAt, p_time_zone: timeZone
            )).execute().value
            return row.model
        }
    }

    func cancel(id: UUID) async throws {
        try await run { _ = try await client.rpc("cancel_scheduled_message", params: IDParams(p_id: id)).execute() }
    }
}

// MARK: - Notifications

extension SupabaseRepositories: NotificationRepository {
    private static let preferenceColumns = "new_notes, surprises, important_dates, pairing, account, show_previews"

    func preferences() async throws -> NotificationPreferences {
        try await run {
            let row: PreferencesRow = try await client.from("notification_preferences").select(Self.preferenceColumns)
                .eq("user_id", value: try userID()).single().execute().value
            return row.model
        }
    }

    func update(_ preferences: NotificationPreferences) async throws {
        try await run {
            _ = try await client.from("notification_preferences").update(PreferencesRow(preferences))
                .eq("user_id", value: try userID()).execute()
        }
    }

    func registerDevice(token: String, environment: PushEnvironment) async throws {
        try await run {
            _ = try await client.rpc(
                "register_device_token", params: RegisterTokenParams(p_token: token, p_environment: environment.rawValue)
            ).execute()
        }
    }

    func unregisterDevice(token: String) async throws {
        try await run { _ = try await client.rpc("unregister_device_token", params: TokenParams(p_token: token)).execute() }
    }
}

// MARK: - Entitlement

extension SupabaseRepositories: EntitlementRepository {
    func entitlement() async throws -> Entitlement {
        try await run {
            let payload: EntitlementPayload = try await client.rpc("get_entitlement").execute().value
            return payload.model
        }
    }

    func submitTransaction(jws: String) async throws -> Entitlement {
        try await run {
            // The function verifies Apple's signature chain on the server and
            // only then records the subscription. This call cannot grant
            // anything by assertion.
            try await client.functions.invoke("verify-purchase", options: FunctionInvokeOptions(body: ["jws": jws]))
            let payload: EntitlementPayload = try await client.rpc("get_entitlement").execute().value
            return payload.model
        }
    }
}

extension ISO8601DateFormatter {
    /// Microsecond-free but fraction-aware, as PostgREST filters expect.
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
