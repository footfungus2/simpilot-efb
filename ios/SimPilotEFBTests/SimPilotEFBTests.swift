import XCTest
@testable import SimPilotEFB

final class ChartGeoProjectionTests: XCTestCase {
    /// Builds an area whose chart rectangle is consistent with its world rectangle under the projection,
    /// the way real georeferenced Lido pages are.
    private func area(orientation: Double = 0) -> ChartArea {
        let world = ChartRect(upperLeft: [8.3, 50.2], lowerRight: [8.9, 49.9], orientation: orientation)
        let proj = ChartProjection(standardParallel1: 49, standardParallel2: 51, centralMeridian: 8.6)
        // Probe with a provisional chart rect to find where the lower-right corner lands, then use that.
        let probe = ChartArea(layer: "plan", geoReferenced: true,
                              chartRect: ChartRect(upperLeft: [10, 20], lowerRight: [990, 1000], orientation: 0),
                              worldRect: world, projection: proj)
        let lr = ChartGeoProjection(area: probe)!.project(lat: 49.9, lon: 8.9)
        return ChartArea(layer: "plan", geoReferenced: true,
                         chartRect: ChartRect(upperLeft: [10, 20], lowerRight: [Double(lr.x), Double(lr.y)], orientation: 0),
                         worldRect: world, projection: proj)
    }

    func testCornersMapToChartRectangle() throws {
        let a = area()
        let p = try XCTUnwrap(ChartGeoProjection(area: a))
        let ul = p.project(lat: 50.2, lon: 8.3)
        XCTAssertEqual(ul.x, 10, accuracy: 1e-6)
        XCTAssertEqual(ul.y, 20, accuracy: 1e-6)
        let lr = p.project(lat: 49.9, lon: 8.9)
        XCTAssertEqual(Double(lr.x), a.chartRect.lowerRight[0], accuracy: 1e-6)
        XCTAssertEqual(Double(lr.y), a.chartRect.lowerRight[1], accuracy: 1e-6)
    }

    func testNorthIsUpAndEastIsRight() throws {
        let p = try XCTUnwrap(ChartGeoProjection(area: area()))
        XCTAssertLessThan(p.project(lat: 50.15, lon: 8.6).y, p.project(lat: 50.0, lon: 8.6).y)
        XCTAssertGreaterThan(p.project(lat: 50.0, lon: 8.8).x, p.project(lat: 50.0, lon: 8.4).x)
    }

    func testPagePositionOnlyInsideArea() {
        let page = ChartPage(index: 0, width: 1200, height: 1200, geoReferenced: true, areas: [area()], image: nil)
        XCTAssertNotNil(page.position(lat: 50.05, lon: 8.6))
        XCTAssertNil(page.position(lat: 51.5, lon: 8.6))
    }

    func testRejectsIncompleteArea() {
        let a = ChartArea(layer: "x", geoReferenced: true,
                          chartRect: ChartRect(upperLeft: [0, 0], lowerRight: [1, 1], orientation: 0),
                          worldRect: nil, projection: nil)
        XCTAssertNil(ChartGeoProjection(area: a))
    }

    func testRejectsIncompleteFittedChartRectangle() {
        let a = ChartArea(layer: "plan", geoReferenced: true,
                          chartRect: ChartRect(upperLeft: [], lowerRight: [1, 1], orientation: 0),
                          worldRect: nil, projection: ChartProjection(standardParallel1: 49, standardParallel2: 51, centralMeridian: 8.6),
                          similarity: [0, 0, 1, 0])
        XCTAssertNil(ChartGeoProjection(area: a))
    }
}

final class BridgeMessageTests: XCTestCase {
    func testDecodesOwnship() {
        let json = #"{"t":"ownship","lat":50.03,"lon":8.57,"altFt":364,"gsKt":0,"trkDeg":250,"hdgDeg":250,"vsFpm":0,"onGround":true,"magVarDeg":-3,"ts":1}"#
        guard case let .ownship(o)? = BridgeMessage.decode(Data(json.utf8)) else { return XCTFail("not ownship") }
        XCTAssertEqual(o.trkDeg, 250)
        XCTAssertTrue(o.onGround)
    }

    func testDecodesHelloAndIgnoresUnknown() {
        let hello = #"{"t":"hello","v":1,"bridgeVersion":"0.1.0","status":{"sim":{"connected":true,"aircraftTitle":"A350"},"link":{"connected":false}}}"#
        guard case let .hello(s)? = BridgeMessage.decode(Data(hello.utf8)) else { return XCTFail("not hello") }
        XCTAssertEqual(s.sim.aircraftTitle, "A350")
        XCTAssertNil(BridgeMessage.decode(Data(#"{"t":"later"}"#.utf8)))
    }
}

final class AiracTests: XCTestCase {
    func testCycleValidityMatchesPublishedCycles() {
        XCTAssertEqual(AiracCycle.validity(of: "2602"), "19 Feb - 18 Mar") // as on the mPilot screenshots
        XCTAssertEqual(AiracCycle.validity(of: "2510"), "2 Oct - 29 Oct")
        XCTAssertNil(AiracCycle.validity(of: "2615"))
    }
}

#if DEBUG
final class BundledChartsTests: XCTestCase {
    /// The offline EGSS charts (personal-use PDFs, gitignored — skipped when absent) put the airport on the chart
    /// and round-trip positions through their georeference.
    func testOfflineChartsAreGeoreferenced() throws {
        let charts = BundledCharts.charts(for: "EGSS")
        try XCTSkipIf(charts.isEmpty, "No offline charts bundled in this checkout")
        let index = BundledCharts.index(icao: "EGSS", charts: charts)
        XCTAssertEqual(index.provider, BundledCharts.provider)
        XCTAssertEqual(index.categories.flatMap(\.charts).count, charts.count)
        XCTAssertEqual(BundledCharts.title(for: charts), "Offline UK AIP charts")
        for chart in charts {
            let page = try XCTUnwrap(chart.detail.pages.first)
            XCTAssertEqual(page.image, chart.imagePath)
            // Aerodrome reference point: every bundled SID starts there.
            let p = try XCTUnwrap(page.position(lat: 51.885, lon: 0.235), chart.detail.chart.name)
            let back = try XCTUnwrap(ChartGeoProjection(area: page.areas[0])).unproject(p)
            XCTAssertEqual(back.lat, 51.885, accuracy: 1e-6)
            XCTAssertEqual(back.lon, 0.235, accuracy: 1e-6)
        }
    }
}
#endif
