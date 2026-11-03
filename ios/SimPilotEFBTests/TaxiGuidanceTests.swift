import CoreLocation
import XCTest
@testable import SimPilotEFB

final class TaxiGuidanceTests: XCTestCase {
    private let lon = 0.2, lat = 51.9 // 0.001° of latitude is about 111 m

    private func feature(_ kind: String, _ props: [String: Any] = [:], point: [Double]? = nil, line: [[Double]]? = nil) -> [String: Any] {
        var p = props
        p["kind"] = kind
        let geometry: [String: Any] = point != nil ? ["type": "Point", "coordinates": point!] : ["type": "LineString", "coordinates": line!]
        return ["type": "Feature", "properties": p, "geometry": geometry]
    }

    private func ground() -> AirportGround {
        AirportGround(features: [
            feature("taxi-line", ["ref": "B"], line: [[lon, lat], [lon, lat + 0.003]]),
            feature("taxi-line", ["ref": "C"], line: [[lon, lat + 0.003], [lon + 0.004, lat + 0.003]]),
            feature("taxi-line", ["ref": "D"], line: [[lon + 0.004, lat + 0.003], [lon + 0.004, lat + 0.006]]),
            feature("runway-centerline", line: [[lon - 0.002, lat + 0.0045], [lon + 0.006, lat + 0.0045]]),
            feature("runway-end", ["ref": "04"], point: [lon - 0.002, lat + 0.0045]),
            feature("runway-end", ["ref": "22"], point: [lon + 0.006, lat + 0.0045]),
            feature("hold", point: [lon + 0.004, lat + 0.0035]),
            feature("stand", ["ref": "225"], point: [lon - 0.001, lat]),
            feature("stand", ["ref": "21"], point: [lon - 0.002, lat]),
            feature("stand-line", line: [[lon, lat], [lon - 0.001, lat]]),
        ])
    }

    private func at(_ dLat: Double, _ dLon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon)
    }

    func testStandsAreSortedNaturallyAndHaveTheirLeadIn() {
        let g = ground()
        XCTAssertEqual(g.stands.map(\.ref), ["21", "225"])
        XCTAssertNotNil(g.leadIn(of: g.stand("225")!))
        XCTAssertNil(g.leadIn(of: g.stand("21")!))
        XCTAssertNil(g.stand("999"))
    }

    func testHoldingPointsAreLabelledByTaxiwayAndRunway() {
        XCTAssertEqual(ground().holds.map(\.label), ["D · RWY 04/22"])
    }

    func testProgressFollowsTheRouteAndNeverGoesBack() {
        let g = ground()
        let route = ["B", "C", "D"]
        var progress = TaxiProgress()
        progress.update(route: route, ground: g, position: at(-0.002, 0)) // 220 m before B
        XCTAssertEqual(progress.reached, 0)
        XCTAssertFalse(progress.onRoute)
        progress.update(route: route, ground: g, position: at(0.001, 0))
        XCTAssertEqual(progress.reached, 0)
        XCTAssertTrue(progress.onRoute)
        progress.update(route: route, ground: g, position: at(0.003, 0.002))
        XCTAssertEqual(progress.reached, 1)
        XCTAssertEqual(progress.done(in: route), ["B"])
        XCTAssertEqual(progress.remaining(in: route), ["C", "D"])
        XCTAssertEqual(progress.next(in: route), "D")
        progress.update(route: route, ground: g, position: at(0.001, 0)) // back on B: stays on C
        XCTAssertEqual(progress.reached, 1)
        progress.update(route: route, ground: g, position: at(0.0045, 0.004))
        XCTAssertEqual(progress.reached, 2)
        XCTAssertNil(progress.next(in: route))
        progress.update(route: [], ground: g, position: at(0, 0))
        XCTAssertEqual(progress, TaxiProgress())
    }

    func testGuidanceShapesOnlyContainWhatWasPicked() throws {
        let g = ground()
        XCTAssertNil(TaxiGuidanceShapes.json(stand: nil, leadIn: nil, hold: nil))
        let stand = g.stand("225")
        let data = try XCTUnwrap(TaxiGuidanceShapes.json(stand: stand, leadIn: stand.flatMap { g.leadIn(of: $0) }, hold: g.holds.first))
        let features = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["features"] as? [[String: Any]])
        let kinds = features.compactMap { ($0["properties"] as? [String: Any])?["kind"] as? String }
        XCTAssertEqual(Set(kinds), ["g-stand-line", "g-stand", "g-hold"])
    }
}
