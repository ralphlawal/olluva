import AuthenticationServices
import CoupleDesign
import CoupleDomain
import CryptoKit
import SwiftUI

// Screen: Welcome
// Purpose: say what this is in one glance and get someone to an account.
// Primary action: "Get started". Secondary: sign in.
// Layouts weighed: a paged carousel (too many taps before any value), a
// full-bleed animation (motion for its own sake), and a single composed page
// that shows the product itself. The last one is used: the three notes at the
// top are drawn by the real note renderer, so the first thing a person sees
// is exactly what they will be sending.

struct WelcomeFlow: View {
    enum Route: Hashable {
        case signUp
        case signIn
        case confirm(email: String)
        case reset(email: String)
    }

    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .signUp: SignUpView(path: $path)
                    case .signIn: SignInView(path: $path)
                    case .confirm(let email): ConfirmEmailView(email: email)
                    case .reset(let email): ResetPasswordView(email: email)
                    }
                }
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

            VStack(spacing: Space.xs) {
                Button("Get started") { path.append(.signUp) }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("welcome.getStarted")
                Button("I already have an account") { path.append(.signIn) }
                    .buttonStyle(.quiet)
                    .accessibilityIdentifier("welcome.signIn")
            }

            Button {
                showingPrivacy = true
            } label: {
                Label("Private to the two of you. How it works", systemImage: "lock")
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

/// What "private" actually means here, in plain words, before any account exists.
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
                        symbol: "person.2",
                        title: "Only you and your partner",
                        detail: "Each space has exactly two members. Our servers check who is asking on every request, so nobody outside your space can read what’s in it."
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
                        detail: "You can export what you’ve written or delete your account, and what you wrote with it, at any time from Settings."
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

struct PasswordField: View {
    @Environment(\.palette) private var palette
    let prompt: LocalizedStringKey
    @Binding var text: String
    var isNew = false
    var identifier = ""
    @State private var isRevealed = false

    /// The simulator's strong-password sheet swallows automated typing.
    private static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")

    var body: some View {
        HStack {
            Group {
                if isRevealed {
                    TextField(prompt, text: $text)
                } else {
                    SecureField(prompt, text: $text)
                }
            }
            .textContentType(isNew && !Self.isUITesting ? .newPassword : .password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(identifier)
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(palette.inkSecondary)
                    .frame(width: Size.touch, height: Size.touch)
            }
            .accessibilityLabel(isRevealed ? Text("Hide password") : Text("Show password"))
        }
    }
}

// MARK: - Sign up

struct SignUpView: View {
    private enum Field { case name, email, password }

    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Binding var path: [WelcomeFlow.Route]
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var action = ActionState()
    @State private var attempted = false
    @FocusState private var focus: Field?

    private var nameValid: Bool { InputRules.isValidDisplayName(name) }
    private var emailValid: Bool { InputRules.isValidEmail(email) }
    private var passwordValid: Bool { InputRules.isAcceptablePassword(password) }

    var body: some View {
        FormPage(title: "Let’s begin", subtitle: "Create your account. You’ll invite your partner next.") {
            VStack(spacing: Space.lg) {
                LabeledField(
                    "Your name", message: attempted && !nameValid ? "Tell us what your partner calls you." : nil,
                    isError: attempted && !nameValid
                ) {
                    TextField("Alex", text: $name)
                        .textContentType(.givenName)
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .email }
                        .accessibilityIdentifier("signUp.name")
                }
                LabeledField(
                    "Email", message: attempted && !emailValid ? "Enter a valid email address." : nil,
                    isError: attempted && !emailValid
                ) {
                    TextField("you@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("signUp.email")
                }
                LabeledField(
                    "Password", message: "At least 8 characters.", isError: attempted && !passwordValid
                ) {
                    PasswordField(prompt: "Choose a password", text: $password, isNew: true, identifier: "signUp.password")
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                }
            }
            .disabled(action.isRunning)

            if let error = action.error {
                NoticeBanner(error.message)
            }

            VStack(spacing: Space.md) {
                Button("Create account", action: submit)
                    .buttonStyle(.primary(isLoading: action.isRunning))
                    .disabled(action.isRunning)
                    .accessibilityIdentifier("signUp.submit")
                if !app.backend.isDemo {
                    AppleSignInButton(action: action)
                }
                Text("By continuing you agree to the Terms and Privacy Policy linked in Settings.")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear { focus = .name }
    }

    private func submit() {
        attempted = true
        guard nameValid, emailValid, passwordValid else {
            focus = !nameValid ? .name : !emailValid ? .email : .password
            return
        }
        focus = nil
        let address = email.trimmingCharacters(in: .whitespaces)
        action.run {
            let outcome = try await app.backend.auth.signUp(email: address, password: password, displayName: name)
            if outcome == .confirmationRequired {
                path.append(.confirm(email: address))
            }
        }
    }
}

// MARK: - Sign in

struct SignInView: View {
    private enum Field { case email, password }

    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Binding var path: [WelcomeFlow.Route]
    @State private var email = ""
    @State private var password = ""
    @State private var action = ActionState()
    @FocusState private var focus: Field?

    var body: some View {
        FormPage(title: "Welcome back", subtitle: nil) {
            if app.session.sessionEndedUnexpectedly {
                NoticeBanner("You were signed out. Sign in again to pick up where you left off.", tone: .info)
            }
            VStack(spacing: Space.lg) {
                LabeledField("Email") {
                    TextField("you@example.com", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("signIn.email")
                }
                LabeledField("Password") {
                    PasswordField(prompt: "Your password", text: $password, identifier: "signIn.password")
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                }
            }
            .disabled(action.isRunning)

            if let error = action.error {
                NoticeBanner(error.message)
            }

            VStack(spacing: Space.md) {
                Button("Sign in", action: submit)
                    .buttonStyle(.primary(isLoading: action.isRunning))
                    .disabled(action.isRunning || email.isEmpty || password.isEmpty)
                    .accessibilityIdentifier("signIn.submit")
                if !app.backend.isDemo {
                    AppleSignInButton(action: action)
                }
                Button("Forgot your password?") {
                    path.append(.reset(email: email.trimmingCharacters(in: .whitespaces)))
                }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("signIn.forgot")
            }
        }
        .onAppear { focus = .email }
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        focus = nil
        let address = email.trimmingCharacters(in: .whitespaces)
        action.run {
            do {
                try await app.backend.auth.signIn(email: address, password: password)
            } catch AppError.emailNotConfirmed {
                try? await app.backend.auth.resendConfirmation(email: address)
                path.append(.confirm(email: address))
            }
        }
    }
}

// MARK: - Email confirmation

struct ConfirmEmailView: View {
    @Environment(AppEnvironment.self) private var app
    let email: String
    @State private var code = ""
    @State private var action = ActionState()
    @State private var resent = false
    @FocusState private var focused: Bool

    var body: some View {
        FormPage(title: "Check your email", subtitle: "We sent a 6-digit code to \(email).") {
            LabeledField("Code") {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(Typo.code)
                    .focused($focused)
                    .onChange(of: code) { _, value in
                        code = String(value.filter(\.isNumber).prefix(6))
                    }
                    .accessibilityIdentifier("confirm.code")
            }
            .disabled(action.isRunning)

            if let error = action.error {
                NoticeBanner(error.message)
            } else if resent {
                NoticeBanner("A new code is on its way.", tone: .success)
            }

            VStack(spacing: Space.xs) {
                Button("Confirm") {
                    focused = false
                    action.run { try await app.backend.auth.confirmSignUp(email: email, code: code) }
                }
                .buttonStyle(.primary(isLoading: action.isRunning))
                .disabled(code.count < 6 || action.isRunning)
                .accessibilityIdentifier("confirm.submit")

                Button("Send a new code") {
                    action.run({ try await app.backend.auth.resendConfirmation(email: email) }, onSuccess: { resent = true })
                }
                .buttonStyle(.quiet)
                .disabled(action.isRunning)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Password recovery

struct ResetPasswordView: View {
    private enum Step { case request, complete }

    @Environment(AppEnvironment.self) private var app
    @State var email: String
    @State private var step = Step.request
    @State private var code = ""
    @State private var password = ""
    @State private var action = ActionState()
    @FocusState private var focused: Bool

    var body: some View {
        FormPage(
            title: "Reset your password",
            subtitle: step == .request
                ? "Enter your email and we’ll send you a code."
                : "If there’s an account for \(email), a code is on its way. Enter it with your new password."
        ) {
            VStack(spacing: Space.lg) {
                if step == .request {
                    LabeledField("Email") {
                        TextField("you@example.com", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .accessibilityIdentifier("reset.email")
                    }
                } else {
                    LabeledField("Code") {
                        TextField("123456", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(Typo.code)
                            .focused($focused)
                            .onChange(of: code) { _, value in
                                code = String(value.filter(\.isNumber).prefix(6))
                            }
                            .accessibilityIdentifier("reset.code")
                    }
                    LabeledField("New password", message: "At least 8 characters.") {
                        PasswordField(prompt: "Choose a new password", text: $password, isNew: true, identifier: "reset.password")
                    }
                }
            }
            .disabled(action.isRunning)

            if let error = action.error {
                NoticeBanner(error.message)
            }

            if step == .request {
                Button("Send code") {
                    action.run({ try await app.backend.auth.requestPasswordReset(email: email) }, onSuccess: {
                        step = .complete
                        focused = true
                    })
                }
                .buttonStyle(.primary(isLoading: action.isRunning))
                .disabled(!InputRules.isValidEmail(email) || action.isRunning)
                .accessibilityIdentifier("reset.send")
            } else {
                Button("Save and sign in") {
                    focused = false
                    action.run { try await app.backend.auth.resetPassword(email: email, code: code, newPassword: password) }
                }
                .buttonStyle(.primary(isLoading: action.isRunning))
                .disabled(code.count < 6 || !InputRules.isAcceptablePassword(password) || action.isRunning)
                .accessibilityIdentifier("reset.submit")
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Sign in with Apple

/// Apple's own button, wired to Supabase's ID-token sign-in. A random nonce is
/// sent to Apple hashed and to the server in the clear, which ties the token
/// Apple returns to this one request.
struct AppleSignInButton: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.colorScheme) private var scheme
    let action: ActionState
    @State private var nonce = ""

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            nonce = Self.randomNonce()
            request.requestedScopes = [.fullName, .email]
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
                let name = credential.fullName.flatMap { PersonNameComponentsFormatter().string(from: $0) }
                action.run {
                    try await app.backend.auth.signInWithApple(idToken: token, nonce: nonce, displayName: name)
                }
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
