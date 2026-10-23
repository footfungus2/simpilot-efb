import XCTest
@testable import SimPilotEFB

final class UpdateInstallerTests: XCTestCase {
    func testDetectsInstallationMarkersWithoutGuessing() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let bundle = container.appendingPathComponent("SimPilotEFB.app")
        let identifier = "com.simpilot.efb.SIGNEDTEAM"
        var info: [String: Any] = ["CFBundleIdentifier": identifier]
        XCTAssertNil(UpdateInstaller.detect(bundleURL: bundle, info: info))

        info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["sidestore-unrelated"]]]
        XCTAssertNil(UpdateInstaller.detect(bundleURL: bundle, info: info))

        info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["sidestore-\(identifier)"]]]
        XCTAssertEqual(UpdateInstaller.detect(bundleURL: bundle, info: info), .sideStore)

        // Reinstalling with TrollStore may preserve SideStore's old Info.plist metadata.
        for marker in ["_TrollStore", "_TrollStoreLite"] {
            let url = container.appendingPathComponent(marker)
            try Data().write(to: url)
            XCTAssertEqual(UpdateInstaller.detect(bundleURL: bundle, info: info), .trollStore)
            XCTAssertEqual(UpdateInstaller.detect(bundleURL: bundle, info: [:]), .trollStore)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertNil(UpdateInstaller.detect(bundleURL: bundle, info: [:]))
    }
}
