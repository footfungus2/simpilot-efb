import CoreLocation
import PencilKit
import UIKit
import XCTest
@testable import SimPilotEFB

final class MapToolsTests: XCTestCase {
    func testTextScalingPreservesZoomStopsAndScalesOutputs() {
        XCTAssertEqual(MapStyle.scaledTextSize(12, by: 1.4) as! Double, 16.8, accuracy: 1e-9)
        let expression: [Any] = ["interpolate", ["linear"], ["zoom"], 2, 10, 6, 15]
        let scaled = MapStyle.scaledTextSize(expression, by: 1.2) as! [Any]
        XCTAssertEqual(scaled[0] as? String, "interpolate")
        XCTAssertEqual(scaled[3] as? Int, 2)
        XCTAssertEqual(scaled[5] as? Int, 6)
        XCTAssertEqual(scaled[4] as? Double, 12)
        XCTAssertEqual(scaled[6] as? Double, 18)
        let step = MapStyle.scaledTextSize(["step", ["zoom"], 10, 6, 15] as [Any], by: 2) as! [Any]
        XCTAssertEqual(step[2] as? Double, 20)
        XCTAssertEqual(step[3] as? Int, 6)
        XCTAssertEqual(step[4] as? Double, 30)
        XCTAssertEqual(MapStyle.scaledTextSize(expression, by: 1) as! NSArray, expression as NSArray)
    }

    func testHighChartRespectsFiltersAndSwitchesLevels() {
        var filters = MapFilters()
        filters.ndb = true
        let high = Dictionary(uniqueKeysWithValues: MapStyle.layers(for: filters, high: true))
        let low = Dictionary(uniqueKeysWithValues: MapStyle.layers(for: filters, high: false))
        XCTAssertEqual(high["navaid-ndb"], false)
        XCTAssertEqual(high["all-airports-minor"], false)
        XCTAssertEqual(low["navaid-ndb"], true)
        filters.airports = false
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: MapStyle.layers(for: filters, high: false))["all-airports-minor"], false)
        XCTAssertEqual(MapFilters.levels(high: true, cruise: 357), [380, 350, 290])
        XCTAssertEqual(MapFilters.levels(high: false, cruise: 357), [190, 130, 70])
        XCTAssertEqual(MapFilters.levels(high: true, cruise: 0), [380, 350, 290])
        XCTAssertEqual(Set(MapFilters.levels(high: true, cruise: 10)).count, 3)
    }

    func testRulerMeasuresAndSplitsTheDateline() {
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 179)
        let b = CLLocationCoordinate2D(latitude: 0, longitude: -179)
        XCTAssertEqual(MapRuler.distanceNM(a, a), 0)
        XCTAssertEqual(MapRuler.distanceNM(a, b), 120.2, accuracy: 0.3)
        XCTAssertEqual(RunwayAwareness.bearing(a, b), 90, accuracy: 0.001)
        let lines = MapRuler.segments(a, b)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.count, 2)
            for pair in zip(line, line.dropFirst()) { XCTAssertLessThanOrEqual(abs(pair.0[0] - pair.1[0]), 180) }
            XCTAssertTrue(line.allSatisfy { $0.allSatisfy(\.isFinite) })
        }
        var ruler = MapRuler()
        let p = MapRuler.Point(coordinate: a, label: "A")
        ruler.tap(p); ruler.tap(MapRuler.Point(coordinate: b, label: "B"))
        XCTAssertNotNil(ruler.b)
        ruler.tap(p)
        XCTAssertEqual(ruler.a, p)
        XCTAssertNil(ruler.b)
        XCTAssertEqual(MapRuler.segments(a, a).first?.count, 2)
        XCTAssertTrue(MapRuler.segments(CLLocationCoordinate2D(latitude: 0, longitude: 180), CLLocationCoordinate2D(latitude: 0, longitude: -180))
            .flatMap { $0 }.flatMap { $0 }.allSatisfy(\.isFinite))
        ruler.followsAircraft = true
        XCTAssertNil(ruler.start(nil))
    }

    func testCompanyFeaturesWorkWithoutMainLayerAndIgnoreUnrelatedPilots() throws {
        let pilot = { (callsign: String) in VatsimPilot(cid: 1, name: "Test", callsign: callsign, latitude: 51, longitude: 0,
            altitude: 100, groundspeed: 0, heading: 0, transponder: nil, flight_plan: nil, logon_time: "") }
        let feed = VatsimFeed(pilots: [pilot("EZY123"), pilot("BAW456"), pilot("EZYA1")], controllers: [], atis: [])
        var filters = VatsimFilters()
        filters.pilots = false; filters.groundTraffic = false; filters.minAltitude = .aboveFL245
        let data = try XCTUnwrap(VatsimStore.buildFeatures(feed, filters: filters, myAirports: [], highlight: nil, enabled: false, companyCode: "EZY"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let features = json["features"] as! [[String: Any]]
        XCTAssertEqual(features.count, 1)
        let properties = features[0]["properties"] as! [String: Any]
        XCTAssertEqual(properties["key"] as? String, "EZY123")
        XCTAssertEqual(properties["company"] as? Bool, true)
        XCTAssertEqual(properties["showLabel"] as? Bool, true)
        XCTAssertEqual(AppState.companyCode(override: "", callsign: "ezy128w"), "EZY")
        XCTAssertEqual(AppState.companyCode(override: " baw ", callsign: nil), "BAW")
        XCTAssertNil(AppState.companyCode(override: "EZY123", callsign: "BAW1"))
        XCTAssertNil(VatsimPilot.airlineCode("N123AB"))
    }

    @MainActor func testDismantlingChartFlushesInkBeforeTheDebounce() throws {
        let key = "save-regression-\(UUID().uuidString)"
        defer { AnnotationStore.save(PKDrawing(), key: key) }
        let view = ChartScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { _ in UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 400)) }
        view.show(image: image, dark: false, key: key)
        view.setAnnotations(key: key, chartSize: CGSize(width: 400, height: 400))
        view.layoutIfNeeded()
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first?.subviews.compactMap { $0 as? PKCanvasView }.first)
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 80)].enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) / 10, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        view.canvasViewDrawingDidChange(canvas)
        ZoomableChartView.dismantleUIView(view, coordinator: ())
        XCTAssertEqual(AnnotationStore.load(key)?.strokes.count, 1)
    }
}
