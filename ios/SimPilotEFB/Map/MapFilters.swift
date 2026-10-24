import CoreLocation
import Foundation

/// What the NAV layer box shows on the enroute map. Persisted between launches.
struct MapFilters: Codable, Equatable {
    var route = true
    var airports = true
    var firs = true
    var vor = true
    var ndb = false
    var dme = false
    var navaidFrequencies = false

    /// Number of active groups, shown on the NAV button like mPilot's layer counts.
    var activeCount: Int { [route, airports, firs, vor, ndb, dme].filter { $0 }.count }

    static func levels(high: Bool, cruise: Int) -> [Int] {
        let cruise = cruise > 0 ? max(60, cruise) : 350
        return high ? [cruise + 30, cruise, cruise - 60].map { $0 - $0 % 10 } : [190, 130, 70]
    }

    static func load() -> MapFilters {
        guard let data = UserDefaults.standard.data(forKey: "mapFilters"),
              let f = try? JSONDecoder().decode(MapFilters.self, from: data) else { return MapFilters() }
        return f
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "mapFilters") }
    }
}

/// Something tapped on the enroute/airport map: a route waypoint, a navaid or an airport.
struct MapPick: Equatable {
    enum Kind: String { case fix, navaid, airport }
    let kind: Kind
    let id: String
    let coordinate: CLLocationCoordinate2D
    let attributes: [String: String]

    static func == (a: MapPick, b: MapPick) -> Bool { a.kind == b.kind && a.id == b.id }
}
