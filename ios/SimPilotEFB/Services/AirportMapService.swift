import CoreLocation
import Foundation

/// Airport moving map data from OpenStreetMap (Overpass API), converted into GeoJSON the map styles as an
/// mPilot-like AMM: pavement areas, runway markings, taxiway centrelines and names, stands, holding points.
/// Only aeroway features and buildings are requested, so no roads appear. Results are cached on disk.
enum AirportMapService {
    /// The main Overpass server first, then public mirrors — the main one rate-limits and is sometimes overloaded.
    private static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ].compactMap(URL.init(string:))
    private static let cacheTTL: TimeInterval = 30 * 24 * 3600

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// GeoJSON features (as dictionaries) for one airport: fresh cache → Overpass (with mirrors) →
    /// any older cached copy, so a server outage never leaves the ground map empty.
    static func features(icao: String) async throws -> [[String: Any]] {
        let file = cacheURL(icao)
        if let age = cacheAge(file), age < cacheTTL, let cached = readCache(file) { return fixStands(cached) }
        // Caches written before the move to Application Support (iOS may purge Caches when storage is low).
        if let age = cacheAge(oldCacheURL(icao)), age < cacheTTL, let cached = readCache(oldCacheURL(icao)) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: oldCacheURL(icao), to: file)
            return fixStands(cached)
        }

        do {
            let elements = try await download(icao: icao)
            let feats = fixStands(convert(elements, icao: icao))
            if !feats.isEmpty, let out = try? JSONSerialization.data(withJSONObject: feats) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? out.write(to: file, options: .atomic)
            }
            return feats
        } catch {
            // Offline or every server busy: use an expired copy, or the previous format (still draws fine).
            if let stale = readCache(file) ?? readCache(oldCacheURL(icao)) { return fixStands(stale) }
            if let legacy = readCache(legacyCacheURL(icao)) { return fixStands(upgradeLegacy(legacy)) }
            throw error
        }
    }

    /// Main Overpass server, then the OpenStreetMap API (a separate service, so it still works when Overpass
    /// rate-limits or is down), then the Overpass mirrors.
    private static func download(icao: String) async throws -> [[String: Any]] {
        var lastError: Error = Failure(message: "Airport map for \(icao) unavailable")
        if !overpassDown.isSet {
            do { return try await overpass(icao: icao, endpoint: endpoints[0]) } catch {
                lastError = error
                overpassDown.set(for: 600) // don't make every airport wait on a blocked server
            }
        }
        do { return try await osmAPI(icao: icao) } catch { lastError = error }
        for endpoint in endpoints.dropFirst() {
            do { return try await overpass(icao: icao, endpoint: endpoint) } catch { lastError = error }
        }
        throw lastError
    }

    private static let overpassDown = Backoff()

    /// Thread-safe "skip until" flag (downloads for several airports run at once).
    private final class Backoff {
        private let lock = NSLock()
        private var until = Date.distantPast
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return Date() < until }
        func set(for seconds: TimeInterval) { lock.lock(); until = Date().addingTimeInterval(seconds); lock.unlock() }
    }

    private static func overpass(icao: String, endpoint: URL) async throws -> [[String: Any]] {
        let query = """
        [out:json][timeout:60];
        area["aeroway"="aerodrome"]["icao"="\(icao)"]->.a;
        (way(area.a)["aeroway"~"^(runway|taxiway|taxilane|apron|parking_position|stopway|hangar|terminal)$"];
         relation(area.a)["aeroway"="apron"];
         way(area.a)["building"];
         node(area.a)["aeroway"~"^(parking_position|holding_position|windsock)$"];);
        out geom;
        """
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query)]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        req.timeoutInterval = 20 // a hung server shouldn't block the fallbacks
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]], !elements.isEmpty else {
            throw Failure(message: "Airport map for \(icao): \(endpoint.host ?? "server") returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return elements
    }

    private static let userAgent = "SimPilotEFB/0.1 (personal flight-sim EFB)"

    // MARK: - OpenStreetMap API fallback

    /// Downloads the raw OSM data around the airport from api.openstreetmap.org in tiles, keeps the same features
    /// the Overpass query asks for (inside the aerodrome boundary) and returns them in Overpass `out geom` form.
    private static func osmAPI(icao: String) async throws -> [[String: Any]] {
        guard let center = AirportIndex.all.first(where: { $0.icao == icao })?.coordinate else {
            throw Failure(message: "Airport map for \(icao): unknown airport position")
        }
        let radiusKm = 3.5
        let dLat = radiusKm / 111.32, dLon = radiusKm / (111.32 * cos(center.latitude * .pi / 180))
        let box = (minLon: center.longitude - dLon, minLat: center.latitude - dLat,
                   maxLon: center.longitude + dLon, maxLat: center.latitude + dLat)
        // 2×2 tiles keep each request well under the API's 50 000-node limit; dense tiles split again.
        let midLon = (box.minLon + box.maxLon) / 2, midLat = (box.minLat + box.maxLat) / 2
        let tiles = [(box.minLon, box.minLat, midLon, midLat), (midLon, box.minLat, box.maxLon, midLat),
                     (box.minLon, midLat, midLon, box.maxLat), (midLon, midLat, box.maxLon, box.maxLat)]
        let raw = try await withThrowingTaskGroup(of: [[String: Any]].self) { group -> [[String: Any]] in
            for t in tiles { group.addTask { try await osmTile(t, depth: 0) } }
            var all: [[String: Any]] = []
            for try await part in group { all += part }
            return all
        }

        var nodes: [Int: [String: Any]] = [:], ways: [Int: [String: Any]] = [:], relations: [Int: [String: Any]] = [:]
        for e in raw {
            guard let id = e["id"] as? Int else { continue }
            switch e["type"] as? String {
            case "node": nodes[id] = e
            case "way": ways[id] = e
            case "relation": relations[id] = e
            default: break
            }
        }
        func geom(_ way: [String: Any]) -> [[String: Double]]? {
            let pts = (way["nodes"] as? [Int] ?? []).compactMap { ref -> [String: Double]? in
                guard let n = nodes[ref], let lat = n["lat"] as? Double, let lon = n["lon"] as? Double else { return nil }
                return ["lat": lat, "lon": lon]
            }
            return pts.count >= 2 ? pts : nil
        }
        func tags(_ e: [String: Any]) -> [String: String] { e["tags"] as? [String: String] ?? [:] }

        // Aerodrome boundary: prefer the one tagged with this ICAO code.
        let aerodromeWays = ways.values.filter { tags($0)["aeroway"] == "aerodrome" }
        let aerodromeRelWays = relations.values.filter { tags($0)["aeroway"] == "aerodrome" }.flatMap { r in
            (r["members"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "way" && $0["role"] as? String == "outer" }
                .compactMap { ($0["ref"] as? Int).flatMap { ways[$0] }.map { w -> [String: Any] in
                    var w = w; w["tags"] = r["tags"]; return w } }
        }
        let candidates = aerodromeWays + aerodromeRelWays
        let own = candidates.filter { tags($0)["icao"] == icao }
        // Only closed rings work as a boundary; a relation's outer ring split over several ways is skipped.
        let closed = (own.isEmpty ? candidates : own).filter { w in
            let refs = w["nodes"] as? [Int] ?? []
            return refs.count >= 4 && refs.first == refs.last
        }
        func contains(_ rings: [[[String: Double]]], _ p: [String: Double]) -> Bool {
            guard let x = p["lon"], let y = p["lat"] else { return false }
            return rings.contains { ring in
                var hit = false
                var j = ring.count - 1
                for i in 0..<ring.count {
                    let (xi, yi, xj, yj) = (ring[i]["lon"]!, ring[i]["lat"]!, ring[j]["lon"]!, ring[j]["lat"]!)
                    if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { hit.toggle() }
                    j = i
                }
                return hit
            }
        }
        // Use the boundary only if it actually contains the airport's reference point.
        let rings = closed.compactMap(geom)
        let boundary = contains(rings, ["lat": center.latitude, "lon": center.longitude]) ? rings : []
        func inside(_ p: [String: Double]) -> Bool { boundary.isEmpty || contains(boundary, p) }
        func centroid(_ g: [[String: Double]]) -> [String: Double] {
            ["lat": g.map { $0["lat"]! }.reduce(0, +) / Double(g.count), "lon": g.map { $0["lon"]! }.reduce(0, +) / Double(g.count)]
        }

        let wayKinds: Set = ["runway", "taxiway", "taxilane", "apron", "parking_position", "stopway", "hangar", "terminal"]
        let nodeKinds: Set = ["parking_position", "holding_position", "windsock"]
        var out: [[String: Any]] = []
        for w in ways.values {
            let t = tags(w)
            guard wayKinds.contains(t["aeroway"] ?? "") || t["building"] != nil, let g = geom(w), inside(centroid(g)) else { continue }
            out.append(["type": "way", "tags": t, "geometry": g])
        }
        for r in relations.values where tags(r)["aeroway"] == "apron" {
            let members = (r["members"] as? [[String: Any]] ?? []).compactMap { m -> [String: Any]? in
                guard m["type"] as? String == "way", let ref = m["ref"] as? Int, let w = ways[ref], let g = geom(w) else { return nil }
                return ["type": "way", "role": m["role"] as? String ?? "", "geometry": g]
            }
            if !members.isEmpty { out.append(["type": "relation", "tags": tags(r), "members": members]) }
        }
        for n in nodes.values {
            let t = tags(n)
            guard nodeKinds.contains(t["aeroway"] ?? ""), let lat = n["lat"] as? Double, let lon = n["lon"] as? Double,
                  inside(["lat": lat, "lon": lon]) else { continue }
            out.append(["type": "node", "tags": t, "lat": lat, "lon": lon])
        }
        guard out.contains(where: { tags($0)["aeroway"] == "runway" }) else {
            throw Failure(message: "Airport map for \(icao): no OpenStreetMap data")
        }
        return out
    }

    /// One bbox from the OSM API; a tile with too many nodes (HTTP 400) is split into four.
    private static func osmTile(_ b: (Double, Double, Double, Double), depth: Int) async throws -> [[String: Any]] {
        let bbox = String(format: "%.5f,%.5f,%.5f,%.5f", b.0, b.1, b.2, b.3)
        var req = URLRequest(url: URL(string: "https://api.openstreetmap.org/api/0.6/map.json?bbox=\(bbox)")!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400, depth < 2 {
            let mx = (b.0 + b.2) / 2, my = (b.1 + b.3) / 2
            var all: [[String: Any]] = []
            for t in [(b.0, b.1, mx, my), (mx, b.1, b.2, my), (b.0, my, mx, b.3), (mx, my, b.2, b.3)] {
                all += try await osmTile(t, depth: depth + 1)
            }
            return all
        }
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else {
            throw Failure(message: "Airport map: openstreetmap.org returned HTTP \(status)")
        }
        return elements
    }

    private static func cacheAge(_ file: URL) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    private static func readCache(_ file: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: file),
              let cached = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !cached.isEmpty else { return nil }
        return cached
    }

    /// Puts each stand at the right end of its lead-in line. OSM mappers draw parking_position lines in either
    /// direction, so "last point" is the stand only about 80 % of the time; the stand is the end farther from the
    /// taxiway/taxilane centrelines, and the symbol points along the lead-in towards it.
    static func fixStands(_ features: [[String: Any]]) -> [[String: Any]] {
        let taxiLines = features.compactMap { f -> [Coord]? in
            guard (f["properties"] as? [String: Any])?["kind"] as? String == "taxi-line" else { return nil }
            return (f["geometry"] as? [String: Any])?["coordinates"] as? [Coord]
        }
        guard !taxiLines.isEmpty else { return features }
        func key(_ c: Coord) -> String { String(format: "%.7f,%.7f", c[0], c[1]) }
        // Where each stand should go, keyed by the position the converter put it at (the line's last point).
        var moves: [String: (Coord, Double)] = [:]
        for f in features where (f["properties"] as? [String: Any])?["kind"] as? String == "stand-line" {
            guard let line = (f["geometry"] as? [String: Any])?["coordinates"] as? [Coord], line.count >= 2 else { continue }
            let first = line[0], last = line[line.count - 1]
            let standAtFirst = distanceToLines(first, taxiLines) > distanceToLines(last, taxiLines) + 2
            moves[key(last)] = standAtFirst ? (first, bearing(line[1], first)) : (last, bearing(line[line.count - 2], last))
        }
        return features.map { f in
            guard var props = f["properties"] as? [String: Any], props["kind"] as? String == "stand",
                  let c = (f["geometry"] as? [String: Any])?["coordinates"] as? Coord, let move = moves[key(c)] else { return f }
            props["rot"] = move.1
            return ["type": "Feature", "properties": props, "geometry": point(move.0)]
        }
    }

    /// Distance in metres from a point to the nearest segment of any line.
    private static func distanceToLines(_ c: Coord, _ lines: [[Coord]]) -> Double {
        let cosLat = cos(c[1] * .pi / 180)
        var best = Double.infinity
        for line in lines {
            for i in 0..<(line.count - 1) {
                let a = line[i], b = line[i + 1]
                let ax = (a[0] - c[0]) * cosLat * 111_320, ay = (a[1] - c[1]) * 111_320
                let bx = (b[0] - c[0]) * cosLat * 111_320, by = (b[1] - c[1]) * 111_320
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
                best = min(best, hypot(ax + t * dx, ay + t * dy))
            }
        }
        return best
    }

    /// Converts a cache from before taxiways/runways became width-carrying lines: their stitched polygon buffers
    /// (MultiPolygons, which left seams) are dropped and rebuilt as lines from the centrelines kept in the cache.
    /// Widths weren't stored then, so typical ones are used (taxiway 23 m, runway 45 m).
    static func upgradeLegacy(_ features: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for f in features {
            guard let props = f["properties"] as? [String: Any], let kind = props["kind"] as? String,
                  let geom = f["geometry"] as? [String: Any] else { continue }
            let isBuffer = geom["type"] as? String == "MultiPolygon"
            if isBuffer && (kind == "pavement" || kind == "runway-area") { continue }
            out.append(f)
            let lat = ((geom["coordinates"] as? [[Double]])?.first?[1]) ?? 50
            if kind == "taxi-line" || kind == "runway-centerline" {
                var p = widthProps(kind == "taxi-line" ? 23 : 45, lat: lat)
                p["kind"] = kind == "taxi-line" ? "taxiway-surface" : "runway-surface"
                p["apt"] = props["apt"] ?? ""
                out.append(["type": "Feature", "properties": p, "geometry": geom])
            }
        }
        return out
    }

    /// Cache file from before taxiways became width-carrying lines; used only if nothing newer can be fetched.
    private static func legacyCacheURL(_ icao: String) -> URL {
        oldCacheURL(icao).deletingLastPathComponent().appendingPathComponent("\(icao).json")
    }

    /// Kept in Application Support: iOS purges Caches when storage runs low, which emptied the ground map.
    private static func cacheURL(_ icao: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("amm", isDirectory: true)
            .appendingPathComponent("\(icao).v2.json") // v2: taxiways/runways as width-carrying lines
    }

    /// Where the cache lived before (Caches); still read so nothing is downloaded again.
    private static func oldCacheURL(_ icao: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("amm", isDirectory: true)
            .appendingPathComponent("\(icao).v2.json")
    }

    // MARK: - OSM → GeoJSON

    typealias Coord = [Double] // [lon, lat]

    static func convert(_ elements: [[String: Any]], icao: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var taxiLines: [[Coord]] = []
        var holds: [(Coord, String)] = []

        func add(_ kind: String, _ geometry: [String: Any], _ props: [String: Any] = [:]) {
            var p = props
            p["kind"] = kind
            p["apt"] = icao
            out.append(["type": "Feature", "properties": p, "geometry": geometry])
        }

        for e in elements {
            let tags = e["tags"] as? [String: String] ?? [:]
            let aeroway = tags["aeroway"] ?? ""
            let type = e["type"] as? String ?? ""
            let ref = tags["ref"] ?? ""

            if type == "node", let lat = e["lat"] as? Double, let lon = e["lon"] as? Double {
                let c: Coord = [lon, lat]
                switch aeroway {
                case "holding_position": holds.append((c, tags["holding_position:type"] ?? ""))
                case "parking_position": add("stand", point(c), ["ref": ref, "rot": 0])
                case "windsock": add("windsock", point(c))
                default: break
                }
                continue
            }

            if type == "relation" {
                // Multipolygon aprons: stitch the outer member ways into rings (holes are covered by buildings anyway).
                let outers = (e["members"] as? [[String: Any]] ?? [])
                    .filter { ($0["role"] as? String) == "outer" }
                    .compactMap { geometry($0["geometry"]) }
                for ring in stitch(outers) { add("apron", polygon(ring)) }
                continue
            }

            guard let line = geometry(e["geometry"]), line.count >= 2 else { continue }
            let closed = line.count > 3 && line.first! == line.last!

            switch aeroway {
            case "runway", "stopway":
                if closed {
                    add("runway-area", polygon(line))
                } else {
                    let width = Double(tags["width"] ?? "") ?? 45
                    add("runway-surface", lineString(line), widthProps(width, lat: line[0][1]))
                    if aeroway == "runway" {
                        add("runway-centerline", lineString(line))
                        for end in runwayEnds(line, ref: ref) { add("runway-end", point(end.0), ["ref": end.1, "rot": end.2]) }
                    }
                }
            case "taxiway", "taxilane":
                if closed && tags["area"] == "yes" {
                    add("pavement", polygon(line))
                } else {
                    let width = Double(tags["width"] ?? "") ?? (aeroway == "taxiway" ? 23 : 15)
                    add("taxiway-surface", lineString(line), widthProps(width, lat: line[0][1]))
                    add("taxi-line", lineString(line), ["ref": ref])
                    taxiLines.append(line)
                }
            case "apron":
                if closed { add("apron", polygon(line)) }
            case "parking_position":
                if closed { break }
                add("stand-line", lineString(line))
                // The stand symbol sits at the end where the aircraft stops, pointing along the lead-in line.
                let a = line[line.count - 2], b = line[line.count - 1]
                add("stand", point(b), ["ref": ref, "rot": bearing(a, b)])
            default:
                if closed && (tags["building"] != nil || aeroway == "terminal" || aeroway == "hangar") {
                    add("building", polygon(line), ["name": tags["name"] ?? ""])
                }
            }
        }

        // Holding points: a bar across the nearest taxiway centreline (the bar icon is horizontal,
        // so rotating it by the taxiway's bearing puts it perpendicular to the taxiway).
        for (c, holdType) in holds {
            let rot = nearestSegmentBearing(to: c, in: taxiLines) ?? 0
            add("hold", point(c), ["rot": rot, "type": holdType])
        }
        return out
    }

    private static func geometry(_ any: Any?) -> [Coord]? {
        guard let pts = any as? [[String: Any]] else { return nil }
        let coords = pts.compactMap { p -> Coord? in
            guard let lat = p["lat"] as? Double, let lon = p["lon"] as? Double else { return nil }
            return [lon, lat]
        }
        return coords.isEmpty ? nil : coords
    }

    private static func point(_ c: Coord) -> [String: Any] { ["type": "Point", "coordinates": c] }
    private static func lineString(_ l: [Coord]) -> [String: Any] { ["type": "LineString", "coordinates": l] }
    private static func polygon(_ ring: [Coord]) -> [String: Any] {
        var r = ring
        if r.first! != r.last! { r.append(r.first!) }
        return ["type": "Polygon", "coordinates": [r]]
    }

    /// Joins open ways into closed rings by matching endpoints.
    static func stitch(_ ways: [[Coord]]) -> [[Coord]] {
        var pool = ways
        var rings: [[Coord]] = []
        while !pool.isEmpty {
            var ring = pool.removeFirst()
            var progress = true
            while ring.first! != ring.last! && progress {
                progress = false
                for (i, w) in pool.enumerated() {
                    if w.first! == ring.last! { ring += w.dropFirst() }
                    else if w.last! == ring.last! { ring += w.reversed().dropFirst() }
                    else { continue }
                    pool.remove(at: i)
                    progress = true
                    break
                }
            }
            if ring.count >= 4 { rings.append(ring) }
        }
        return rings
    }

    /// Width of a taxiway/runway in metres plus its on-screen width at zoom 10 and 20, so the map can draw it as a
    /// line exactly `metres` wide at any zoom (exponential base-2 interpolation between the two).
    /// Drawing surfaces as thick lines with round joins avoids the seams/slivers that polygon buffers leave.
    static func widthProps(_ metres: Double, lat: Double) -> [String: Any] {
        let metresPerPixelZ0 = 156_543.033_92 * cos(lat * .pi / 180)
        return ["width": metres, "w10": metres / (metresPerPixelZ0 / 1024), "w20": metres / (metresPerPixelZ0 / 1_048_576)]
    }

    /// Runway end labels: "10/28" → "10" at the end you'd take off from heading ~100°.
    static func runwayEnds(_ line: [Coord], ref: String) -> [(Coord, String, Double)] {
        let parts = ref.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let first = line.first, let last = line.last else { return [] }
        let brg = bearing(first, last)
        func heading(_ d: String) -> Double? { Double(d.prefix { $0.isNumber }).map { $0 * 10 } }
        func diff(_ a: Double, _ b: Double) -> Double { abs(((a - b) + 540).truncatingRemainder(dividingBy: 360) - 180) }
        // Which designator matches the direction first → last?
        let firstIsA = (heading(parts[0]).map { diff($0, brg) } ?? 0) <= (heading(parts[1]).map { diff($0, brg) } ?? 0)
        let atFirst = firstIsA ? parts[0] : parts[1]
        let atLast = firstIsA ? parts[1] : parts[0]
        return [(first, atFirst, brg), (last, atLast, (brg + 180).truncatingRemainder(dividingBy: 360))]
    }

    static func bearing(_ a: Coord, _ b: Coord) -> Double {
        let φ1 = a[1] * .pi / 180, φ2 = b[1] * .pi / 180
        let Δλ = (b[0] - a[0]) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func nearestSegmentBearing(to c: Coord, in lines: [[Coord]]) -> Double? {
        let cosLat = cos(c[1] * .pi / 180)
        var best: (Double, Double)?
        for line in lines {
            for i in 0..<(line.count - 1) {
                let a = line[i], b = line[i + 1]
                let ax = (a[0] - c[0]) * cosLat, ay = a[1] - c[1]
                let bx = (b[0] - c[0]) * cosLat, by = b[1] - c[1]
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
                let d = hypot(ax + t * dx, ay + t * dy)
                if best == nil || d < best!.0 { best = (d, bearing(a, b)) }
            }
        }
        return best?.1
    }
}
