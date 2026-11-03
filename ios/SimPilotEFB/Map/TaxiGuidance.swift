import CoreLocation
import Foundation

/// The ground layout of one airport, taken from its airport-map features: named taxiways, stands with their
/// lead-in lines, and holding points labelled by the taxiway and runway they belong to.
struct AirportGround {
    struct TaxiLine {
        let ref: String
        let points: [CLLocationCoordinate2D]
    }

    struct Stand: Identifiable, Equatable {
        let ref: String
        let coordinate: CLLocationCoordinate2D
        var id: String { ref }

        static func == (a: Stand, b: Stand) -> Bool { a.ref == b.ref && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude }
    }

    struct Hold: Identifiable {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        let label: String
    }

    private(set) var taxiLines: [TaxiLine] = []
    private(set) var stands: [Stand] = []
    private(set) var holds: [Hold] = []
    private var standLines: [[CLLocationCoordinate2D]] = []

    init() {}

    init(features: [[String: Any]]) {
        var runwayLines: [[CLLocationCoordinate2D]] = []
        var runwayEnds: [(ref: String, coordinate: CLLocationCoordinate2D)] = []
        var rawHolds: [CLLocationCoordinate2D] = []
        for feature in features {
            guard let props = feature["properties"] as? [String: Any], let kind = props["kind"] as? String,
                  let geometry = feature["geometry"] as? [String: Any] else { continue }
            switch kind {
            case "taxi-line":
                let ref = (props["ref"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if let line = Self.line(geometry) { taxiLines.append(TaxiLine(ref: ref, points: line)) }
            case "stand":
                let ref = (props["ref"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if !ref.isEmpty, let c = Self.point(geometry) { stands.append(Stand(ref: ref, coordinate: c)) }
            case "stand-line":
                if let line = Self.line(geometry) { standLines.append(line) }
            case "runway-centerline":
                if let line = Self.line(geometry) { runwayLines.append(line) }
            case "runway-end":
                if let c = Self.point(geometry), let ref = props["ref"] as? String, !ref.isEmpty { runwayEnds.append((ref, c)) }
            case "hold":
                if let c = Self.point(geometry) { rawHolds.append(c) }
            default: break
            }
        }

        // "04/22": the runway-end labels nearest to the two ends of each runway centreline.
        func pair(_ line: [CLLocationCoordinate2D]) -> String? {
            guard let a = line.first, let b = line.last else { return nil }
            func nearest(_ c: CLLocationCoordinate2D) -> String? {
                runwayEnds.min { Self.meters($0.coordinate, c) < Self.meters($1.coordinate, c) }.flatMap { Self.meters($0.coordinate, c) < 400 ? $0.ref : nil }
            }
            guard let x = nearest(a), let y = nearest(b), x != y else { return nil }
            return "\(x)/\(y)"
        }
        let runways = runwayLines.compactMap { line in pair(line).map { (name: $0, line: line) } }

        var labels: [String] = []
        for c in rawHolds {
            let taxiway = taxiLines.filter { !$0.ref.isEmpty }
                .map { ($0.ref, Self.distance(c, toLine: $0.points)) }.min { $0.1 < $1.1 }.flatMap { $0.1 <= 60 ? $0.0 : nil }
            let runway = runways.map { ($0.name, Self.distance(c, toLine: $0.line)) }.min { $0.1 < $1.1 }.flatMap { $0.1 <= 250 ? $0.0 : nil }
            switch (taxiway, runway) {
            case let (t?, r?): labels.append("\(t) · RWY \(r)")
            case let (t?, nil): labels.append(t)
            case let (nil, r?): labels.append("RWY \(r)")
            default: labels.append("Holding point")
            }
        }
        // Several holding points can share a label (both sides of a runway): number them in file order.
        var seen: [String: Int] = [:]
        for (i, c) in rawHolds.enumerated() {
            let base = labels[i]
            let total = labels.filter { $0 == base }.count
            seen[base, default: 0] += 1
            holds.append(Hold(id: i, coordinate: c, label: total > 1 ? "\(base) (\(seen[base]!))" : base))
        }
        stands.sort { $0.ref.localizedStandardCompare($1.ref) == .orderedAscending }
    }

    func stand(_ ref: String) -> Stand? { stands.first { $0.ref.caseInsensitiveCompare(ref) == .orderedSame } }

    func hold(_ id: Int) -> Hold? { holds.first { $0.id == id } }

    /// The lead-in line that ends at the stand.
    func leadIn(of stand: Stand) -> [CLLocationCoordinate2D]? {
        standLines.first { line in
            [line.first, line.last].contains { $0.map { Self.meters($0, stand.coordinate) < 3 } ?? false }
        }
    }

    /// Distance in metres to the nearest centreline of the taxiway called `ref`; infinity when it isn't known.
    func distance(from c: CLLocationCoordinate2D, toTaxiway ref: String) -> Double {
        taxiLines.filter { $0.ref.caseInsensitiveCompare(ref) == .orderedSame }
            .map { Self.distance(c, toLine: $0.points) }.min() ?? .infinity
    }

    // MARK: Geometry

    private static func point(_ geometry: [String: Any]) -> CLLocationCoordinate2D? {
        guard let c = geometry["coordinates"] as? [Double], c.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: c[1], longitude: c[0])
    }

    private static func line(_ geometry: [String: Any]) -> [CLLocationCoordinate2D]? {
        guard let coords = geometry["coordinates"] as? [[Double]], coords.count >= 2 else { return nil }
        let points = coords.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
        return points.count >= 2 ? points : nil
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let cosLat = cos(((a.latitude + b.latitude) / 2) * .pi / 180)
        return hypot((a.longitude - b.longitude) * cosLat * 111_320, (a.latitude - b.latitude) * 111_320)
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Metres from a point to the nearest segment of a line.
    static func distance(_ c: CLLocationCoordinate2D, toLine line: [CLLocationCoordinate2D]) -> Double {
        guard line.count >= 2 else { return .infinity }
        let cosLat = cos(c.latitude * .pi / 180)
        var best = Double.infinity
        for i in 0..<(line.count - 1) {
            let ax = (line[i].longitude - c.longitude) * cosLat * 111_320, ay = (line[i].latitude - c.latitude) * 111_320
            let bx = (line[i + 1].longitude - c.longitude) * cosLat * 111_320, by = (line[i + 1].latitude - c.latitude) * 111_320
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            best = min(best, hypot(ax + t * dx, ay + t * dy))
        }
        return best
    }
}

/// How far along the entered taxi route the aircraft is. The route is a list of taxiway names; the aircraft has
/// "reached" a taxiway when it is on it, and never goes back to an earlier one.
struct TaxiProgress: Equatable {
    /// Taxiways closer than this to the aircraft count as "on it" (metres).
    static let radiusM = 35.0

    /// Index in the route of the taxiway reached; every earlier one is done.
    private(set) var reached = 0
    /// On a taxiway of the route right now (false: somewhere off the route, or not yet on it).
    private(set) var onRoute = false

    mutating func update(route: [String], ground: AirportGround, position: CLLocationCoordinate2D) {
        guard !route.isEmpty else {
            self = TaxiProgress()
            return
        }
        reached = min(reached, route.count - 1)
        if let hit = route.indices.dropFirst(reached).first(where: { ground.distance(from: position, toTaxiway: route[$0]) <= Self.radiusM }) {
            reached = hit
            onRoute = true
        } else {
            onRoute = false
        }
    }

    func done(in route: [String]) -> [String] { Array(route.prefix(reached)) }
    func remaining(in route: [String]) -> [String] { Array(route.dropFirst(reached)) }
    func next(in route: [String]) -> String? { reached + 1 < route.count ? route[reached + 1] : nil }
}

/// The selected stand's lead-in and the chosen holding point as GeoJSON for the map's guidance layers.
enum TaxiGuidanceShapes {
    static func json(stand: AirportGround.Stand?, leadIn: [CLLocationCoordinate2D]?, hold: AirportGround.Hold?) -> Data? {
        var features: [[String: Any]] = []
        func feature(_ kind: String, _ geometry: [String: Any]) -> [String: Any] {
            ["type": "Feature", "properties": ["kind": kind], "geometry": geometry]
        }
        if let leadIn { features.append(feature("g-stand-line", ["type": "LineString", "coordinates": leadIn.map { [$0.longitude, $0.latitude] }])) }
        if let stand { features.append(feature("g-stand", ["type": "Point", "coordinates": [stand.coordinate.longitude, stand.coordinate.latitude]])) }
        if let hold { features.append(feature("g-hold", ["type": "Point", "coordinates": [hold.coordinate.longitude, hold.coordinate.latitude]])) }
        guard !features.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }
}
