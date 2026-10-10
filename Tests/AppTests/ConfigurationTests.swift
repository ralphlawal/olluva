import XCTest
@testable import CoupleNotes

final class ConfigurationTests: XCTestCase {
    private final class FakeBundle: Bundle, @unchecked Sendable {
        var values: [String: String] = [:]
        override func object(forInfoDictionaryKey key: String) -> Any? { values[key] }
    }

    private func configuration(_ values: [String: String], arguments: [String] = []) -> AppConfiguration {
        let bundle = FakeBundle()
        bundle.values = values
        return AppConfiguration(bundle: bundle, arguments: arguments)
    }

    func testBackendIsAlwaysHTTPS() {
        let config = configuration(["SupabaseHost": "abc.supabase.co", "SupabaseAnonKey": "key"])
        XCTAssertEqual(config.supabase?.url.absoluteString, "https://abc.supabase.co")
    }

    func testAHostWithASchemeOrPathIsRejectedRatherThanTrusted() {
        XCTAssertNil(configuration(["SupabaseHost": "http://abc.supabase.co", "SupabaseAnonKey": "key"]).supabase)
        XCTAssertNil(configuration(["SupabaseHost": "abc.supabase.co/rest", "SupabaseAnonKey": "key"]).supabase)
        XCTAssertNil(configuration(["SupabaseHost": "abc.supabase.co", "SupabaseAnonKey": ""]).supabase)
    }

    func testPushEnvironmentDefaultsToSandbox() {
        XCTAssertEqual(configuration([:]).pushEnvironment, .sandbox)
        XCTAssertEqual(configuration(["PushEnvironment": "production"]).pushEnvironment, .production)
    }

    func testUITestingForcesTheDemoBackendEvenWhenAServerIsConfigured() {
        let config = configuration(
            ["SupabaseHost": "abc.supabase.co", "SupabaseAnonKey": "key"],
            arguments: ["-uiTesting", "-demoScenario", "paired"]
        )
        XCTAssertTrue(config.usesDemoBackend)
        XCTAssertEqual(config.demoScenario, "paired")
        XCTAssertFalse(config.isMissingBackend)
    }
}
