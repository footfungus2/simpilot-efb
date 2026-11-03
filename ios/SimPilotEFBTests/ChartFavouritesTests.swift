import XCTest
@testable import SimPilotEFB

@MainActor
final class ChartFavouritesTests: XCTestCase {
    private func store() -> (ChartFavourites, UserDefaults) {
        let defaults = UserDefaults(suiteName: "chart-fav-\(UUID().uuidString)")!
        return (ChartFavourites(defaults: defaults), defaults)
    }

    private func ref(_ i: Int, icao: String = "EGSS") -> ChartRef {
        ChartRef(icao: icao, guid: "g\(i)", name: "Chart \(i)", type: "SID")
    }

    func testRecentsAreUniqueNewestFirstAndCapped() {
        let (favourites, _) = store()
        for i in 0..<15 { favourites.recordOpen(ref(i)) }
        favourites.recordOpen(ref(10)) // opened again: moves to the front, no duplicate
        XCTAssertEqual(favourites.recents.count, ChartFavourites.recentLimit)
        XCTAssertEqual(favourites.recents.first?.guid, "g10")
        XCTAssertEqual(Set(favourites.recents.map(\.guid)).count, ChartFavourites.recentLimit)
        XCTAssertFalse(favourites.recents.contains { $0.guid == "g0" }) // the oldest fell off
    }

    func testStarsToggleAndSurviveARestart() {
        let (favourites, defaults) = store()
        favourites.toggle(ref(1, icao: "LIRA"))
        XCTAssertTrue(favourites.isFavourite("g1"))
        let again = ChartFavourites(defaults: defaults)
        XCTAssertEqual(again.favourites.map(\.icao), ["LIRA"])
        again.toggle(ref(1, icao: "LIRA"))
        XCTAssertFalse(again.isFavourite("g1"))
        XCTAssertTrue(ChartFavourites(defaults: defaults).favourites.isEmpty)
    }
}
