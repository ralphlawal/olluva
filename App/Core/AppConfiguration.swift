import CoupleDomain
import CoupleWidgetUI
import Foundation

/// Build-time and launch-time configuration, read once at start-up.
struct AppConfiguration {
    struct SupabaseConfiguration {
        let url: URL
        let anonKey: String
    }

    let supabase: SupabaseConfiguration?
    let appGroupID: String
    let pushEnvironment: PushEnvironment
    let displayName: String
    let version: String
    let build: String
    /// Run on the in-memory backend. Only ever true in DEBUG builds.
    let usesDemoBackend: Bool
    let demoScenario: String
    let isUITesting: Bool
    /// Demo only: the seeded account exists but nobody is signed in yet.
    let demoStartsSignedOut: Bool
    /// Demo only: sending fails as if the connection had dropped.
    let demoSendsFail: Bool
    let forcesDarkAppearance: Bool
    /// UI tests suppress one-time prompts unless a test asks for one.
    let showsBackupOffer: Bool

    static let current = AppConfiguration(bundle: .main, arguments: ProcessInfo.processInfo.arguments)

    init(bundle: Bundle, arguments: [String]) {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        func argument(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        let host = value("SupabaseHost")
        let key = value("SupabaseAnonKey")
        // Only a bare host is accepted, and the scheme is fixed here: there is
        // no configuration under which the app talks to its backend over http.
        if !host.isEmpty, !key.isEmpty, !host.contains("/"), let url = URL(string: "https://\(host)") {
            supabase = SupabaseConfiguration(url: url, anonKey: key)
        } else {
            supabase = nil
        }

        appGroupID = value("AppGroupID")
        pushEnvironment = PushSigning.environment(bundle: bundle, buildSetting: value("PushEnvironment"))
        displayName = value("CFBundleDisplayName").isEmpty ? "Olluva" : value("CFBundleDisplayName")
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")

        #if DEBUG
        isUITesting = arguments.contains("-uiTesting")
        usesDemoBackend = isUITesting || arguments.contains("-demoBackend") || supabase == nil
        demoScenario = argument(after: "-demoScenario") ?? "fresh"
        demoStartsSignedOut = arguments.contains("-startSignedOut")
        demoSendsFail = arguments.contains("-demoSendsFail")
        forcesDarkAppearance = arguments.contains("-forceDark")
        showsBackupOffer = arguments.contains("-showBackupOffer")
        #else
        demoStartsSignedOut = false
        demoSendsFail = false
        forcesDarkAppearance = false
        showsBackupOffer = false
        isUITesting = false
        usesDemoBackend = false
        demoScenario = ""
        #endif
    }

    /// A release build with no backend configured cannot do anything useful,
    /// and must say so rather than pretend.
    var isMissingBackend: Bool {
        supabase == nil && !usesDemoBackend
    }
}

/// Small on-device preferences that are not account data.
enum LocalPreferenceKey {
    static let widgetStyle = "widgetStyle"
    static let hideOnLockScreen = "hideOnLockScreen"
    static let appearance = "appearance"
    static let hasSeenWelcome = "hasSeenWelcome"
    static let notificationPrimingShown = "notificationPrimingShown"
    static let deviceToken = "deviceToken"
    static let backupOfferShown = "backupOfferShown"
}
