import CoupleDesign
import SwiftUI
import UIKit

@main
struct CoupleNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .coupleTheme(app.session.space.space?.themeID ?? "paper", accentHex: app.session.space.space?.accentHex)
                .preferredColorScheme(app.settings.appearance.colorScheme)
                .task {
                    delegate.app = app
                    await app.start()
                }
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
    @MainActor weak var app: AppEnvironment?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await app?.notifications.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in app?.notifications.didFailToRegister(error) }
    }

    /// A background push says "something changed". The app fetches the latest
    /// note through its normal authorised path and republishes the widget.
    /// iOS throttles these; delivery is best-effort by design.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let app = await app else { return .noData }
        await app.refreshContent()
        await app.publishWidget()
        return .newData
    }
}
