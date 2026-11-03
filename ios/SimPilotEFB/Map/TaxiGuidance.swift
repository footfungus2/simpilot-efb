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
        /// The name on the airport chart ("N1", "H3"); empty when the map data has none.
        let name: String
        /// For lists: "N1 · RWY 04/22", "N3 · ILS", or the taxiway and runway when there is no name.
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
        var rawHolds: [(coordinate: CLLocationCoordinate2D, ref: String, type: String)] = []
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
                if let c = Self.point(geometry) {
                    rawHolds.append((c, (props["ref"] as? String ?? "").trimmingCharacters(in: .whitespaces).uppercased(), (props["type"] as? String ?? "").lowercased()))
                }
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
        for hold in rawHolds {
            let c = hold.coordinate
            let taxiway = taxiLines.filter { !$0.ref.isEmpty }
                .map { ($0.ref, Self.distance(c, toLine: $0.points)) }.min { $0.1 < $1.1 }.flatMap { $0.1 <= 60 ? $0.0 : nil }
            let runway = runways.map { ($0.name, Self.distance(c, toLine: $0.line)) }.min { $0.1 < $1.1 }.flatMap { $0.1 <= 250 ? $0.0 : nil }
            if !hold.ref.isEmpty {
                // A named holding point: its name, and what it protects.
                let what = hold.type == "ils" ? "ILS" : (runway.map { "RWY \($0)" } ?? "")
                labels.append(what.isEmpty ? hold.ref : "\(hold.ref) · \(what)")
                continue
            }
            switch (taxiway, runway) {
            case let (t?, r?): labels.append("\(t) · RWY \(r)")
            case let (t?, nil): labels.append(t)
            case let (nil, r?): labels.append("RWY \(r)")
            default: labels.append("Holding point")
            }
        }
        // Several holding points can share a label (both sides of a runway): number them in file order.
        var seen: [String: Int] = [:]
        for (i, hold) in rawHolds.enumerated() {
            let base = labels[i]
            let total = labels.filter { $0 == base }.count
            seen[base, default: 0] += 1
            holds.append(Hold(id: i, coordinate: hold.coordinate, name: hold.ref, label: total > 1 ? "\(base) (\(seen[base]!))" : base))
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
    static func json(stand: AirportGround.Stand?, leadIn: [CLLocationCoordinate2D]?, hold: AirportGround.Hold?,
                     routeDone: [CLLocationCoordinate2D] = [], routeTodo: [CLLocationCoordinate2D] = []) -> Data? {
        var features: [[String: Any]] = []
        func feature(_ kind: String, _ geometry: [String: Any]) -> [String: Any] {
            ["type": "Feature", "properties": ["kind": kind], "geometry": geometry]
        }
        if routeDone.count >= 2 { features.append(feature("g-route-done", ["type": "LineString", "coordinates": routeDone.map { [$0.longitude, $0.latitude] }])) }
        if routeTodo.count >= 2 { features.append(feature("g-route-todo", ["type": "LineString", "coordinates": routeTodo.map { [$0.longitude, $0.latitude] }])) }
        if let leadIn { features.append(feature("g-stand-line", ["type": "LineString", "coordinates": leadIn.map { [$0.longitude, $0.latitude] }])) }
        if let stand { features.append(feature("g-stand", ["type": "Point", "coordinates": [stand.coordinate.longitude, stand.coordinate.latitude]])) }
        if let hold { features.append(feature("g-hold", ["type": "Point", "coordinates": [hold.coordinate.longitude, hold.coordinate.latitude]])) }
        guard !features.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }
}

// MARK: - The path you will actually drive

/// The taxi route as one line: only the stretch of each named taxiway between the junctions you use, in driving order.
/// Taxiway names alone light up whole taxiways (a long parallel one in full); this follows the network instead.
struct TaxiPath: Equatable {
    let points: [CLLocationCoordinate2D]

    static func == (a: TaxiPath, b: TaxiPath) -> Bool {
        a.points.count == b.points.count && zip(a.points, b.points).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }

    /// The nearest point on the path to `position`: which segment it is on and how far away (metres).
    func nearest(to position: CLLocationCoordinate2D) -> (segment: Int, point: CLLocationCoordinate2D, meters: Double)? {
        guard points.count >= 2 else { return nil }
        let cosLat = cos(position.latitude * .pi / 180)
        var best: (segment: Int, point: CLLocationCoordinate2D, meters: Double)?
        for i in 0..<(points.count - 1) {
            let ax = (points[i].longitude - position.longitude) * cosLat * 111_320, ay = (points[i].latitude - position.latitude) * 111_320
            let bx = (points[i + 1].longitude - position.longitude) * cosLat * 111_320, by = (points[i + 1].latitude - position.latitude) * 111_320
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            let meters = hypot(ax + t * dx, ay + t * dy)
            if meters < (best?.meters ?? .infinity) {
                let p = CLLocationCoordinate2D(latitude: points[i].latitude + t * (points[i + 1].latitude - points[i].latitude),
                                               longitude: points[i].longitude + t * (points[i + 1].longitude - points[i].longitude))
                best = (i, p, meters)
            }
        }
        return best
    }

    /// The part already driven and the part still to go, split at the aircraft's position (when it is on the path).
    func split(at position: CLLocationCoordinate2D?) -> (done: [CLLocationCoordinate2D], todo: [CLLocationCoordinate2D]) {
        guard let position, let best = nearest(to: position), best.meters <= 40 else { return ([], points) }
        let done = Array(points[0...best.segment]) + [best.point]
        let todo = [best.point] + Array(points[(best.segment + 1)...])
        // Nothing driven yet / nothing left: no zero-length line.
        func usable(_ line: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
            zip(line, line.dropFirst()).contains { AirportGround.meters($0, $1) > 0.5 } ? line : []
        }
        return (usable(done), usable(todo))
    }

    /// The path cut off exactly at `target` (a holding point on it); nil when the target is not on the path.
    func truncated(at target: CLLocationCoordinate2D, within meters: Double = 25) -> TaxiPath? {
        guard let best = nearest(to: target), best.meters <= meters else { return nil }
        let kept = Array(points[0...best.segment]) + [best.point]
        let cleaned = kept.enumerated().filter { $0.offset == 0 || AirportGround.meters(kept[$0.offset - 1], $0.element) > 0.01 }.map(\.element)
        return cleaned.count >= 2 ? TaxiPath(points: cleaned) : nil
    }

    var meters: Double { zip(points, points.dropFirst()).reduce(0) { $0 + AirportGround.meters($1.0, $1.1) } }

    /// Corners rounded the way an aircraft turns instead of the sharp angle where two centrelines cross. Each corner is
    /// replaced by a curve that starts and ends before it (a quadratic curve with the corner as its control point).
    /// Straight stretches, the first point and the last point stay where they are.
    func smoothed(radius: Double = 20, minTurnDegrees: Double = 22) -> TaxiPath {
        guard points.count >= 3 else { return self }
        let cosLat = cos(points[0].latitude * .pi / 180)
        let origin = points[0]
        func xy(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) { ((c.longitude - origin.longitude) * cosLat * 111_320, (c.latitude - origin.latitude) * 111_320) }
        func coordinate(_ p: (x: Double, y: Double)) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: origin.latitude + p.y / 111_320, longitude: origin.longitude + p.x / (cosLat * 111_320))
        }
        let m = points.map(xy)
        var out: [CLLocationCoordinate2D] = [points[0]]
        for i in 1..<(points.count - 1) {
            let (a, b, c) = (m[i - 1], m[i], m[i + 1])
            let lenIn = hypot(b.x - a.x, b.y - a.y), lenOut = hypot(c.x - b.x, c.y - b.y)
            guard lenIn > 0.5, lenOut > 0.5 else { continue }
            let u = ((b.x - a.x) / lenIn, (b.y - a.y) / lenIn), v = ((c.x - b.x) / lenOut, (c.y - b.y) / lenOut)
            let cosTurn = max(-1, min(1, u.0 * v.0 + u.1 * v.1))
            let turn = acos(cosTurn) // 0 = straight on
            if turn < minTurnDegrees * .pi / 180 || turn > 175 * .pi / 180 {
                out.append(points[i])
                continue
            }
            // How far before and after the corner the curve begins: a turn of this radius, but never more than half a leg.
            let cut = min(radius * tan(turn / 2), 0.5 * lenIn, 0.5 * lenOut)
            let start = (x: b.x - u.0 * cut, y: b.y - u.1 * cut), end = (x: b.x + v.0 * cut, y: b.y + v.1 * cut)
            let steps = max(4, Int((turn * 180 / .pi) / 12))
            for k in 0...steps {
                let t = Double(k) / Double(steps)
                let p = (x: (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * b.x + t * t * end.x,
                         y: (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * b.y + t * t * end.y)
                out.append(coordinate(p))
            }
        }
        out.append(points[points.count - 1])
        return TaxiPath(points: out)
    }
}

/// A min-priority queue for the route search.
private struct MinHeap {
    private var items: [(cost: Double, state: Int)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ cost: Double, _ state: Int) {
        items.append((cost, state))
        var i = items.count - 1
        while i > 0, items[(i - 1) / 2].cost > items[i].cost {
            items.swapAt(i, (i - 1) / 2)
            i = (i - 1) / 2
        }
    }

    mutating func pop() -> (cost: Double, state: Int)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l].cost < items[m].cost { m = l }
                if r < items.count, items[r].cost < items[m].cost { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}

extension AirportGround {
    /// Cost of an unnamed connector relative to named taxiway: the same, and a fillet is shorter than the corner it cuts, so the route
    /// follows the mapped curve at a junction instead of going through the point where the centrelines cross.
    fileprivate static let connectorCost = 1.0
    /// ...and a part of the same taxiway under another name ("C" for "C EAST").
    fileprivate static let siblingCost = 1.4

    /// "C EAST" → "C": the name without a trailing compass word.
    static func familyName(_ name: String) -> String {
        let upper = name.trimmingCharacters(in: .whitespaces).uppercased()
        for word in [" EAST", " WEST", " NORTH", " SOUTH"] where upper.hasSuffix(word) && upper.count > word.count {
            return String(upper.dropLast(word.count))
        }
        return upper
    }

    /// The driving path for a list of taxiway names. `start` (where the aircraft is) picks which end of the first taxiway to
    /// begin; `end` (a holding point or stand) says where to stop on the last one, else it runs to that taxiway's far end.
    /// With `stopAtEnd` (a holding point) the line is cut off exactly at it, and corners are rounded.
    /// Nil when the names don't connect in that order (the map then falls back to lighting up the taxiways).
    func path(route: [String], start: CLLocationCoordinate2D?, end: CLLocationCoordinate2D?, stopAtEnd: Bool = false) -> TaxiPath? {
        // Points within 1.5 m are one vertex (OSM ways share their junction nodes, but not always exactly).
        var grid: [String: [Int]] = [:]
        var points: [CLLocationCoordinate2D] = []
        var nameIDs: [String: Int] = [:]
        // Edges with no taxiway name (name -1): the curved connectors between taxiways and the apron lanes. They can be
        // driven on the way from one named taxiway to the next, at a higher cost so the named ones are preferred.
        var adjacency: [[(to: Int, name: Int, length: Double)]] = []
        let cosLat = max(0.01, cos((taxiLines.first?.points.first?.latitude ?? 0) * .pi / 180))
        let cellLat = 1.4e-5, cellLon = 1.4e-5 / cosLat
        func vertex(_ c: CLLocationCoordinate2D) -> Int {
            let ci = Int((c.latitude / cellLat).rounded(.down)), cj = Int((c.longitude / cellLon).rounded(.down))
            for di in -1...1 {
                for dj in -1...1 {
                    for v in grid["\(ci + di),\(cj + dj)"] ?? [] where Self.meters(points[v], c) < 1.5 { return v }
                }
            }
            grid["\(ci),\(cj)", default: []].append(points.count)
            points.append(c)
            adjacency.append([])
            return points.count - 1
        }
        for line in taxiLines {
            let name = line.ref.trimmingCharacters(in: .whitespaces).uppercased()
            let id = name.isEmpty ? -1 : (nameIDs[name] ?? { nameIDs[name] = nameIDs.count; return nameIDs.count - 1 }())
            for k in 0..<(line.points.count - 1) {
                let a = vertex(line.points[k]), b = vertex(line.points[k + 1])
                guard a != b else { continue }
                let length = Self.meters(line.points[k], line.points[k + 1])
                adjacency[a].append((b, id, length))
                adjacency[b].append((a, id, length))
            }
        }
        let ids = route.compactMap { nameIDs[$0.trimmingCharacters(in: .whitespaces).uppercased()] }
        guard !route.isEmpty, ids.count == route.count else { return nil }
        let n = ids.count
        // "C", "C EAST" and "C WEST" are one taxiway mapped in parts under different names: they may stand in for each other
        // on the way from one named taxiway of the route to the next (at a higher cost than the exact name).
        var familyOf = [String](repeating: "", count: nameIDs.count)
        for (name, id) in nameIDs { familyOf[id] = Self.familyName(name) }

        // State = (vertex, index of the taxiway being driven). Driving along taxiway i keeps i; taking an edge of taxiway
        // i + 1 at a junction moves on to it; unnamed connectors keep i.
        func search(from starts: [Int]) -> [CLLocationCoordinate2D]? {
            var cost = [Double](repeating: .infinity, count: points.count * n)
            var previous = [Int](repeating: -1, count: points.count * n)
            var heap = MinHeap()
            for v in starts {
                cost[v * n] = 0
                heap.push(0, v * n)
            }
            while let (c, state) = heap.pop() {
                if c > cost[state] { continue }
                let v = state / n, i = state % n
                let behind = previous[state] >= 0 ? previous[state] / n : -1
                for edge in adjacency[v] where edge.to != behind { // no turning round on the spot
                    for next in [i, i + 1] where next < n {
                        let exact = edge.name == ids[next]
                        let sibling = !exact && edge.name >= 0 && familyOf[edge.name] == familyOf[ids[next]]
                        let connector = edge.name == -1 && next == i
                        guard exact || sibling || connector else { continue }
                        let target = edge.to * n + next
                        let total = c + edge.length * (exact ? 1 : sibling ? Self.siblingCost : Self.connectorCost)
                        if total < cost[target] {
                            cost[target] = total
                            previous[target] = state
                            heap.push(total, target)
                        }
                    }
                }
            }
            func extract(_ goal: Int) -> [CLLocationCoordinate2D] {
                var path: [CLLocationCoordinate2D] = []
                var state = goal * n + n - 1
                while state >= 0 {
                    path.append(points[state / n])
                    state = previous[state]
                }
                return path.reversed()
            }
            let reachable = points.indices.filter { cost[$0 * n + n - 1] < .infinity && adjacency[$0].contains { $0.name == ids[n - 1] } }
            guard !reachable.isEmpty else { return nil }
            if let end {
                // Stop where the hold or stand is: of the points of the last taxiway near it, the shortest route that passes it.
                let near = reachable.filter { Self.meters(points[$0], end) <= 400 }.sorted { Self.meters(points[$0], end) < Self.meters(points[$1], end) }.prefix(4)
                let paths = near.map { extract($0) }
                let passing = paths.filter { TaxiPath(points: $0).nearest(to: end).map { $0.meters <= 25 } ?? false }
                if let best = passing.min(by: { TaxiPath(points: $0).meters < TaxiPath(points: $1).meters }) ?? paths.first { return best }
            }
            // No hold or stand given: to the far end of the last taxiway (a vertex with a single edge of that taxiway).
            let ends = reachable.filter { v in adjacency[v].filter { $0.name == ids[n - 1] }.count == 1 }
            return extract((ends.isEmpty ? reachable : ends).max { cost[$0 * n + n - 1] < cost[$1 * n + n - 1] }!)
        }

        // With the aircraft's position, begin at the vertex of the first taxiway nearest to it. Without it nobody knows
        // which way the aircraft will join, so show the first taxiway from whichever end gives the longer route.
        let starts = points.indices.filter { v in adjacency[v].contains(where: { $0.name == ids[0] }) }
        guard !starts.isEmpty else { return nil }
        var found: [CLLocationCoordinate2D]?
        if let start, let nearest = starts.min(by: { Self.meters(points[$0], start) < Self.meters(points[$1], start) }) {
            found = search(from: [nearest])
        } else {
            let first = starts.filter { v in adjacency[v].filter { $0.name == ids[0] }.count == 1 }
            let candidates = (first.isEmpty ? starts : first).compactMap { search(from: [$0]) }
            found = candidates.max { TaxiPath(points: $0).meters < TaxiPath(points: $1).meters }
        }
        guard let raw = found else { return nil }
        // Back-and-forth over the same vertex (a switch of taxiway at a junction) is no real movement.
        var cleaned: [CLLocationCoordinate2D] = []
        for p in raw where !(cleaned.last.map { Self.meters($0, p) < 0.01 } ?? false) { cleaned.append(p) }
        guard cleaned.count >= 2 else { return nil }
        var path = TaxiPath(points: cleaned)
        if stopAtEnd, let end, let cut = path.truncated(at: end) { path = cut }
        return path.smoothed()
    }
}
