import AuthenticationServices
import CoupleDesign
import CoupleDomain
import CryptoKit
import SwiftUI

// Screen: Welcome
// Purpose: say what this is in one glance and let someone start immediately.
// Primary action: "Get started". There is no sign-up: tapping it creates a
// private identity on this phone and moves straight on. The only other path is
// for someone who already has a space and is on a new phone.
// Layouts weighed: a paged carousel (too many taps before any value), a
// full-bleed animation (motion for its own sake), and a single composed page
// that shows the product itself. The last one is used: the three notes at the
// top are drawn by the real note renderer, so the first thing a person sees
// is exactly what they will be sending.

struct WelcomeFlow: View {
    enum Route: Hashable {
        case restore
    }

    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(path: $path)
                .navigationDestination(for: Route.self) { _ in RestoreView() }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var path: [WelcomeFlow.Route]
    @State private var arrived = false
    @State private var showingPrivacy = false
    @State private var action = ActionState()

    private static let samples: [NoteContent] = [
        NoteContent(
            body: "Dinner at ours tonight?",
            style: NoteStyle(paper: "lilac", ink: "plum", typeface: .serif)
        ),
        NoteContent(
            body: "Good luck today.\nYou’ve got this.",
            style: NoteStyle(
                paper: "blush", ink: "rose", typeface: .hand,
                stickers: [StickerPlacement(sticker: "star", x: 0.82, y: 0.18, scale: 1, rotation: 12)]
            )
        ),
        NoteContent(
            body: "Thinking of you",
            style: NoteStyle(
                paper: "cream", ink: "plum", typeface: .hand,
                stickers: [StickerPlacement(sticker: "heart", x: 0.8, y: 0.82, scale: 0.9, rotation: -10)]
            )
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !typeSize.isAccessibilitySize {
                noteFan
                    .frame(maxHeight: .infinity)
                    .padding(.top, Space.lg)
            } else {
                Spacer(minLength: Space.lg)
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Make your favourite person part of your everyday.")
                    .font(Typo.display)
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Leave each other notes, drawings and photos that show up right on your Home Screen.")
                    .font(Typo.body)
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Space.lg)

            if app.session.sessionEndedUnexpectedly {
                NoticeBanner("You were signed out on this phone. If you backed up your space, you can restore it.", tone: .info)
                    .padding(.bottom, Space.sm)
            }
            if let error = action.error {
                NoticeBanner(error.message, actionTitle: error.isRetryable ? "Try again" : nil, action: start)
                    .padding(.bottom, Space.sm)
            }

            VStack(spacing: Space.xs) {
                Button("Get started", action: start)
                    .buttonStyle(.primary(isLoading: action.isRunning))
                    .disabled(action.isRunning)
                    .accessibilityIdentifier("welcome.getStarted")
                Button("I already have a space") { path.append(.restore) }
                    .buttonStyle(.quiet)
                    .disabled(action.isRunning)
                    .accessibilityIdentifier("welcome.restore")
            }

            Button {
                showingPrivacy = true
            } label: {
                Label("No account needed. How your notes stay private", systemImage: "lock")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
            }
            .frame(minHeight: Size.touch)
            .accessibilityIdentifier("welcome.privacy")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.xs)
        .pageBackground(palette)
        .sheet(isPresented: $showingPrivacy) { PrivacyExplainerSheet() }
        .onAppear {
            app.settings.hasSeenWelcome = true
            withAnimation(reduceMotion ? Motion.fade : Motion.gentle.delay(0.1)) { arrived = true }
        }
    }

    /// No form, no email: a private identity is created for this phone and
    /// kept in its Keychain. The session store picks it up and moves on.
    private func start() {
        action.run { try await app.backend.auth.startAnonymously() }
    }

    private var noteFan: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width * 0.56, proxy.size.height * 0.62)
            let spread: [(x: CGFloat, y: CGFloat, tilt: Double)] = [(-0.36, -0.2, -9), (0.36, -0.26, 8), (0, 0.14, -2)]
            ZStack {
                ForEach(Array(Self.samples.enumerated()), id: \.offset) { index, sample in
                    let place = spread[index]
                    NoteCardView(content: sample, dimsInDarkMode: true)
                        .frame(width: side, height: side)
                        .paperShadow(palette, lifted: index == 2)
                        .rotationEffect(.degrees(arrived || reduceMotion ? place.tilt : 0))
                        .offset(
                            x: arrived || reduceMotion ? place.x * side : 0,
                            y: arrived || reduceMotion ? place.y * side : 0
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .opacity(arrived ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Three example notes"))
    }
}

/// For someone on a new phone who backed their space up with their Apple ID.
struct RestoreView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var action = ActionState()

    var body: some View {
        FormPage(
            title: "Restore your space",
            subtitle: "If you backed up with your Apple ID on your old phone, sign in with it here and everything comes back."
        ) {
            VStack(alignment: .leading, spacing: Space.md) {
                ConsequenceRow(symbol: "checkmark.circle", text: "Your partner, notes and memories return exactly as they were.")
                ConsequenceRow(symbol: "questionmark.circle", text: "If you never backed up, there’s nothing to restore. Go back and tap Get started, then ask your partner for a new invitation.")
            }

            if let error = action.error { NoticeBanner(error.message) }

            AppleIDButton(label: .signIn, action: action) { token, nonce in
                try await app.backend.auth.restoreWithApple(idToken: token, nonce: nonce)
            }
            .disabled(action.isRunning)

            #if DEBUG
            if app.demo != nil {
                Button("Demo: restore the backed-up space") {
                    action.run { try await app.backend.auth.restoreWithApple(idToken: DemoController.appleID, nonce: "demo") }
                }
                .buttonStyle(.quiet)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("restore.demo")
            }
            #endif
        }
    }
}

/// What "private" actually means here, in plain words, before anything is created.
struct PrivacyExplainerSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Your notes are for two people.")
                        .font(Typo.title)
                        .foregroundStyle(palette.ink)
                    PrivacyPoint(
                        symbol: "person.crop.circle.badge.checkmark",
                        title: "No account, no email",
                        detail: "You don’t sign up. Your phone holds a private key to your space. We never ask for your email, phone number or contacts."
                    )
                    PrivacyPoint(
                        symbol: "person.2",
                        title: "Only you and your partner",
                        detail: "Each space has exactly two members. Our servers check who is asking on every request, so nobody outside your space can read what’s in it."
                    )
                    PrivacyPoint(
                        symbol: "icloud.and.arrow.up",
                        title: "Back up if you want to",
                        detail: "Because there’s no account, losing this phone would mean losing your space. You can attach your Apple ID as a backup so you can restore it on a new phone."
                    )
                    PrivacyPoint(
                        symbol: "lock.rectangle",
                        title: "Protected in transit and at rest",
                        detail: "Everything travels over an encrypted connection and is stored encrypted. Notes are not end-to-end encrypted, which is what lets them reach your widgets and arrive on a schedule."
                    )
                    PrivacyPoint(
                        symbol: "eye.slash",
                        title: "Quiet by default",
                        detail: "Notifications and Lock Screen widgets don’t show what a note says unless you choose to turn that on."
                    )
                    PrivacyPoint(
                        symbol: "trash",
                        title: "Yours to take or remove",
                        detail: "You can export what you’ve written or delete everything, at any time, from Settings."
                    )
                }
                .padding(Space.gutter)
            }
            .pageBackground(palette)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PrivacyPoint: View {
    @Environment(\.palette) private var palette
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: Size.iconControl, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Typo.bodyStrong).foregroundStyle(palette.ink)
                Text(detail).font(Typo.callout).foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Form scaffold

/// The shared shape of the account screens: a serif title, a line of context,
/// the fields, then the action — in a scroll view that yields to the keyboard.
struct FormPage<Content: View>: View {
    @Environment(\.palette) private var palette
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title)
                        .font(Typo.title)
                        .foregroundStyle(palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typo.body)
                            .foregroundStyle(palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .pageBackground(palette)
        .navigationBarTitleDisplayMode(.inline)
        // Content must not show through behind the clock when it scrolls.
        .toolbarBackground(palette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - Sign in with Apple

/// Apple's own button. Used only to back a space up and to restore one; it
/// requests no name and no email. A random nonce is sent to Apple hashed and
/// to the server in the clear, which ties the token to this one request.
struct AppleIDButton: View {
    @Environment(\.colorScheme) private var scheme
    let label: SignInWithAppleButton.Label
    let action: ActionState
    let onToken: (_ idToken: String, _ nonce: String) async throws -> Void
    @State private var nonce = ""

    var body: some View {
        SignInWithAppleButton(label) { request in
            nonce = Self.randomNonce()
            request.requestedScopes = []
            request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let tokenData = credential.identityToken,
                      let token = String(data: tokenData, encoding: .utf8)
                else {
                    action.error = .appleSignInUnavailable
                    return
                }
                let usedNonce = nonce
                action.run { try await onToken(token, usedNonce) }
            case .failure(let error):
                // Dismissing the sheet is a choice, not a failure.
                if (error as? ASAuthorizationError)?.code != .canceled {
                    action.error = .appleSignInUnavailable
                }
            }
        }
        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
        .frame(height: Size.button)
        .clipShape(Capsule())
        .accessibilityIdentifier("auth.apple")
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
