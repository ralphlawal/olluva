import CoupleDomain
import CoupleWidgetUI
import Foundation
import Observation
import UIKit
import UserNotifications

/// Notification permission, device-token registration, per-category
/// preferences, and what happens when a notification is tapped.
@MainActor
@Observable
final class NotificationCoordinator: NSObject {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var preferences: NotificationPreferences?
    private(set) var preferencesState: LoadState = .idle

    var onOpen: ((DeepLink) -> Void)?
    /// A push arrived while the app was running or in the background.
    var onRemoteChange: (() async -> Void)?

    private let backend: Backend
    private let environment: PushEnvironment
    private let defaults: UserDefaults
    private let isEnabled: Bool

    init(backend: Backend, environment: PushEnvironment, defaults: UserDefaults = .standard, isEnabled: Bool = true) {
        self.backend = backend
        self.environment = environment
        self.defaults = defaults
        self.isEnabled = isEnabled
        super.init()
    }

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if isAuthorized { registerForRemoteNotifications() }
    }

    /// Shows the system prompt. Only ever called from a screen that has just
    /// explained what the notifications are for.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isEnabled else { return false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        return granted
    }

    private func registerForRemoteNotifications() {
        guard isEnabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Device token

    func didRegister(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        do {
            try await backend.notifications.registerDevice(token: token, environment: environment)
            defaults.set(token, forKey: LocalPreferenceKey.deviceToken)
        } catch {
            // Tried again on the next launch; never surfaced to the person.
            Diagnostics.failure(Diagnostics.push, "registerDevice", error)
        }
    }

    func didFailToRegister(_ error: Error) {
        Diagnostics.push.error("APNs registration failed: \(String(describing: type(of: error)), privacy: .public)")
    }

    /// Detaches this device from the account, so a signed-out phone stops
    /// receiving that account's notifications. Must run before sign-out, while
    /// the session can still authorise it.
    func unregisterDevice() async {
        guard let token = defaults.string(forKey: LocalPreferenceKey.deviceToken) else { return }
        try? await backend.notifications.unregisterDevice(token: token)
        defaults.removeObject(forKey: LocalPreferenceKey.deviceToken)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }

    // MARK: - Preferences

    func loadPreferences() async {
        if preferences == nil { preferencesState = .loading }
        do {
            preferences = try await backend.notifications.preferences()
            preferencesState = .loaded
        } catch {
            if preferences == nil { preferencesState = .failed(appError(from: error)) }
        }
    }

    /// Applies a change immediately and puts it back if the server refuses.
    func update(_ change: (inout NotificationPreferences) -> Void) async throws {
        guard let current = preferences else { return }
        var updated = current
        change(&updated)
        guard updated != current else { return }
        preferences = updated
        do {
            try await backend.notifications.update(updated)
        } catch {
            preferences = current
            throw appError(from: error)
        }
    }

    func reset() {
        preferences = nil
        preferencesState = .idle
    }

    func clearBadge() {
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }

    /// Reads the destination out of a notification payload. Payloads carry
    /// identifiers only, so there is nothing sensitive to parse here.
    nonisolated static func deepLink(from userInfo: [AnyHashable: Any]) -> DeepLink? {
        if let raw = userInfo["note_id"] as? String, let id = UUID(uuidString: raw) { return .note(id) }
        if let kind = userInfo["category"] as? String, kind == "pairing" || kind == "account" { return .home }
        return nil
    }
}

extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.userInfo["category"] as? String
        await onRemoteChange?()
        // A new note appears on screen by itself while the app is open; a
        // banner on top of it would only be noise.
        return category == "new_note" || category == "surprise" ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let link = Self.deepLink(from: response.notification.request.content.userInfo)
        await MainActor.run {
            if let link { onOpen?(link) }
        }
    }
}
