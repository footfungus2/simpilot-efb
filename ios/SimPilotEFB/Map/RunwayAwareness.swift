import CoreLocation
import Foundation

/// Runway geometry for one airport, built from the airport-map features, plus mPilot-style awareness:
/// "ON RWY 04-22" when the aircraft is on a runway, "APRCH RWY 22" when it's established on final.
struct RunwayAwareness {
    struct Runway {
        let a: CLLocationCoordinate2D, b: CLLocationCoordinate2D // centreline ends
        let refA: String, refB: String                           // designators at a and b
        let widthM: Double
    }

    enum Status: Equatable {
        case onRunway(String)   // "04-22"
        case approaching(String) // "22"

        var text: String {
            switch self {
            case let .onRunway(r): return "ON RWY \(r)"
            case let .approaching(r): return "APRCH RWY \(r)"
            }
        }

        /// Runway end badges to show green on the airport map.
        var activeRefs: [String] {
            switch self {
            case let .onRunway(r): return r.components(separatedBy: "-")
            case let .approaching(r): return [r]
            }
        }
    }

    let runways: [Runway]

    init(features: [[String: Any]]) {
        typealias Coord = [Double]
        func coords(_ f: [String: Any]) -> [Coord]? { (f["geometry"] as? [String: Any])?["coordinates"] as? [Coord] }
        func kind(_ f: [String: Any]) -> String? { (f["properties"] as? [String: Any])?["kind"] as? String }
        let ends: [(Coord, String)] = features.compactMap { f in
            guard kind(f) == "runway-end", let c = (f["geometry"] as? [String: Any])?["coordinates"] as? Coord,
                  let ref = (f["properties"] as? [String: Any])?["ref"] as? String, !ref.hasPrefix("H") else { return nil }
            return (c, ref)
        }
        let widths: [(Coord, Double)] = features.compactMap { f in
            guard kind(f) == "runway-surface", let c = coords(f)?.first,
                  let w = (f["properties"] as? [String: Any])?["width"] as? Double else { return nil }
            return (c, w)
        }
        func ref(at c: Coord) -> String? { ends.first { $0.0 == c }?.1 }
        runways = features.compactMap { f in
            guard kind(f) == "runway-centerline", let line = coords(f), let first = line.first, let last = line.last,
                  let ra = ref(at: first), let rb = ref(at: last) else { return nil }
            let width = widths.first { $0.0 == first }?.1 ?? 45
            return Runway(a: CLLocationCoordinate2D(latitude: first[1], longitude: first[0]),
                          b: CLLocationCoordinate2D(latitude: last[1], longitude: last[0]),
                          refA: ra, refB: rb, widthM: width)
        }
    }

    func status(_ o: Ownship) -> Status? {
        for r in runways {
            let (along, cross, length) = Self.project(o.coordinate, r.a, r.b)
            if o.onGround {
                if along >= -30, along <= length + 30, abs(cross) <= r.widthM / 2 + 10 {
                    return .onRunway("\(r.refA)-\(r.refB)")
                }
                continue
            }
            // Established on final: below 5000 ft, descending, within 8 NM before the threshold,
            // tracking within 20° of the runway and within ~0.6 NM of the extended centreline.
            guard o.altFt < 5000, o.vsFpm < -100 else { continue }
            for (thr, far, ref) in [(r.a, r.b, r.refA), (r.b, r.a, r.refB)] {
                let (alongT, crossT, _) = Self.project(o.coordinate, thr, far)
                let heading = Self.bearing(thr, far)
                let trackDiff = abs(((o.trkDeg - heading) + 540).truncatingRemainder(dividingBy: 360) - 180)
                if alongT < 0, alongT > -8 * 1852, abs(crossT) < 1100, trackDiff < 20 {
                    return .approaching(ref)
                }
            }
        }
        return nil
    }

    /// Along-track and cross-track metres of `p` relative to the line a→b (local flat approximation), and its length.
    static func project(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (Double, Double, Double) {
        let k = cos(a.latitude * .pi / 180) * 111_320
        let bx = (b.longitude - a.longitude) * k, by = (b.latitude - a.latitude) * 111_320
        let px = (p.longitude - a.longitude) * k, py = (p.latitude - a.latitude) * 111_320
        let len = hypot(bx, by)
        guard len > 0 else { return (0, 0, 0) }
        let ux = bx / len, uy = by / len
        return (px * ux + py * uy, px * uy - py * ux, len)
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180, Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2), x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
