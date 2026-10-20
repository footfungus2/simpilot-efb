import CoreLocation
import Foundation

/// The bundled airport list (Basemap/airports.geojson), for finding which airport the map is looking at.
enum AirportIndex {
    struct Airport {
        let icao: String
        let coordinate: CLLocationCoordinate2D
    }

    static let all: [Airport] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Basemap/airports.geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { f in
            guard let icao = (f["properties"] as? [String: Any])?["icao"] as? String,
                  let c = (f["geometry"] as? [String: Any])?["coordinates"] as? [Double], c.count == 2 else { return nil }
            return Airport(icao: icao, coordinate: CLLocationCoordinate2D(latitude: c[1], longitude: c[0]))
        }
    }()

    static func nearest(to c: CLLocationCoordinate2D, withinKm km: Double) -> String? {
        let cosLat = cos(c.latitude * .pi / 180)
        var best: (String, Double)?
        for a in all {
            let dx = (a.coordinate.longitude - c.longitude) * cosLat * 111.32
            let dy = (a.coordinate.latitude - c.latitude) * 111.32
            let d = hypot(dx, dy)
            if d <= km, best == nil || d < best!.1 { best = (a.icao, d) }
        }
        return best?.0
    }
}
