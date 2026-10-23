import CoreLocation
import XCTest
@testable import SimPilotEFB

/// The iPad side of the Fenix control path; the bridge side (readback, ordering, squawk entry, tuning, reconnect)
/// is covered by bridge/test/fenix-control.test.ts.
final class FenixLinkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func link(bridge: Bool = true, sim: Bool = true, title: String? = "FenixA320 IAE", demo: Bool = false,
                      dataAge: TimeInterval? = 1, values: Bool = true) -> FenixLink {
        FenixLink.evaluate(bridgeConnected: bridge, simConnected: sim, aircraftTitle: title, demoActive: demo,
                           lastSimData: dataAge.map { now.addingTimeInterval(-$0) }, hasCockpitValues: values, now: now)
    }

    func testLiveOnlyWithEverythingInPlace() {
        XCTAssertEqual(link(), .live)
    }

    func testEachMissingPieceBlocksControl() {
        XCTAssertEqual(link(bridge: false), .noBridge)
        XCTAssertEqual(link(sim: false), .noSim)
        XCTAssertEqual(link(demo: true), .demo)
        XCTAssertEqual(link(dataAge: nil), .staleSim)
        XCTAssertEqual(link(dataAge: FenixLink.maxDataAge + 1), .staleSim)
        XCTAssertEqual(link(title: "Airbus A320neo Asobo"), .wrongAircraft("Airbus A320neo Asobo"))
        XCTAssertEqual(link(values: false), .waiting)
        for state in [link(bridge: false), link(dataAge: nil), link(title: "Cessna"), link(values: false)] {
            XCTAssertFalse(state.isLive)
        }
    }

    func testOldValuesDoNotCountAsLive() {
        // Cockpit values from earlier, but the sim stopped sending data: not live.
        XCTAssertEqual(link(dataAge: 30, values: true), .staleSim)
    }
}

final class FrequencyInputTests: XCTestCase {
    func testAcceptsCommonForms() {
        XCTAssertEqual(FrequencyInput.khz("121.8"), 121_800)
        XCTAssertEqual(FrequencyInput.khz("121.800"), 121_800)
        XCTAssertEqual(FrequencyInput.khz("118,575"), 118_575)
        XCTAssertEqual(FrequencyInput.khz("121800"), 121_800)
        XCTAssertEqual(FrequencyInput.khz("122"), 122_000)
        XCTAssertEqual(FrequencyInput.khz(vatsim: "133.700"), 133_700)
    }

    func testRejectsNonVhfCom() {
        XCTAssertNil(FrequencyInput.khz(""))
        XCTAssertNil(FrequencyInput.khz("117.950"))
        XCTAssertNil(FrequencyInput.khz("137.000"))
        XCTAssertNil(FrequencyInput.khz("abc"))
        XCTAssertNil(FrequencyInput.khz(vatsim: "199.998")) // VATSIM's "no frequency" placeholder
        for input in ["1.0e300", "1.0e999", "-9223372036854775808", "nan", "inf"] {
            XCTAssertNil(FrequencyInput.khz(input), input)
        }
    }
}

final class VatsimAssistantTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(VatsimAssistant.level("35000"), "FL350")
        XCTAssertEqual(VatsimAssistant.level("FL320"), "FL320")
        XCTAssertEqual(VatsimAssistant.level("5000"), "5000 ft")
        XCTAssertNil(VatsimAssistant.level(""))
        XCTAssertNil(VatsimAssistant.level(nil))
    }

    func testPointInSectorGeometry() {
        let square: [String: Any] = ["type": "Polygon", "coordinates": [[[0.0, 50.0], [2.0, 50.0], [2.0, 52.0], [0.0, 52.0], [0.0, 50.0]]]]
        XCTAssertTrue(VatsimAssistant.contains(square, CLLocationCoordinate2D(latitude: 51, longitude: 1)))
        XCTAssertFalse(VatsimAssistant.contains(square, CLLocationCoordinate2D(latitude: 53, longitude: 1)))
        let multi: [String: Any] = ["type": "MultiPolygon", "coordinates": [[[[10.0, 40.0], [11.0, 40.0], [11.0, 41.0], [10.0, 40.0]]],
                                                                           [[[0.0, 50.0], [2.0, 50.0], [2.0, 52.0], [0.0, 50.0]]]]]
        XCTAssertTrue(VatsimAssistant.contains(multi, CLLocationCoordinate2D(latitude: 50.5, longitude: 1.5)))
    }
}
