import XCTest
@testable import SimPilotEFB

final class FlightPhaseDetectorTests: XCTestCase {
    private func feed(_ d: inout FlightPhaseDetector, _ seconds: Double, ground: Bool, gs: Double = 0) -> FlightPhaseDetector.Event? {
        d.feed(ts: seconds * 1000, onGround: ground, gsKt: gs)
    }

    func testTakeoffNeedsAHeldChangeAndSpeed() {
        var d = FlightPhaseDetector()
        XCTAssertNil(feed(&d, 0, ground: true))
        XCTAssertNil(feed(&d, 10, ground: false, gs: 140)) // starts the change
        XCTAssertNil(feed(&d, 14, ground: false, gs: 150)) // not held long enough yet
        XCTAssertEqual(feed(&d, 19, ground: false, gs: 160), .takeoff(Date(timeIntervalSince1970: 10)))
    }

    func testABounceOnTheRunwayIsIgnored() {
        var d = FlightPhaseDetector()
        _ = feed(&d, 0, ground: true)
        XCTAssertNil(feed(&d, 5, ground: false, gs: 30))
        XCTAssertNil(feed(&d, 8, ground: true))
        XCTAssertNil(feed(&d, 30, ground: true))
    }

    func testSlowAirborneSamplesDoNotCountAsATakeoff() {
        var d = FlightPhaseDetector()
        _ = feed(&d, 0, ground: true)
        _ = feed(&d, 5, ground: false, gs: 10) // e.g. the sim being repositioned
        XCTAssertNil(feed(&d, 30, ground: false, gs: 10))
    }

    func testLandingIsReportedAtTheTouchdownTime() {
        var d = FlightPhaseDetector()
        _ = feed(&d, 0, ground: false, gs: 250) // app started in flight: no event
        XCTAssertNil(feed(&d, 100, ground: true, gs: 130))
        XCTAssertEqual(feed(&d, 110, ground: true, gs: 60), .landing(Date(timeIntervalSince1970: 100)))
    }
}

@MainActor
final class FlightToolsStoreTests: XCTestCase {
    private func makeStore(_ name: String = UUID().uuidString) -> (FlightToolsStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flight-tools-\(name).json")
        try? FileManager.default.removeItem(at: url)
        return (FlightToolsStore(url: url), url)
    }

    func testChecklistProgressIsPerFlight() {
        let (store, _) = makeStore()
        let item = store.data.checklists[0].items[0]
        store.toggle(item, flight: "A")
        XCTAssertTrue(store.ticked("A").contains(item.id.uuidString))
        XCTAssertTrue(store.ticked("B").isEmpty)
        store.resetTicks(store.data.checklists[0], flight: "A")
        XCTAssertTrue(store.ticked("A").isEmpty)
    }

    func testClearancesKeepNewestFirstAndIgnoreEmptyOnes() {
        let (store, _) = makeStore()
        store.addClearance(ClearanceEntry(), flight: "A")
        XCTAssertTrue(store.clearances("A").isEmpty)
        store.addClearance(ClearanceEntry(altitude: "FL240"), flight: "A")
        store.addClearance(ClearanceEntry(squawk: "4521"), flight: "A")
        XCTAssertEqual(store.clearances("A").map(\.squawk), ["4521", ""])
    }

    func testSavedDataComesBack() {
        let (store, url) = makeStore()
        store.setMinima(Minima(approach: "ILS 22", decision: "200", visibility: "550"), flight: "A", icao: "LIRA")
        var entry = LogEntry()
        entry.origin = "EGSS"
        store.upsert(entry)
        store.saveNow()
        let reloaded = FlightToolsStore(url: url)
        XCTAssertEqual(reloaded.minima(flight: "A", icao: "LIRA").decision, "200")
        XCTAssertEqual(reloaded.data.log.map(\.origin), ["EGSS"])
    }

    func testTakeoffAndLandingMakeOneLogEntry() {
        let (store, _) = makeStore()
        func sample(_ s: Double, ground: Bool, gs: Double) -> Ownship {
            Ownship(lat: 51.9, lon: 0.2, altFt: 0, gsKt: gs, trkDeg: 0, hdgDeg: 0, vsFpm: 0, onGround: ground, magVarDeg: 0, ts: s * 1000)
        }
        store.observe(sample(0, ground: true, gs: 0), ofp: nil, aircraftTitle: "Fenix A320")
        store.observe(sample(10, ground: false, gs: 150), ofp: nil, aircraftTitle: "Fenix A320")
        store.observe(sample(20, ground: false, gs: 160), ofp: nil, aircraftTitle: "Fenix A320")
        XCTAssertEqual(store.data.log.count, 1)
        XCTAssertNotNil(store.data.log[0].takeoff)
        XCTAssertNil(store.data.log[0].landing)
        store.observe(sample(3_000, ground: true, gs: 120), ofp: nil, aircraftTitle: "Fenix A320")
        store.observe(sample(3_010, ground: true, gs: 40), ofp: nil, aircraftTitle: "Fenix A320")
        XCTAssertEqual(store.data.log.count, 1)
        XCTAssertNotNil(store.data.log[0].landing)
    }
}

@MainActor
final class FuelCheckTests: XCTestCase {
    /// A straight route north along the 0° meridian: one degree of latitude is 60 NM, so along-track = (lat − 50) × 60.
    private func ofp() -> Ofp {
        func fix(_ ident: String, lat: Double, cum: Double, fuel: Double, type: String = "wpt") -> OfpFix {
            OfpFix(ident: ident, name: ident, type: type, lat: lat, lon: 0, altFt: 0, airway: "", stage: "", isSidStar: false,
                   legNm: 0, cumNm: cum, frequency: "", fuelPlanKg: fuel)
        }
        let airport = OfpAirport(icao: "AAAA", iata: "", name: "", lat: 50, lon: 0, elevFt: 0, planRwy: "", metar: "")
        return Ofp(fetchedAt: 0, airac: "", callsign: "TST1", aircraft: .init(icao: "A320", name: "A320", reg: ""),
                   origin: airport, destination: airport, alternates: [], route: "", distanceNm: 120, cruiseFl: 300, costIndex: "",
                   times: .init(schedOut: 0, schedOff: 0, schedOn: 0, schedIn: 0, eteSec: 0),
                   fuel: .init(units: "kgs", ramp: 0, takeoff: 0, landing: 0, minTakeoff: 0),
                   navlog: [fix("AAAA", lat: 50, cum: 0, fuel: 6000, type: "apt"), fix("W1", lat: 51, cum: 60, fuel: 5400), fix("W2", lat: 52, cum: 120, fuel: 4800)],
                   ofpHtml: "", pdfUrl: nil)
    }

    private func sample(lat: Double, fuel: Double?, ts: Double) -> Ownship {
        Ownship(lat: lat, lon: 0, altFt: 30000, gsKt: 450, trkDeg: 0, hdgDeg: 0, vsFpm: 0, onGround: false, magVarDeg: 0, ts: ts, fuelKg: fuel)
    }

    func testPlannedFuelIsInterpolatedAlongTheRoute() {
        XCTAssertEqual(FuelCheck.planned(ofp: ofp(), alongNm: 30)!, 5700, accuracy: 0.01)
        XCTAssertEqual(FuelCheck.planned(ofp: ofp(), alongNm: 90)!, 5100, accuracy: 0.01)
        XCTAssertEqual(FuelCheck.planned(ofp: ofp(), alongNm: 500)!, 4800, accuracy: 0.01)
    }

    func testDifferenceFromPlan() {
        let check = FuelCheck(ofp: ofp(), ownship: sample(lat: 50.5, fuel: 5800, ts: 0))
        XCTAssertEqual(check?.deltaKg ?? 0, 100, accuracy: 0.5)
        XCTAssertNil(FuelCheck(ofp: ofp(), ownship: sample(lat: 50.5, fuel: nil, ts: 0)))
        XCTAssertNil(FuelCheck(ofp: ofp(), ownship: sample(lat: 50.5, fuel: 0, ts: 0)))
    }

    func testEachWaypointIsNotedOnceWithTheFuelAtThatMoment() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fuel-\(UUID().uuidString).json")
        let store = FlightToolsStore(url: url)
        let plan = ofp()
        store.observe(sample(lat: 50.5, fuel: 5800, ts: 1_000), ofp: plan, aircraftTitle: nil, flight: "F")
        XCTAssertTrue((store.data.fuelPasses["F"] ?? []).isEmpty)
        store.observe(sample(lat: 51.1, fuel: 5350, ts: 5_000), ofp: plan, aircraftTitle: nil, flight: "F")
        store.observe(sample(lat: 51.2, fuel: 5300, ts: 9_000), ofp: plan, aircraftTitle: nil, flight: "F")
        let passes = store.data.fuelPasses["F"] ?? []
        XCTAssertEqual(passes.map(\.ident), ["W1"])
        XCTAssertEqual(passes.first?.actualKg, 5350)
        XCTAssertEqual(passes.first?.deltaKg ?? 0, -50, accuracy: 0.5)
    }

    func testStartingTheAppFarPastWaypointsDoesNotLogThem() {
        let store = FlightToolsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("fuel-\(UUID().uuidString).json"))
        store.observe(sample(lat: 51.9, fuel: 4900, ts: 1_000), ofp: ofp(), aircraftTitle: nil, flight: "F") // W1 is 54 NM behind
        XCTAssertTrue((store.data.fuelPasses["F"] ?? []).isEmpty)
    }
}

final class EditFlightRunwayTests: XCTestCase {
    func testRunwaysAreNormalised() {
        XCTAssertEqual(EditFlightSheet.runway("4"), "04")
        XCTAssertEqual(EditFlightSheet.runway(" rwy 4l "), "04L")
        XCTAssertEqual(EditFlightSheet.runway("22r"), "22R")
        XCTAssertEqual(EditFlightSheet.runway(""), "")
    }

    func testOnlyRealRunwaysAreAccepted() {
        XCTAssertTrue(EditFlightSheet.isRunway(""))
        XCTAssertTrue(EditFlightSheet.isRunway("04"))
        XCTAssertTrue(EditFlightSheet.isRunway("36L"))
        XCTAssertFalse(EditFlightSheet.isRunway("37"))
        XCTAssertFalse(EditFlightSheet.isRunway("00"))
        XCTAssertFalse(EditFlightSheet.isRunway("04X"))
        XCTAssertFalse(EditFlightSheet.isRunway("HELP"))
    }
}
