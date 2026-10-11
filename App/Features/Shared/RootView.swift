import CoupleDesign
import CoupleDomain
import SwiftUI

/// Chooses the top-level experience from the session's phase.
struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            palette.canvas.ignoresSafeArea()
            switch app.session.phase {
            case .launching:
                SplashView()
            case .notConfigured:
                NotConfiguredView()
            case .signedOut:
                WelcomeFlow()
            case .loadFailed(let error):
                LoadFailureView(error.message) {
                    Task { await app.session.retryInitialLoad() }
                }
            case .unpaired:
                PairingFlow()
            case .paired:
                MainView()
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.gentle, value: app.session.phase)
    }
}

/// The in-app half of the launch experience. It draws the app icon exactly
/// where the system launch screen drew it, on the same colour, so the two are
/// indistinguishable and nothing moves or flashes while the session loads.
struct SplashView: View {
    var body: some View {
        Image("LaunchIcon")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .accessibilityLabel(Text("Loading"))
    }
}

/// Two sheets of paper, one resting on the other.
struct BrandMark: View {
    @Environment(\.palette) private var palette
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(Color(hex: "#B7A8D8"))
                .frame(width: size * 0.72, height: size * 0.72)
                .rotationEffect(.degrees(9))
                .offset(x: size * 0.08, y: -size * 0.04)
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(Color(hex: "#FFF9EC"))
                .frame(width: size * 0.72, height: size * 0.72)
                .rotationEffect(.degrees(-6))
                .offset(x: -size * 0.05, y: size * 0.05)
                .shadow(color: .black.opacity(0.12), radius: size * 0.05, y: size * 0.03)
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.2))
                .foregroundStyle(Color(hex: "#C9566B"))
                .rotationEffect(.degrees(-6))
                .offset(x: -size * 0.05, y: size * 0.05)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Shown by a release build that was compiled without backend settings.
/// It says exactly that; it does not fall back to anything simulated.
struct NotConfiguredView: View {
    var body: some View {
        EmptyStateView(
            symbol: "server.rack",
            title: "Not connected to a server",
            message: "This build has no backend configured. Add your Supabase host and key to Config/Secrets.xcconfig and build again."
        )
    }
}

/// Loads a note's media through the authorised store and renders the card.
struct LoadedNoteCard: View {
    @Environment(AppEnvironment.self) private var app
    let content: NoteContent
    var maxPixel = 1400

    @State private var photo: CGImage?
    @State private var drawing: CGImage?

    var body: some View {
        NoteCardView(content: content, photo: photo, drawing: drawing)
            .task(id: content.photoPath) {
                photo = await app.media.image(path: content.photoPath, maxPixel: maxPixel)
            }
            .task(id: content.drawingPath) {
                drawing = await app.media.image(path: content.drawingPath, maxPixel: maxPixel)
            }
    }
}

/// A person's avatar, loaded from private storage when they have one.
struct ProfileAvatar: View {
    @Environment(AppEnvironment.self) private var app
    let profile: Profile?
    var size: CGFloat = 44

    @State private var image: CGImage?

    var body: some View {
        AvatarView(initial: profile?.initial ?? "·", image: image, size: size)
            .task(id: "\(profile?.avatarPath ?? "")#\(profile?.avatarVersion ?? 0)") {
                image = await app.media.image(path: profile?.avatarPath, maxPixel: 400, version: profile?.avatarVersion ?? 0)
            }
    }
}

/// Presents a short-lived confirmation over whatever is on screen.
struct ToastModifier: ViewModifier {
    @Binding var message: LocalizedStringKey?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Low on the screen, clear of titles and of the tab bar.
        content.overlay(alignment: .bottom) {
            if let message {
                ToastView(message)
                    .padding(.bottom, 104)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation(Motion.standard) { self.message = nil }
                    }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(Motion.standard, value: message == nil)
    }
}

extension View {
    func toast(_ message: Binding<LocalizedStringKey?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

/// Runs an async action from a button, tracking progress and surfacing any
/// failure as an `AppError` for the screen to show inline.
@MainActor
@Observable
final class ActionState {
    private(set) var isRunning = false
    var error: AppError?

    func run(_ action: @escaping () async throws -> Void, onSuccess: (() -> Void)? = nil) {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        Task {
            do {
                try await action()
                isRunning = false
                onSuccess?()
            } catch {
                self.error = appError(from: error)
                isRunning = false
                Haptics.warning()
            }
        }
    }
}
