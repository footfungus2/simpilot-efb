import CoreLocation
import Foundation

/// The airways the planned route follows, one run per airway, for labelling along the route line. They come from the
/// SimBrief navlog (the airway used to reach each fix), so only the airways of this flight are known.
enum RouteAirways {
    struct Run: Equatable {
        let name: String
        let coordinates: [CLLocationCoordinate2D]

        static func == (a: Run, b: Run) -> Bool {
            a.name == b.name && a.coordinates.count == b.coordinates.count
                && zip(a.coordinates, b.coordinates).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
    }

    static func runs(in ofp: Ofp) -> [Run] {
        var runs: [Run] = []
        var current: (name: String, coordinates: [CLLocationCoordinate2D])?
        var previous = ofp.origin.coordinate
        func flush() {
            if let current, current.coordinates.count >= 2 { runs.append(Run(name: current.name, coordinates: current.coordinates)) }
            current = nil
        }
        for fix in ofp.navlog {
            let name = fix.airway.trimmingCharacters(in: .whitespaces)
            // SIDs and STARs are procedures, "DCT" is no airway.
            if !fix.isSidStar, !name.isEmpty, name.uppercased() != "DCT" {
                if current?.name == name {
                    current?.coordinates.append(fix.coordinate)
                } else {
                    flush()
                    current = (name, [previous, fix.coordinate])
                }
            } else {
                flush()
            }
            previous = fix.coordinate
        }
        flush()
        return runs
    }
}
