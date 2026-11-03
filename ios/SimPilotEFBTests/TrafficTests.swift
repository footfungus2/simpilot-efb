import XCTest
@testable import SimPilotEFB

final class TrafficTests: XCTestCase {
    private func aircraft(_ id: Int, callsign: String = "EASY 1234", altFt: Double = 35_000, onGround: Bool = false) -> TrafficAircraft {
        TrafficAircraft(id: id, callsign: callsign, type: "Airbus A320neo", lat: 51.5, lon: 0.1, altFt: altFt, hdgDeg: 270, gsKt: 450, onGround: onGround)
    }

    func testTheBridgeMessageDecodes() throws {
        let json = #"{"t":"traffic","aircraft":[{"id":7,"callsign":"EASY 1234","type":"A320","lat":51.5,"lon":0.1,"altFt":4500,"hdgDeg":272,"gsKt":220,"onGround":false}]}"#
        guard case let .traffic(list)? = BridgeMessage.decode(Data(json.utf8)) else { return XCTFail("not decoded as traffic") }
        XCTAssertEqual(list.map(\.id), [7])
        XCTAssertEqual(list.first?.callsign, "EASY 1234")
    }

    func testLabelsShowLevelOrAltitudeAndNothingOnTheGround() {
        XCTAssertEqual(TrafficStore.label(aircraft(1, altFt: 35_000)), "EASY 1234\nFL350")
        XCTAssertEqual(TrafficStore.label(aircraft(2, altFt: 4_480)), "EASY 1234\n4500 ft")
        XCTAssertEqual(TrafficStore.label(aircraft(3, onGround: true)), "EASY 1234")
        XCTAssertEqual(TrafficStore.label(aircraft(4, callsign: "")), "–\nFL350")
    }

    @MainActor
    func testStoreBuildsGeoJSONAndClears() throws {
        let store = TrafficStore()
        XCTAssertNil(store.geojson)
        store.update([aircraft(1), aircraft(2, onGround: true)])
        let data = try XCTUnwrap(store.geojson)
        let features = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["features"] as? [[String: Any]])
        XCTAssertEqual(features.count, 2)
        let versionBefore = store.version
        store.clear()
        XCTAssertNil(store.geojson)
        XCTAssertGreaterThan(store.version, versionBefore)
        let versionAfter = store.version
        store.clear() // already empty: nothing to push to the map
        XCTAssertEqual(store.version, versionAfter)
    }
}
