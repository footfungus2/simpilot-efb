import CoreLocation
import XCTest
@testable import SimPilotEFB

final class TaxiPathTests: XCTestCase {
    private let lon = 0.2, lat = 51.9 // 0.001° of latitude is about 111 m

    private func line(_ ref: String, _ points: [[Double]]) -> [String: Any] {
        ["type": "Feature", "properties": ["kind": "taxi-line", "ref": ref], "geometry": ["type": "LineString", "coordinates": points]]
    }

    private func c(_ dLat: Double, _ dLon: Double) -> [Double] { [lon + dLon, lat + dLat] }

    /// H runs west to east with a vertex at (0, 0.004); B crosses it there; C leaves B's north end to the east; J is not connected.
    private func ground() -> AirportGround {
        AirportGround(features: [
            line("H", [c(0, 0), c(0, 0.004), c(0, 0.008)]),
            line("B", [c(-0.002, 0.004), c(0, 0.004), c(0.002, 0.004)]),
            line("C", [c(0.002, 0.004), c(0.002, 0.007)]),
            line("J", [c(0.005, 0), c(0.005, 0.008)]),
        ])
    }

    private func at(_ dLat: Double, _ dLon: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon) }

    func testOnlyTheDrivenStretchOfEachTaxiwayIsUsed() throws {
        let path = try XCTUnwrap(ground().path(route: ["H", "B", "C"], start: at(0, 0.0001), end: nil))
        let first = try XCTUnwrap(path.points.first), last = try XCTUnwrap(path.points.last)
        XCTAssertEqual(first.longitude, lon, accuracy: 0.0002) // H's west end, where the aircraft is
        XCTAssertEqual(last.longitude, lon + 0.007, accuracy: 0.00001) // C's far end
        XCTAssertEqual(last.latitude, lat + 0.002, accuracy: 0.00001)
        XCTAssertFalse(path.points.contains { abs($0.latitude - lat) < 1e-9 && $0.longitude > lon + 0.0041 }) // no H beyond the junction
        XCTAssertFalse(path.points.contains { $0.latitude < lat - 1e-9 }) // no B south of it
    }

    func testTheEndsFollowTheAircraftAndTheTarget() throws {
        let east = try XCTUnwrap(ground().path(route: ["H", "B"], start: at(0, 0.0079), end: nil))
        XCTAssertGreaterThan(try XCTUnwrap(east.points.first).longitude, lon + 0.0075) // began at H's east end
        let toStand = try XCTUnwrap(ground().path(route: ["H", "B"], start: at(0, 0.0001), end: at(-0.0021, 0.004)))
        XCTAssertEqual(try XCTUnwrap(toStand.points.last).latitude, lat - 0.002, accuracy: 0.00001) // B's south end, nearest the stand
    }

    func testNamesThatDontConnectGiveNoPath() {
        XCTAssertNil(ground().path(route: ["H", "J"], start: nil, end: nil))
        XCTAssertNil(ground().path(route: ["H", "ZZ"], start: nil, end: nil))
        XCTAssertNil(ground().path(route: ["C", "H"], start: nil, end: nil))
        XCTAssertNil(ground().path(route: [], start: nil, end: nil))
    }

    /// H and C meet only through a short unnamed connector whose first point is a little off H's end (as at EGSS).
    func testTaxiwaysJoinedByAnUnnamedConnectorStillConnect() throws {
        let joined = AirportGround(features: [
            line("H", [c(0, 0), c(0, 0.004)]),
            line("", [[lon + 0.004 + 0.000008, lat + 0.0000005], c(0.0004, 0.0045), c(0.001, 0.005)]),
            line("C", [c(0.001, 0.005), c(0.002, 0.008)]),
        ])
        let path = try XCTUnwrap(joined.path(route: ["H", "C"], start: at(0, 0.0001), end: nil))
        XCTAssertEqual(try XCTUnwrap(path.points.last).longitude, lon + 0.008, accuracy: 0.00001)
        XCTAssertTrue(path.points.contains { abs($0.longitude - (lon + 0.0045)) < 0.00001 }) // went over the connector
        XCTAssertNotNil(joined.path(route: ["C", "H"], start: nil, end: nil))
        // Two taxiways with no link at all still give no path.
        let apart = AirportGround(features: [line("H", [c(0, 0), c(0, 0.004)]), line("J", [c(0.01, 0), c(0.01, 0.004)])])
        XCTAssertNil(apart.path(route: ["H", "J"], start: nil, end: nil))
    }

    /// "C" leads from H to the apron lane that is mapped as "C EAST" (a part of the same taxiway under another name).
    func testPartsOfOneTaxiwayStandInForEachOther() throws {
        let family = AirportGround(features: [
            line("H", [c(0, 0), c(0, 0.004)]),
            line("C", [c(0, 0.004), c(0.002, 0.006)]),
            line("C EAST", [c(0.002, 0.006), c(0.004, 0.008)]),
        ])
        let east = try XCTUnwrap(family.path(route: ["H", "C EAST"], start: at(0, 0.0001), end: nil))
        XCTAssertEqual(try XCTUnwrap(east.points.last).longitude, lon + 0.008, accuracy: 0.00001) // runs out to the end of C EAST
        XCTAssertNotNil(family.path(route: ["C EAST", "H"], start: nil, end: nil))
        // A taxiway of another name does not stand in: A is not part of C's family.
        let other = AirportGround(features: [line("H", [c(0, 0), c(0, 0.004)]), line("A", [c(0, 0.004), c(0.002, 0.006)]), line("C EAST", [c(0.002, 0.006), c(0.004, 0.008)])])
        XCTAssertNil(other.path(route: ["H", "C EAST"], start: nil, end: nil))
    }

    func testFamilyNamesDropATrailingCompassWord() {
        XCTAssertEqual(AirportGround.familyName("C EAST"), "C")
        XCTAssertEqual(AirportGround.familyName(" b west "), "B")
        XCTAssertEqual(AirportGround.familyName("N SOUTH"), "N")
        XCTAssertEqual(AirportGround.familyName("EAST"), "EAST") // nothing left of the name: keep it
        XCTAssertEqual(AirportGround.familyName("A1"), "A1")
        XCTAssertEqual(AirportGround.familyName("Taxiway Y"), "TAXIWAY Y")
    }

    func testSplitAtTheAircraft() throws {
        let path = try XCTUnwrap(ground().path(route: ["H", "B", "C"], start: at(0, 0.0001), end: nil))
        let onB = at(0.001, 0.004)
        let parts = path.split(at: onB)
        XCTAssertGreaterThanOrEqual(parts.done.count, 2)
        XCTAssertGreaterThanOrEqual(parts.todo.count, 2)
        XCTAssertLessThan(AirportGround.meters(try XCTUnwrap(parts.done.last), onB), 1)
        XCTAssertLessThan(AirportGround.meters(try XCTUnwrap(parts.todo.first), onB), 1)
        let away = path.split(at: at(0.02, 0))
        XCTAssertTrue(away.done.isEmpty)
        XCTAssertEqual(away.todo.count, path.points.count)
        XCTAssertEqual(path.split(at: nil).todo.count, path.points.count)
    }
}

final class TaxiPathPresentationTests: XCTestCase {
    private let lon = 0.2, lat = 51.9

    private func at(_ north: Double, _ east: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat + north / 111_320, longitude: lon + east / (cos(lat * .pi / 180) * 111_320))
    }

    private func line(_ ref: String, _ points: [CLLocationCoordinate2D]) -> [String: Any] {
        ["type": "Feature", "properties": ["kind": "taxi-line", "ref": ref], "geometry": ["type": "LineString", "coordinates": points.map { [$0.longitude, $0.latitude] }]]
    }

    private func hold(_ point: CLLocationCoordinate2D, ref: String? = nil, type: String = "runway") -> [String: Any] {
        var props: [String: Any] = ["kind": "hold", "type": type, "rot": 0]
        if let ref { props["ref"] = ref }
        return ["type": "Feature", "properties": props, "geometry": ["type": "Point", "coordinates": [point.longitude, point.latitude]]]
    }

    func testACornerBecomesACurveWithTheSameEnds() {
        let corner = TaxiPath(points: [at(0, 0), at(100, 0), at(100, 100)])
        let curved = corner.smoothed()
        XCTAssertGreaterThan(curved.points.count, 3)
        XCTAssertLessThan(AirportGround.meters(curved.points[0], corner.points[0]), 0.01)
        XCTAssertLessThan(AirportGround.meters(curved.points.last!, corner.points.last!), 0.01)
        XCTAssertFalse(curved.points.contains { AirportGround.meters($0, at(100, 0)) < 3 }) // the sharp point is gone
        XCTAssertLessThan(curved.meters, corner.meters)
        XCTAssertGreaterThan(curved.meters, corner.meters * 0.9)
    }

    func testStraightAndGentleStretchesAreLeftAlone() {
        let straight = TaxiPath(points: [at(0, 0), at(50, 0), at(100, 0)])
        XCTAssertEqual(straight.smoothed(), straight)
        let gentle = TaxiPath(points: [at(0, 0), at(100, 0), at(200, 8)])
        XCTAssertEqual(gentle.smoothed(), gentle)
    }

    func testShortLegsKeepTheCurveInsideThem() {
        let tight = TaxiPath(points: [at(0, 0), at(20, 0), at(20, 20)]).smoothed()
        XCTAssertGreaterThan(tight.points.count, 3)
        XCTAssertTrue(tight.points.allSatisfy { AirportGround.meters($0, at(20, 0)) <= 20.5 })
    }

    func testTheLineIsCutExactlyAtAHoldingPoint() throws {
        let path = TaxiPath(points: [at(0, 0), at(300, 0)])
        let cut = try XCTUnwrap(path.truncated(at: at(120, 6))) // the hold bar sits 6 m beside the centreline
        XCTAssertLessThan(AirportGround.meters(try XCTUnwrap(cut.points.last), at(120, 0)), 1)
        XCTAssertNil(path.truncated(at: at(120, 100))) // far from the path: not on it
    }

    func testARouteToAHoldStopsThereInsteadOfAtTheEndOfTheTaxiway() throws {
        let ground = AirportGround(features: [
            line("H", [at(0, 0), at(0, 280), at(0, 560)]),
            line("B", [at(0, 280), at(220, 280), at(440, 280)]),
        ])
        let holdPoint = at(133, 282)
        let start = at(0, 5)
        let stopped = try XCTUnwrap(ground.path(route: ["H", "B"], start: start, end: holdPoint, stopAtEnd: true))
        XCTAssertLessThan(AirportGround.meters(try XCTUnwrap(stopped.points.last), at(133, 280)), 2)
        let justShort = at(215, 280) // just before a vertex of B
        let stoppedShort = try XCTUnwrap(ground.path(route: ["H", "B"], start: start, end: justShort, stopAtEnd: true))
        XCTAssertLessThan(AirportGround.meters(try XCTUnwrap(stoppedShort.points.last), justShort), 2)
        let past = try XCTUnwrap(ground.path(route: ["H", "B"], start: start, end: holdPoint, stopAtEnd: false))
        XCTAssertGreaterThan(AirportGround.meters(try XCTUnwrap(past.points.last), at(0, 280)), 133) // runs on to a vertex beyond it
    }

    func testHoldingPointsUseTheirNamesFromTheMap() {
        let ground = AirportGround(features: [
            line("N", [at(0, 0), at(0, 300)]),
            hold(at(0, 100), ref: "N1", type: "runway"),
            hold(at(0, 200), ref: "N3", type: "ILS"),
            hold(at(0, 250)), // no name in the map data
        ])
        XCTAssertEqual(ground.holds.map(\.name), ["N1", "N3", ""])
        XCTAssertEqual(ground.holds[1].label, "N3 · ILS")
        XCTAssertTrue(ground.holds[0].label.hasPrefix("N1"))
        XCTAssertEqual(ground.holds[2].label, "N") // falls back to the taxiway it is on
    }

    func testMapsSavedBeforeHoldNamesAreRefreshedOnce() {
        func f(_ props: [String: Any]) -> [String: Any] { ["type": "Feature", "properties": props, "geometry": ["type": "Point", "coordinates": [0.2, 51.9]]] }
        XCTAssertTrue(AirportMapService.lacksHoldNames([f(["kind": "hold", "type": "runway"])])) // old schema
        XCTAssertFalse(AirportMapService.lacksHoldNames([f(["kind": "hold", "type": "runway", "ref": ""])])) // new schema, no name in OSM
        XCTAssertFalse(AirportMapService.lacksHoldNames([f(["kind": "hold", "ref": "N1"])]))
        XCTAssertFalse(AirportMapService.lacksHoldNames([f(["kind": "stand", "ref": "5"])])) // no holding points at all
    }
}
