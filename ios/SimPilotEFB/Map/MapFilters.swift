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
    /// Grid MORA numbers (approximate, from open terrain data).
    var mora = false
    /// Altitude under each route waypoint, colour-coded by phase, plus T/C and T/D.
    var routeAltitudes = true

    init() {}

    // Filters saved by older builds lack newer keys; they keep the user's choices and default the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = try c.decodeIfPresent(Bool.self, forKey: .route) ?? true
        airports = try c.decodeIfPresent(Bool.self, forKey: .airports) ?? true
        firs = try c.decodeIfPresent(Bool.self, forKey: .firs) ?? true
        vor = try c.decodeIfPresent(Bool.self, forKey: .vor) ?? true
        ndb = try c.decodeIfPresent(Bool.self, forKey: .ndb) ?? false
        dme = try c.decodeIfPresent(Bool.self, forKey: .dme) ?? false
        navaidFrequencies = try c.decodeIfPresent(Bool.self, forKey: .navaidFrequencies) ?? false
        mora = try c.decodeIfPresent(Bool.self, forKey: .mora) ?? false
        routeAltitudes = try c.decodeIfPresent(Bool.self, forKey: .routeAltitudes) ?? true
    }

    /// Number of active groups, shown on the NAV button like mPilot's layer counts.
    var activeCount: Int { [route, airports, firs, vor, ndb, dme, mora].filter { $0 }.count }

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
