import CoreLocation
import XCTest
@testable import SimPilotEFB

final class ServiceRobustnessTests: XCTestCase {
    func testSimBriefNormalizesNonfiniteNumbersWithoutCrashing() {
        let ofp = SimBriefService.normalize([
            "general": ["initial_altitude": "NaN", "route_distance": "Infinity", "gc_distance": "-Infinity"],
            "origin": ["pos_lat": NSNumber(value: Double.nan)],
            "fuel": ["plan_ramp": "NaN"],
        ])
        XCTAssertEqual(ofp.cruiseFl, 0)
        XCTAssertEqual(ofp.distanceNm, 0)
        XCTAssertEqual(ofp.origin.lat, 0)
        XCTAssertEqual(ofp.fuel.ramp, 0)
        XCTAssertEqual(SimBriefService.normalize(["general": ["initial_altitude": "1e300"]]).cruiseFl, 0)
        XCTAssertEqual(SimBriefService.normalize(["general": ["route_distance": "1e300"]]).distanceNm, 0)
    }

    func testSimBriefRetainsNormalNumbersAndSingleFix() {
        let ofp = SimBriefService.normalize([
            "general": ["initial_altitude": "35000", "route_distance": "123.4"],
            "navlog": ["fix": ["ident": "TEST", "distance": "12.5"]],
        ])
        XCTAssertEqual(ofp.cruiseFl, 350)
        XCTAssertEqual(ofp.distanceNm, 123.4)
        XCTAssertEqual(ofp.navlog.count, 1)
        XCTAssertEqual(ofp.navlog.first?.cumNm, 12.5)
    }

    func testMalformedSectorRingsAreIgnored() {
        let point = CLLocationCoordinate2D(latitude: 51, longitude: 1)
        let rings: [[[Double]]] = [[], [[0, 50]], [[0, 50], [2], [2, 52]], [[0, 50], [Double.nan, 51], [2, 52]]]
        for ring in rings {
            XCTAssertFalse(VatsimAssistant.contains(["type": "Polygon", "coordinates": [ring]], point))
        }
    }

    func testInvalidAirportIdentifiersDoNotStartWeatherRequests() async {
        for icao in ["", "ABCDE", "????", "A&B?", "ＥＧＳＳ"] {
            let metar = await WeatherService.metar(icao: icao)
            XCTAssertNil(metar)
        }
    }
}
