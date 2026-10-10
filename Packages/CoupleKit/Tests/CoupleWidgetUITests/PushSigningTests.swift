import CoupleDomain
import CoupleWidgetUI
import XCTest

final class PushSigningTests: XCTestCase {
    /// Shaped like the real thing: signature bytes around a property list.
    private func profile(_ entitlements: String) -> Data {
        var data = Data([0x30, 0x82, 0x1f, 0x00, 0xff])
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
        """.utf8))
        data.append(Data([0xa0, 0x82, 0x00, 0xfe]))
        return data
    }

    func testTheSignedProfileDecidesThePushEnvironment() {
        XCTAssertEqual(PushSigning.environment(inProvisioningProfile: profile("<key>aps-environment</key><string>development</string>")), .sandbox)
        XCTAssertEqual(PushSigning.environment(inProvisioningProfile: profile("<key>aps-environment</key><string>production</string>")), .production)
    }

    func testAProfileWithoutPushOrUnreadableDataDecidesNothing() {
        XCTAssertNil(PushSigning.environment(inProvisioningProfile: profile("<key>get-task-allow</key><true/>")))
        XCTAssertNil(PushSigning.environment(inProvisioningProfile: Data([0x00, 0x01, 0x02])))
    }

    func testWithoutAProfileTheBuildSettingIsUsed() {
        let bundle = Bundle(for: PushSigningTests.self)
        XCTAssertEqual(PushSigning.environment(bundle: bundle, buildSetting: "production"), .production)
        XCTAssertEqual(PushSigning.environment(bundle: bundle, buildSetting: "development"), .sandbox)
        XCTAssertEqual(PushSigning.environment(bundle: bundle, buildSetting: nil), .sandbox)
    }
}
