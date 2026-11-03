import XCTest
@testable import SimPilotEFB

final class ChangelogTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "changelog-\(UUID().uuidString)")! }

    func testAnUpdatedUserSeesTheNewestEntryOnceOnly() {
        let d = defaults()
        XCTAssertEqual(Changelog.unseen(freshInstall: false, defaults: d)?.id, Changelog.latest?.id)
        Changelog.markSeen(defaults: d)
        XCTAssertNil(Changelog.unseen(freshInstall: false, defaults: d))
    }

    func testAFreshInstallSeesNothingAndIsMarkedSeen() {
        let d = defaults()
        XCTAssertNil(Changelog.unseen(freshInstall: true, defaults: d))
        XCTAssertNil(Changelog.unseen(freshInstall: false, defaults: d))
    }

    func testEveryEntryHasContentAndUniqueIDs() {
        XCTAssertFalse(Changelog.entries.isEmpty)
        XCTAssertEqual(Set(Changelog.entries.map(\.id)).count, Changelog.entries.count)
        XCTAssertTrue(Changelog.entries.allSatisfy { !$0.sections.isEmpty && $0.sections.allSatisfy { !$0.items.isEmpty } })
    }
}
