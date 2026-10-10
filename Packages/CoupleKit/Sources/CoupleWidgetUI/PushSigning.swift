import CoupleDomain
import Foundation

/// Which Apple push service a build's tokens belong to.
///
/// That is decided by how the build was signed, not by its configuration: a
/// Release build run from Xcode is signed for development and gets sandbox
/// tokens. Telling the server the wrong one makes every push fail silently, so
/// the provisioning profile inside the bundle is the authority when there is
/// one. App Store and TestFlight builds carry no profile; they fall back to the
/// build setting, which is `production` for Release.
public enum PushSigning {
    public static func environment(bundle: Bundle = .main, buildSetting: String?) -> PushEnvironment {
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let signed = environment(inProvisioningProfile: data) {
            return signed
        }
        return buildSetting == "production" ? .production : .sandbox
    }

    /// A provisioning profile is a signed container around a property list.
    /// The list is stored in the clear, so it can be read without verifying
    /// the signature; iOS has already done that to let the app run.
    public static func environment(inProvisioningProfile data: Data) -> PushEnvironment? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String
        else { return nil }
        return value == "production" ? .production : .sandbox
    }
}
