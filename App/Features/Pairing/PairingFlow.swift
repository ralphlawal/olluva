import CoreImage.CIFilterBuiltins
import CoupleDesign
import CoupleDomain
import Security
import SwiftUI

// Screen group: Pairing
// Purpose: get two specific people into one private space, and nobody else.
// Primary action: share your invitation, or accept your partner's.
// Layouts weighed: one long page holding both the code to share and the field
// to enter one (two jobs competing for one screen); a segmented switcher
// (hides half the feature behind a control); and a short chooser leading to
// two focused screens. The chooser is used: each person does exactly one of
// the two things, so each gets a screen about only that.

struct PairingFlow: View {
    enum Route: Hashable {
        case invite
        case join(code: String)
    }

    @Environment(AppEnvironment.self) private var app
    @State private var path: [Route] = []
    @State private var showingAccount = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if app.session.needsDisplayName {
                    NameStepView()
                } else {
                    PairingHomeView(path: $path, showingAccount: $showingAccount)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .invite: InviteView()
                case .join(let code): JoinView(initialCode: code)
                }
            }
        }
        .sheet(isPresented: $showingAccount) { SettingsView(isSheet: true) }
        .onChange(of: app.router.pendingInviteCode, initial: true) { _, code in
            // An invitation link was opened: go straight to it.
            guard let code, !app.session.needsDisplayName else { return }
            app.router.pendingInviteCode = nil
            path = [.join(code: code)]
        }
    }
}

struct PairingHomeView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Binding var path: [PairingFlow.Route]
    @Binding var showingAccount: Bool

    private var isWaiting: Bool {
        if case .waiting = app.session.space { true } else { false }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Hello, \(app.session.profile?.displayName ?? "")")
                        .overlineStyle(palette)
                    Text("Find each other")
                        .font(Typo.display)
                        .foregroundStyle(palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your space is for two. One of you sends an invitation and the other accepts it.")
                        .font(Typo.body)
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    PairingOptionRow(
                        symbol: "paperplane",
                        title: isWaiting ? "Your invitation" : "Invite my partner",
                        detail: isWaiting ? "Waiting for your partner to accept." : "Get a private code or link to send them."
                    ) { path.append(.invite) }
                        .accessibilityIdentifier("pairing.invite")
                    Hairline()
                    PairingOptionRow(
                        symbol: "envelope.open",
                        title: "I have an invitation",
                        detail: "Enter the code your partner sent you."
                    ) { path.append(.join(code: "")) }
                        .accessibilityIdentifier("pairing.join")
                }

                Label("Invitations work once, for one person, and expire after two days.", systemImage: "lock")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.lg)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .pageBackground(palette)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAccount = true
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel(Text("Account"))
                .accessibilityIdentifier("pairing.account")
            }
        }
        .refreshable { await app.session.refresh() }
    }
}

struct PairingOptionRow: View {
    @Environment(\.palette) private var palette
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: symbol)
                    .font(.system(size: Size.iconFeature * 0.8, weight: .regular))
                    .foregroundStyle(palette.accent)
                    .frame(width: 52, height: 52)
                    .background(palette.sunken, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(Typo.heading).foregroundStyle(palette.ink)
                    Text(detail).font(Typo.callout).foregroundStyle(palette.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown when an account has no name yet (Sign in with Apple may not share one).
struct NameStepView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var name = ""
    @State private var action = ActionState()
    @FocusState private var focused: Bool

    var body: some View {
        FormPage(title: "What should we call you?", subtitle: "This is the name your partner will see.") {
            LabeledField("Your name") {
                TextField("Alex", text: $name)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityIdentifier("name.field")
            }
            if let error = action.error { NoticeBanner(error.message) }
            Button("Continue", action: save)
                .buttonStyle(.primary(isLoading: action.isRunning))
                .disabled(!InputRules.isValidDisplayName(name) || action.isRunning)
                .accessibilityIdentifier("name.submit")
        }
        .onAppear { focused = true }
    }

    private func save() {
        guard InputRules.isValidDisplayName(name) else { return }
        action.run {
            let profile = try await app.backend.profiles.updateProfile(displayName: name, timeZone: TimeZone.current.identifier)
            app.session.setProfile(profile)
        }
    }
}

// MARK: - Invite

struct InviteView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var invitation: IssuedInvitation?
    @State private var load: LoadState = .loading
    @State private var action = ActionState()
    @State private var confirmingNewCode = false
    @State private var toast: LocalizedStringKey?

    var body: some View {
        ScrollView {
            VStack(spacing: Space.lg) {
                VStack(spacing: Space.xs) {
                    Text("Your invitation")
                        .font(Typo.title)
                        .foregroundStyle(palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Send this to your partner, and only your partner. Whoever accepts it shares your space.")
                        .font(Typo.callout)
                        .foregroundStyle(palette.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch load {
                case .loading, .idle:
                    SkeletonBlock(cornerRadius: Radius.card).frame(height: 330)
                case .failed(let error):
                    NoticeBanner(error.message, actionTitle: "Try again") { Task { await prepare(forceNew: false) } }
                case .loaded:
                    if let invitation { content(invitation) }
                }

                if let error = action.error { NoticeBanner(error.message) }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .pageBackground(palette)
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
        .task { await prepare(forceNew: false) }
        .confirmationDialog("Get a new code?", isPresented: $confirmingNewCode, titleVisibility: .visible) {
            Button("Get a new code") { Task { await prepare(forceNew: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The code you’ve already shared will stop working.")
        }
    }

    @ViewBuilder
    private func content(_ invitation: IssuedInvitation) -> some View {
        let link = InviteCode.link(for: invitation.code)
        VStack(spacing: Space.lg) {
            VStack(spacing: Space.md) {
                QRCodeView(text: link.absoluteString)
                    .frame(width: 168, height: 168)
                    .accessibilityLabel(Text("QR code for your invitation"))

                Button {
                    UIPasteboard.general.setItems(
                        [[UIPasteboard.typeAutomatic: InviteCode.display(invitation.code)]],
                        // Do not leave an invitation sitting on the clipboard.
                        options: [.expirationDate: Date().addingTimeInterval(120), .localOnly: true]
                    )
                    Haptics.tap()
                    toast = "Code copied"
                } label: {
                    HStack(spacing: Space.xs) {
                        Text(InviteCode.display(invitation.code))
                            .font(Typo.code)
                            .foregroundStyle(palette.ink)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: Size.iconInline))
                            .foregroundStyle(palette.inkSecondary)
                    }
                    .frame(minHeight: Size.touch)
                }
                .accessibilityLabel(Text("Invitation code \(InviteCode.display(invitation.code).map(String.init).joined(separator: " "))"))
                .accessibilityHint(Text("Copies the code"))
                .accessibilityIdentifier("invite.code")

                Text("Expires \(invitation.expiresAt, format: .relative(presentation: .named))")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .softShadow(palette)

            ShareLink(
                item: link,
                subject: Text("Join me on \(app.configuration.displayName)"),
                message: Text("Join me on \(app.configuration.displayName). Open this link, or enter the code \(InviteCode.display(invitation.code)).")
            ) {
                Label("Share invitation", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("invite.share")

            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.small)
                Text("Waiting for your partner. This screen moves on by itself.")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
            }
            .accessibilityElement(children: .combine)

            Button("Get a new code") { confirmingNewCode = true }
                .buttonStyle(.quiet)
                .disabled(action.isRunning)
                .accessibilityIdentifier("invite.newCode")

            #if DEBUG
            if let demo = app.demo {
                Button("Demo: have Sam accept this") {
                    Task {
                        await demo.simulatePartnerJoining(code: invitation.code)
                        await app.session.refresh()
                    }
                }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("invite.demoAccept")
            }
            #endif
        }
    }

    /// Makes sure there is a space and a live code to show. A code that was
    /// issued earlier and is still valid is reused, so reopening this screen
    /// never invalidates the one a partner already has.
    private func prepare(forceNew: Bool) async {
        load = .loading
        do {
            if case .none = app.session.space {
                try await app.backend.couples.createSpace()
                await app.session.refresh()
            }
            if !forceNew, let saved = InvitationKeychain.load(for: app.session.coupleID), saved.expiresAt > Date().addingTimeInterval(60) {
                invitation = saved
            } else {
                let issued = try await app.backend.couples.createInvitation()
                InvitationKeychain.save(issued, for: app.session.coupleID)
                invitation = issued
            }
            load = .loaded
        } catch {
            let failure = appError(from: error)
            if failure == .alreadyPaired || failure == .alreadyInSpace {
                await app.session.refresh()
            }
            load = .failed(failure)
        }
    }
}

struct QRCodeView: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        if let image = Self.generate(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(Space.sm)
                // A QR code needs a light quiet zone to scan, in either appearance.
                .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
    }

    private static func generate(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

// MARK: - Join

struct JoinView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let initialCode: String
    @State private var code = ""
    @State private var preview: InvitationPreview?
    @State private var action = ActionState()
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let preview {
                confirmation(preview)
            } else {
                entry
            }
        }
        .animation(Motion.standard, value: preview)
        .task {
            // Runs once for the screen, not once per step within it.
            guard code.isEmpty else { return }
            code = InviteCode.display(initialCode)
            if InviteCode.isComplete(code) { lookUp() } else { focused = true }
        }
    }

    private var entry: some View {
        FormPage(title: "Enter your invitation", subtitle: "It’s the 10-character code your partner sent you.") {
            LabeledField("Invitation code") {
                TextField("ABCDE-FGHJK", text: $code)
                    .font(Typo.code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(lookUp)
                    // The text is left exactly as typed or pasted (dashes, spaces,
                    // lower case are all accepted and ignored). Rewriting it on
                    // every keystroke loses characters when someone types quickly.
                    .onChange(of: code) { _, value in
                        if value.count > 24 { code = String(value.prefix(24)) }
                    }
                    .accessibilityIdentifier("join.code")
            }
            .disabled(action.isRunning)

            if let error = action.error { NoticeBanner(error.message) }

            Button("Continue", action: lookUp)
                .buttonStyle(.primary(isLoading: action.isRunning))
                .disabled(!InviteCode.isComplete(code) || action.isRunning)
                .accessibilityIdentifier("join.continue")
        }
    }

    /// The accept-or-decline step: the person sees who they are about to share
    /// a space with before anything is joined.
    private func confirmation(_ preview: InvitationPreview) -> some View {
        VStack(spacing: Space.lg) {
            Spacer()
            AvatarView(initial: preview.inviterName.first.map { String($0).uppercased() } ?? "·", size: 96)
            VStack(spacing: Space.xs) {
                Text("Share a space with \(preview.inviterName)?")
                    .font(Typo.title)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("You’ll be able to send each other notes, and see everything in the space you share. You can leave at any time.")
                    .font(Typo.callout)
                    .foregroundStyle(palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = action.error { NoticeBanner(error.message) }
            Spacer()
            VStack(spacing: Space.xs) {
                Button("Accept") {
                    action.run {
                        do {
                            try await app.backend.couples.acceptInvitation(code: code)
                        } catch AppError.alreadyPaired {
                            // Both partners accepted each other's codes at once:
                            // the other request won and we are already together.
                        }
                        Haptics.success()
                        await app.session.refresh()
                    }
                }
                .buttonStyle(.primary(isLoading: action.isRunning))
                .accessibilityIdentifier("join.accept")

                Button("This isn’t my partner") {
                    action.run({ try await app.backend.couples.declineInvitation(code: code) }, onSuccess: { dismiss() })
                }
                .buttonStyle(.quietDestructive)
                .accessibilityIdentifier("join.decline")
            }
            .disabled(action.isRunning)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.md)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .pageBackground(palette)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func lookUp() {
        guard InviteCode.isComplete(code) else { return }
        focused = false
        action.run {
            preview = try await app.backend.couples.previewInvitation(code: code)
        }
    }
}

// MARK: - Invitation storage

/// Keeps the plaintext of an issued invitation in the Keychain until it is
/// used or expires. The server only has its hash, so this is the one place it
/// can be shown again from.
enum InvitationKeychain {
    private static let service = "invitation"

    private struct Stored: Codable {
        let id: UUID
        let code: String
        let expiresAt: Date
    }

    private static func query(_ coupleID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: coupleID.uuidString,
        ]
    }

    static func save(_ invitation: IssuedInvitation, for coupleID: UUID?) {
        guard let coupleID,
              let data = try? JSONEncoder().encode(Stored(id: invitation.id, code: invitation.code, expiresAt: invitation.expiresAt))
        else { return }
        SecItemDelete(query(coupleID) as CFDictionary)
        var attributes = query(coupleID)
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(for coupleID: UUID?) -> IssuedInvitation? {
        guard let coupleID else { return nil }
        var request = query(coupleID)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return IssuedInvitation(id: stored.id, code: stored.code, expiresAt: stored.expiresAt)
    }

    static func removeAll() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}
