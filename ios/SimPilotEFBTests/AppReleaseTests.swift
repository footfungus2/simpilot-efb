import XCTest
@testable import SimPilotEFB

final class AppReleaseTests: XCTestCase {
    func testVersionAndBuildOrdering() {
        XCTAssertTrue(AppRelease(version: "0.1.0", build: 12).isNewer(than: "0.1.0", build: 11))
        XCTAssertFalse(AppRelease(version: "0.1.0", build: 12).isNewer(than: "0.1.0", build: 12))
        XCTAssertFalse(AppRelease(version: "0.1.0", build: 12).isNewer(than: "0.1.0", build: 13))
        XCTAssertTrue(AppRelease(version: "0.10.0", build: 1).isNewer(than: "0.9.0", build: 99))
        XCTAssertFalse(AppRelease(version: "0.1.0", build: 99).isNewer(than: "0.2.0", build: 1))
        XCTAssertFalse(AppRelease(version: "1.0", build: 1).isNewer(than: "1.0.0", build: 1))
    }

    func testRejectsInvalidReleaseMetadata() throws {
        for version in ["", "1..0", "../latest", "1.0-beta", "-1.0", "١.٠"] {
            XCTAssertFalse(AppRelease(version: version, build: 2).isValid)
        }
        XCTAssertFalse(AppRelease(version: "1.0", build: 0).isValid)
        let data = Data(#"{"version":"0.1.0","build":42}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(AppRelease.self, from: data).isValid)
    }

    func testInstallURLKeepsAssetAndBuildInsideOneQueryValue() throws {
        let release = AppRelease(version: "0.1.0", build: 42)
        let install = try XCTUnwrap(URLComponents(url: release.installURL(using: .trollStore), resolvingAgainstBaseURL: false))
        XCTAssertEqual(install.scheme, "apple-magnifier")
        XCTAssertEqual(install.host, "install")
        XCTAssertEqual(install.queryItems?.count, 1)
        XCTAssertEqual(install.queryItems?.first?.name, "url")
        XCTAssertEqual(install.queryItems?.first?.value,
                       "https://github.com/footfungus2/simpilot-efb/releases/download/v0.1.0-build.42/SimPilotEFB.ipa?build=42")
        let sideStore = try XCTUnwrap(URLComponents(url: release.installURL(using: .sideStore), resolvingAgainstBaseURL: false))
        XCTAssertEqual(sideStore.scheme, "sidestore")
        XCTAssertEqual(sideStore.host, install.host)
        XCTAssertEqual(sideStore.queryItems, install.queryItems)
    }
}
