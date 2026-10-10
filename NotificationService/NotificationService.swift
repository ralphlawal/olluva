import CoupleWidgetUI
import UserNotifications
import WidgetKit

/// Runs for every notification that arrives, whether or not the app is open,
/// in the background, or was closed from the app switcher.
///
/// It does one thing: fetch what the widget should now show and ask WidgetKit
/// to redraw. The notification itself is passed through unchanged. This is
/// what keeps the widget current without depending on the app being woken,
/// which iOS does not do reliably.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        deliver = contentHandler
        content = request.content

        let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? ""
        Task {
            if let store = WidgetSnapshotStore(appGroupID: groupID) {
                // Comfortably inside the roughly 30 seconds iOS allows.
                let outcome = await WidgetRemoteRefresher.refresh(store: store, source: .push, timeout: 15)
                if outcome == .updated || outcome == .revoked {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
            finish()
        }
    }

    /// iOS is about to cut the extension off: show the notification as it is.
    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func finish() {
        guard let deliver, let content else { return }
        self.deliver = nil
        deliver(content)
    }
}
