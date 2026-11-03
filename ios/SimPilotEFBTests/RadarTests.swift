import XCTest
@testable import SimPilotEFB

final class RadarTests: XCTestCase {
    private func parse(_ json: String) throws -> RadarStore.Index { try RadarStore.parse(Data(json.utf8)) }

    func testFramesAreSortedOldestFirst() throws {
        let index = try parse(#"{"host":"https://tilecache.rainviewer.com","radar":{"past":[{"time":200,"path":"/v2/radar/bbb"},{"time":100,"path":"/v2/radar/aaa"}]}}"#)
        XCTAssertEqual(index.frames.map(\.path), ["/v2/radar/aaa", "/v2/radar/bbb"])
        XCTAssertEqual(index.host, "https://tilecache.rainviewer.com")
    }

    func testUnexpectedHostsAndPathsAreRejected() {
        XCTAssertThrowsError(try parse(#"{"host":"http://example.com","radar":{"past":[{"time":1,"path":"/v2/radar/aaa"}]}}"#))
        XCTAssertThrowsError(try parse(#"{"host":"https://a.b/x?y=1","radar":{"past":[{"time":1,"path":"/v2/radar/aaa"}]}}"#))
        XCTAssertThrowsError(try parse(#"{"host":"https://a.b","radar":{"past":[{"time":1,"path":"/v2/radar/../x"}]}}"#))
        XCTAssertThrowsError(try parse(#"{"host":"https://a.b","radar":{"past":[]}}"#))
    }

    @MainActor
    func testFrameSteppingStaysInRange() async throws {
        let store = RadarStore()
        XCTAssertNil(store.tileTemplate)
        XCTAssertFalse(store.canStepBack)
        store.step(back: true) // nothing loaded: no change, no crash
        XCTAssertEqual(store.stepsBack, 0)
    }
}
