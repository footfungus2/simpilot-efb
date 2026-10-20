import CoreLocation
import Foundation

/// Where the aircraft is along the planned (OFP) route, and what's next: waypoint, top of descent, destination.
struct RouteProgress {
    struct Leg {
        let name: String
        let distanceNm: Double
        let eta: Date?
    }

    let next: Leg?
    let topOfDescent: Leg?
    let destination: Leg

    init?(ofp: Ofp, ownship o: Ownship, now: Date = Date()) {
        guard let along = Self.alongTrackNm(ofp: ofp, o) else { return nil }
        let total = max(ofp.navlog.last?.cumNm ?? ofp.distanceNm, along)
        func leg(_ name: String, _ nm: Double) -> Leg {
            // ETAs need a sensible groundspeed; on the ground they'd be meaningless.
            Leg(name: name, distanceNm: max(nm, 0), eta: o.gsKt > 50 ? now.addingTimeInterval(max(nm, 0) / o.gsKt * 3600) : nil)
        }
        next = ofp.navlog
            .first { $0.cumNm > along + 0.3 && $0.type != "apt" && $0.ident != "TOC" && $0.ident != "TOD" }
            .map { leg($0.ident, $0.cumNm - along) }
        topOfDescent = ofp.navlog.first { $0.ident == "TOD" && $0.cumNm > along }.map { leg("TOD", $0.cumNm - along) }
        destination = leg(ofp.destination.icao, total - along)
    }

    /// Distance flown along the planned route: closest point on any leg, plus that leg's start distance.
    static func alongTrackNm(ofp: Ofp, _ o: Ownship) -> Double? {
        var points: [(CLLocationCoordinate2D, Double)] = [(ofp.origin.coordinate, 0)]
        points += ofp.navlog.map { ($0.coordinate, $0.cumNm) }
        guard points.count >= 2 else { return nil }
        let cosLat = cos(o.lat * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) { (c.longitude * 60 * cosLat, c.latitude * 60) } // NM, local flat approx
        let p = xy(o.coordinate)
        var best: (dist: Double, along: Double)?
        for i in 0..<(points.count - 1) {
            let a = xy(points[i].0), b = xy(points[i + 1].0)
            let dx = b.0 - a.0, dy = b.1 - a.1
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2)) : 0
            let cx = a.0 + t * dx, cy = a.1 + t * dy
            let d = hypot(p.0 - cx, p.1 - cy)
            let along = points[i].1 + t * (points[i + 1].1 - points[i].1)
            if best == nil || d < best!.dist { best = (d, along) }
        }
        // More than 100 NM off the route: don't pretend to know where we are on the profile.
        guard let best, best.dist < 100 else { return nil }
        return best.along
    }
}
