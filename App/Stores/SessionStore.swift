import CoupleDomain
import Foundation
import Observation

/// Who is signed in, who they are paired with, and what they are entitled to.
/// The root view switches on `phase`; everything else reads from here.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case launching
        case notConfigured
        case signedOut
        /// Signed in, but the first load of the account failed.
        case loadFailed(AppError)
        case unpaired
        case paired
    }

    private(set) var phase: Phase = .launching
    private(set) var userID: UUID?
    private(set) var email: String?
    private(set) var profile: Profile?
    private(set) var space: SpaceState = .none
    private(set) var serverEntitlement: Entitlement = .free
    /// Set when the server ends the session, so the sign-in screen can explain.
    var sessionEndedUnexpectedly = false

    /// Called after the account's data has been cleared from this device.
    var onSignedOut: (() async -> Void)?
    /// Called whenever profile, space or entitlement has been re-read.
    var onRefreshed: (() -> Void)?

    private let backend: Backend
    private var authTask: Task<Void, Never>?
    private var userInitiatedSignOut = false

    init(backend: Backend) {
        self.backend = backend
    }

    var partner: Profile? { space.partner }
    var coupleID: UUID? { space.space?.id }
    var needsDisplayName: Bool { profile.map { !InputRules.isValidDisplayName($0.displayName) } ?? false }

    // MARK: - Lifecycle

    func start(isMissingBackend: Bool) async {
        guard authTask == nil else { return }
        if isMissingBackend {
            phase = .notConfigured
            return
        }
        let stream = backend.auth.stateChanges()
        authTask = Task { [weak self] in
            for await state in stream {
                await self?.apply(state)
            }
        }
        await apply(await backend.auth.restoreSession())
    }

    private func apply(_ state: AuthState) async {
        switch state {
        case .signedIn(let id, let address):
            email = address
            guard userID != id else { return }
            userID = id
            sessionEndedUnexpectedly = false
            await refresh(isInitial: true)
        case .signedOut:
            guard userID != nil || phase == .launching else { return }
            let wasSignedIn = userID != nil
            sessionEndedUnexpectedly = wasSignedIn && !userInitiatedSignOut
            userInitiatedSignOut = false
            clear()
            phase = .signedOut
            if wasSignedIn { await onSignedOut?() }
        }
    }

    private func clear() {
        userID = nil
        email = nil
        profile = nil
        space = .none
        serverEntitlement = .free
    }

    /// Re-reads profile, space and entitlement. A failure during the first
    /// load is shown; a failure while refreshing keeps what is on screen.
    func refresh(isInitial: Bool = false) async {
        guard userID != nil else { return }
        do {
            async let profile = backend.profiles.myProfile()
            async let space = backend.couples.spaceState()
            let (loadedProfile, loadedSpace) = try await (profile, space)
            self.profile = loadedProfile
            self.space = loadedSpace
            phase = loadedSpace.partner == nil ? .unpaired : .paired
            await refreshEntitlement()
            await syncTimeZone()
            onRefreshed?()
        } catch {
            let failure = appError(from: error)
            Diagnostics.failure(Diagnostics.session, "refresh", failure)
            if failure == .sessionExpired {
                await apply(.signedOut)
            } else if isInitial || phase == .launching {
                phase = .loadFailed(failure)
            }
        }
    }

    func retryInitialLoad() async {
        phase = .launching
        await refresh(isInitial: true)
    }

    func refreshEntitlement() async {
        guard userID != nil else { return }
        if let entitlement = try? await backend.entitlements.entitlement() {
            serverEntitlement = entitlement
        }
    }

    func setServerEntitlement(_ entitlement: Entitlement) {
        serverEntitlement = entitlement
    }

    /// Reminders are sent at 09:00 in the recipient's zone, so the server
    /// needs to know when that zone changes.
    private func syncTimeZone() async {
        let zone = TimeZone.current.identifier
        guard let profile, profile.timeZone != zone else { return }
        if let updated = try? await backend.profiles.updateProfile(displayName: nil, timeZone: zone) {
            self.profile = updated
        }
    }

    // MARK: - Account actions

    func setProfile(_ profile: Profile) {
        self.profile = profile
    }

    func signOut(unregisterToken: (() async -> Void)? = nil) async throws {
        userInitiatedSignOut = true
        await unregisterToken?()
        do {
            try await backend.auth.signOut()
        } catch {
            userInitiatedSignOut = false
            throw appError(from: error)
        }
        await apply(.signedOut)
    }

    func deleteAccount() async throws {
        userInitiatedSignOut = true
        do {
            try await backend.auth.deleteAccount()
        } catch {
            userInitiatedSignOut = false
            throw appError(from: error)
        }
        await apply(.signedOut)
    }

    func leaveSpace(blockPartner: Bool) async throws {
        do {
            try await backend.couples.leaveSpace(blockPartner: blockPartner)
        } catch {
            throw appError(from: error)
        }
        await refresh()
    }
}
