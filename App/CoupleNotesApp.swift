import CoupleDesign
import SwiftUI
import UIKit

@main
struct CoupleNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppEnvironment.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .coupleTheme(app.session.space.space?.themeID ?? "paper", accentHex: app.session.space.space?.accentHex)
                .preferredColorScheme(app.settings.appearance.colorScheme)
                .task { await app.start() }
                .onOpenURL { app.open($0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await app.sceneBecameActive() }
                    }
                }
        }
    }
}

/// UIKit is still the only way to receive the APNs device token and
/// background pushes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Start here, not from a view: when iOS launches the app in the
        // background for a push there is no view to do it.
        Task { @MainActor in await AppEnvironment.shared.start() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await AppEnvironment.shared.notifications.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in AppEnvironment.shared.notifications.didFailToRegister(error) }
    }

    /// A push says "something changed". The app fetches the latest note
    /// through its normal authorised path and republishes the widget.
    /// iOS throttles these wake-ups; delivery is best-effort by design.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await AppEnvironment.shared.handleBackgroundPush() ? .newData : .noData
    }
}
