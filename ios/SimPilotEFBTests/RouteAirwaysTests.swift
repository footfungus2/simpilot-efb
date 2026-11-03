import CoreLocation
import XCTest
@testable import SimPilotEFB

final class RouteAirwaysTests: XCTestCase {
    private func ofp(_ fixes: [(String, String, Bool)]) -> Ofp {
        // (ident, airway used to reach it, isSidStar); fixes run north from the origin, 0.5° apart.
        let navlog = fixes.enumerated().map { i, f in
            OfpFix(ident: f.0, name: f.0, type: "wpt", lat: 51 + Double(i + 1) * 0.5, lon: 0, altFt: 0, airway: f.1, stage: "", isSidStar: f.2,
                   legNm: 30, cumNm: Double(i + 1) * 30, frequency: "")
        }
        let airport = OfpAirport(icao: "AAAA", iata: "", name: "", lat: 51, lon: 0, elevFt: 0, planRwy: "", metar: "")
        return Ofp(fetchedAt: 0, airac: "", callsign: "TST1", aircraft: .init(icao: "A320", name: "A320", reg: ""),
                   origin: airport, destination: airport, alternates: [], route: "", distanceNm: 0, cruiseFl: 300, costIndex: "",
                   times: .init(schedOut: 0, schedOff: 0, schedOn: 0, schedIn: 0, eteSec: 0),
                   fuel: .init(units: "kgs", ramp: 0, takeoff: 0, landing: 0, minTakeoff: 0), navlog: navlog, ofpHtml: "", pdfUrl: nil)
    }

    func testConsecutiveFixesOnOneAirwayMakeOneRunStartingAtThePreviousFix() {
        let runs = RouteAirways.runs(in: ofp([("SID1", "CLN5S", true), ("A", "UL9", false), ("B", "UL9", false), ("C", "UN859", false), ("D", "UN859", false)]))
        XCTAssertEqual(runs.map(\.name), ["UL9", "UN859"])
        // UL9 starts at SID1 (the fix before A) and runs through B.
        XCTAssertEqual(runs[0].coordinates.map(\.latitude), [51.5, 52, 52.5])
        XCTAssertEqual(runs[1].coordinates.map(\.latitude), [52.5, 53, 53.5])
    }

    func testDirectLegsProceduresAndEmptyNamesAreNotAirways() {
        let runs = RouteAirways.runs(in: ofp([("A", "", false), ("B", "DCT", false), ("C", "dct", false), ("D", "DET2D", true), ("E", "L9", false)]))
        XCTAssertEqual(runs.map(\.name), ["L9"])
        XCTAssertEqual(runs[0].coordinates.count, 2)
    }

    func testSameAirwayTwiceSeparatedByADirectIsTwoRuns() {
        let runs = RouteAirways.runs(in: ofp([("A", "UL9", false), ("B", "DCT", false), ("C", "UL9", false)]))
        XCTAssertEqual(runs.map(\.name), ["UL9", "UL9"])
    }
}

final class MapFiltersTests: XCTestCase {
    func testFiltersSavedBeforeMoraExistedKeepTheirChoices() throws {
        let old = #"{"route":false,"airports":true,"firs":false,"vor":true,"ndb":true,"dme":false,"navaidFrequencies":true}"#
        let filters = try JSONDecoder().decode(MapFilters.self, from: Data(old.utf8))
        XCTAssertFalse(filters.route)
        XCTAssertTrue(filters.ndb)
        XCTAssertTrue(filters.navaidFrequencies)
        XCTAssertFalse(filters.mora) // new switch: off until chosen
    }

    func testMoraCountsAsAnActiveGroup() {
        var filters = MapFilters()
        let before = filters.activeCount
        filters.mora = true
        XCTAssertEqual(filters.activeCount, before + 1)
    }

    func testFiltersRoundTrip() throws {
        var filters = MapFilters()
        filters.mora = true
        filters.ndb = true
        let again = try JSONDecoder().decode(MapFilters.self, from: JSONEncoder().encode(filters))
        XCTAssertEqual(again, filters)
    }
}
