import CoreLocation
import Foundation

// MARK: - Feed model (https://data.vatsim.net/v3/vatsim-data.json)

struct VatsimPilot: Decodable {
    struct FlightPlan: Decodable {
        var aircraft_short: String?
        var departure: String?
        var arrival: String?
        var altitude: String?
        var route: String?
    }
    var cid: Int
    var name: String
    var callsign: String
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var groundspeed: Double
    var heading: Double
    var transponder: String?
    var flight_plan: FlightPlan?
    var logon_time: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var onGround: Bool { groundspeed < 50 }

    /// Icon scale by aircraft size, like VATSIM Radar (heavies are drawn bigger).
    var iconScale: Double {
        let type = (flight_plan?.aircraft_short ?? "").uppercased()
        let heavy = ["A33", "A34", "A35", "A38", "A30", "A31", "B74", "B76", "B77", "B78", "MD11", "IL96", "C5", "A124", "A400"]
        let light = ["C15", "C17", "C18", "C20", "C21", "C82", "P28", "P32", "PA", "SR2", "DA2", "DA4", "DA6", "BE", "TBM",
                     "PC12", "DR4", "M20", "C42", "AT4", "AT7", "DH8", "DHC"]
        if heavy.contains(where: { type.hasPrefix($0) }) { return 1.3 }
        if light.contains(where: { type.hasPrefix($0) }) { return 0.7 }
        return 1.0
    }
}

struct VatsimController: Decodable {
    var cid: Int
    var name: String
    var callsign: String
    var frequency: String
    var facility: Int
    var rating: Int
    var text_atis: [String]?
    var logon_time: String

    var ratingName: String {
        ["", "OBS", "S1", "S2", "S3", "C1", "C2", "C3", "I1", "I2", "I3", "SUP", "ADM"][safe: rating] ?? "?"
    }

    /// Callsign without the facility suffix: "EGTT_S_CTR" → "EGTT_S".
    var prefix: String {
        var parts = callsign.split(separator: "_").map(String.init)
        if parts.count > 1 { parts.removeLast() }
        return parts.joined(separator: "_")
    }

    var isAtis: Bool { callsign.hasSuffix("_ATIS") }

    /// "Tower", "Ground"… for card titles.
    var facilityName: String {
        if isAtis { return "ATIS" }
        return [1: "Radio", 2: "Delivery", 3: "Ground", 4: "Tower", 5: "Approach", 6: "Control"][facility] ?? ""
    }

    var onlineFor: String {
        guard let date = VatsimFeed.parseDate(logon_time) else { return "–" }
        let mins = max(0, Int(Date().timeIntervalSince(date) / 60))
        return String(format: "%02d:%02d", mins / 60, mins % 60)
    }
}

struct VatsimFeed: Decodable {
    var pilots: [VatsimPilot]
    var controllers: [VatsimController]
    var atis: [VatsimController]

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // VATSIM sends 7 fractional digits, which ISO8601DateFormatter can't parse; trim to milliseconds.
        if let dot = s.firstIndex(of: "."), let z = s.firstIndex(of: "Z"), s.distance(from: dot, to: z) > 4 {
            return f.date(from: String(s[..<s.index(dot, offsetBy: 4)]) + "Z")
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// ATC booking from https://atc-bookings.vatsim.net/api/booking (times are UTC "yyyy-MM-dd HH:mm:ss").
struct VatsimBooking: Decodable {
    var callsign: String
    var start: String
    var end: String

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var startDate: Date? { Self.parser.date(from: start) }
    var endDate: Date? { Self.parser.date(from: end) }
}

// MARK: - Filters

struct VatsimFilters: Codable, Equatable {
    enum MinAltitude: Int, Codable, CaseIterable {
        case all = 0, aboveFL100 = 10_000, aboveFL245 = 24_500
        var title: String { self == .all ? "All" : self == .aboveFL100 ? "> FL100" : "> FL245" }
    }

    var pilots = true
    var groundTraffic = true
    var pilotLabels = true
    var minAltitude = MinAltitude.all
    var onlyMyAirports = false
    var sectors = true
    var approach = true
    var localAtc = true
    var atis = true
    var trafficCounts = true
    var idleAirports = true
}

// MARK: - Static reference data bundled by scripts/build-basemap.py

/// Maps controller callsigns to sector polygons, TRACON polygons and airport positions.
final class VatsimReference {
    static let shared = VatsimReference()

    let firByPrefix: [String: String]
    let firNames: [String: String]
    let uirMembers: [String: [String]]
    let traconByPrefix: [String: [String]]
    let airports: [String: (lat: Double, lon: Double, name: String, icao: String)]

    struct Sector {
        let geometry: [String: Any]
        let label: [Double]?
    }

    private(set) lazy var sectorGeometry: [String: Sector] = {
        var out: [String: Sector] = [:]
        for f in Self.features("vatsim-sectors.geojson") {
            guard let p = f["properties"] as? [String: Any], let id = p["id"] as? String,
                  let g = f["geometry"] as? [String: Any] else { continue }
            let lx = p["lx"] as? Double ?? 0, ly = p["ly"] as? Double ?? 0
            out[id] = Sector(geometry: g, label: lx == 0 && ly == 0 ? nil : [lx, ly])
        }
        return out
    }()

    /// Sub-sectors of a FIR boundary: "EGTT" → ["EGTT-M", "EGTT-N", "EGTT-S"…].
    private(set) lazy var childrenByParent: [String: [String]] = {
        var out: [String: [String]] = [:]
        for id in sectorGeometry.keys {
            guard let dash = id.firstIndex(of: "-") else { continue }
            out[String(id[..<dash]), default: []].append(id)
        }
        return out
    }()

    func subSectors(of id: String) -> [String] {
        id.contains("-") ? [] : (childrenByParent[id] ?? [])
    }

    private(set) lazy var traconFeatures: [String: (name: String, geometry: [String: Any])] = {
        var out: [String: (String, [String: Any])] = [:]
        for f in Self.features("vatsim-tracons.geojson") {
            guard let p = f["properties"] as? [String: Any], let id = p["id"] as? String,
                  let g = f["geometry"] as? [String: Any] else { continue }
            out[id] = (p["name"] as? String ?? "", g)
        }
        return out
    }()

    private init() {
        let url = Bundle.main.resourceURL!.appendingPathComponent("Basemap/vatsim-index.json")
        let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        firByPrefix = json["fir"] as? [String: String] ?? [:]
        firNames = json["firNames"] as? [String: String] ?? [:]
        uirMembers = json["uir"] as? [String: [String]] ?? [:]
        traconByPrefix = json["tracon"] as? [String: [String]] ?? [:]
        var apts: [String: (Double, Double, String, String)] = [:]
        for (k, v) in json["airports"] as? [String: [Any]] ?? [:] {
            if v.count >= 4, let lat = v[0] as? Double, let lon = v[1] as? Double {
                apts[k] = (lat, lon, v[2] as? String ?? k, v[3] as? String ?? k)
            }
        }
        airports = apts
    }

    func airport(for prefix: String) -> (lat: Double, lon: Double, name: String, icao: String)? {
        let first = String(prefix.split(separator: "_").first ?? "")
        return airports[first] ?? (first.count == 3 ? airports["K" + first] : nil)
    }

    /// Boundary ids for a CTR/FSS controller, trying "EDWW_ALR" then "EDWW"; UIRs expand to their FIRs.
    func sectors(for prefix: String) -> [String] {
        var tokens = prefix.split(separator: "_").map(String.init)
        while !tokens.isEmpty {
            let key = tokens.joined(separator: "_")
            if let id = firByPrefix[key] { return [id] }
            if let members = uirMembers[key] { return members.compactMap { firByPrefix[$0] ?? $0 } }
            tokens.removeLast()
        }
        return []
    }

    func tracons(for prefix: String) -> [String] {
        var tokens = prefix.split(separator: "_").map(String.init)
        while !tokens.isEmpty {
            if let ids = traconByPrefix[tokens.joined(separator: "_")] { return ids }
            tokens.removeLast()
        }
        return []
    }

    private static func features(_ name: String) -> [[String: Any]] {
        let url = Bundle.main.resourceURL!.appendingPathComponent("Basemap/\(name)")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json["features"] as? [[String: Any]] ?? []
    }
}

// MARK: - VATGlasses (real sector ownership)

/// Who actually controls which airspace: VATGlasses positions (matched by callsign prefix, suffix and frequency)
/// and airspace blocks with an owner priority list — the first online owner controls the block.
final class VatGlasses {
    static let shared = VatGlasses()

    struct Position {
        let pre: [String]
        let type: String
        let freq: String?
        let name: String
        let colours: [(online: [String], hex: String)]
    }
    struct Block {
        let min: Int?
        let max: Int?
        let pts: [[Double]] // [lon, lat]
    }
    struct Airspace {
        let owner: [String]
        let blocks: [Block]
    }

    let positions: [String: Position]
    let airspace: [Airspace]
    /// "PREFIX|TYPE" → position ids, e.g. "LON|CTR" → [eg/L, eg/LS, eg/LSC…]
    private let index: [String: [String]]

    private init() {
        let url = Bundle.main.resourceURL!.appendingPathComponent("Basemap/vatglasses.json")
        let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var pos: [String: Position] = [:]
        var idx: [String: [String]] = [:]
        for (id, any) in json["positions"] as? [String: [String: Any]] ?? [:] {
            let colours = (any["colours"] as? [[String: Any]] ?? []).map {
                (online: $0["online"] as? [String] ?? [], hex: $0["hex"] as? String ?? "#4A7A2E")
            }
            let p = Position(pre: any["pre"] as? [String] ?? [], type: any["type"] as? String ?? "",
                             freq: any["freq"] as? String, name: any["name"] as? String ?? "", colours: colours)
            pos[id] = p
            for pre in p.pre { idx["\(pre)|\(p.type)", default: []].append(id) }
        }
        positions = pos
        index = idx
        airspace = (json["airspace"] as? [[String: Any]] ?? []).map { a in
            Airspace(owner: a["owner"] as? [String] ?? [],
                     blocks: (a["blocks"] as? [[String: Any]] ?? []).map {
                         Block(min: $0["min"] as? Int, max: $0["max"] as? Int, pts: $0["pts"] as? [[Double]] ?? [])
                     })
        }
    }

    /// Positions a logged-on controller occupies: prefix (before the first "_"), type (after the last "_")
    /// and, where the position defines one, the exact frequency.
    func positions(for c: VatsimController) -> [String] {
        let parts = c.callsign.split(separator: "_").map(String.init)
        guard parts.count >= 2, let prefix = parts.first, let type = parts.last else { return [] }
        return (index["\(prefix)|\(type)"] ?? []).filter { id in
            guard let f = positions[id]?.freq else { return true }
            return Double(f) == Double(c.frequency)
        }
    }

    /// Whether VATGlasses has data for this callsign's prefix and type at all. If it does but no position
    /// matched (non-standard frequency/position), the controller owns nothing we can draw reliably.
    func covers(_ c: VatsimController) -> Bool {
        let parts = c.callsign.split(separator: "_").map(String.init)
        guard parts.count >= 2, let prefix = parts.first, let type = parts.last else { return false }
        return index["\(prefix)|\(type)"] != nil
    }

    func colour(of id: String, online: [String: String]) -> String {
        positions[id]?.colours.first { $0.online.allSatisfy { online[$0] != nil } }?.hex ?? "#4A7A2E"
    }
}

// MARK: - Store

/// What was tapped on the VATSIM layer.
enum VatsimSelection: Equatable {
    case pilot(String)      // callsign
    case airport(String)    // ICAO
    case controller(String) // APP/CTR/FSS callsign
}

/// Polls the VATSIM feed every 15 s while the layer is on and turns it into map features.
@MainActor
final class VatsimStore: ObservableObject {
    @Published private(set) var feed: VatsimFeed?
    @Published private(set) var version = 0
    @Published private(set) var error: String?
    @Published var selection: VatsimSelection?
    @Published var enabled = false {
        didSet { enabled ? start() : stop() }
    }
    @Published var filters: VatsimFilters {
        didSet {
            if let data = try? JSONEncoder().encode(filters) { UserDefaults.standard.set(data, forKey: "vatsimFilters") }
            rebuild()
        }
    }
    /// Flight level the sector ownership is shown at (sectors are stacked in altitude bands).
    @Published var displayLevel = 350 {
        didSet { if displayLevel != oldValue { rebuild() } }
    }
    /// Airports of the loaded flight, for the "only my airports" filter.
    var myAirports: Set<String> = [] {
        didSet { if myAirports != oldValue && filters.onlyMyAirports { rebuild() } }
    }
    /// Search highlight (callsign or ICAO), drawn in orange.
    @Published private(set) var highlight: String?
    /// The map flies here when `focusToken` changes.
    private(set) var focus: CLLocationCoordinate2D?
    @Published private(set) var focusToken = 0

    /// GeoJSON FeatureCollection of everything the layer draws.
    private(set) var geojson: Data?
    private var bookings: [VatsimBooking] = []
    private var bookingsFetched: Date?
    private var task: Task<Void, Never>?
    private let feedURL = URL(string: "https://data.vatsim.net/v3/vatsim-data.json")!
    private let bookingsURL = URL(string: "https://atc-bookings.vatsim.net/api/booking")!

    init() {
        if let data = UserDefaults.standard.data(forKey: "vatsimFilters"),
           let saved = try? JSONDecoder().decode(VatsimFilters.self, from: data) {
            filters = saved
        } else {
            filters = VatsimFilters()
        }
    }

    private func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        selection = nil
    }

    func refresh() async {
        do {
            let decoded = try JSONDecoder().decode(VatsimFeed.self, from: try await get(feedURL))
            feed = decoded
            error = nil
            rebuild()
        } catch {
            self.error = "VATSIM data unavailable"
        }
        if bookingsFetched.map({ Date().timeIntervalSince($0) > 300 }) ?? true,
           let data = try? await get(bookingsURL), let list = try? JSONDecoder().decode([VatsimBooking].self, from: data) {
            bookings = list
            bookingsFetched = Date()
        }
    }

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("SimPilotEFB/0.1", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: req).0
    }

    private func rebuild() {
        guard let feed else { return }
        let (filters, mine, hl, level) = (self.filters, myAirports, highlight, displayLevel)
        Task {
            let built = await Task.detached(priority: .utility) {
                Self.buildFeatures(feed, filters: filters, myAirports: mine, highlight: hl, level: level)
            }.value
            geojson = built
            version += 1
        }
    }

    // MARK: Search

    /// Finds a pilot callsign or an airport ICAO, highlights it and flies the map there.
    @discardableResult
    func search(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !q.isEmpty else {
            highlight = nil
            rebuild()
            return false
        }
        if let p = feed?.pilots.first(where: { $0.callsign == q }) ?? feed?.pilots.first(where: { $0.callsign.hasPrefix(q) }) {
            highlight = p.callsign
            focus = p.coordinate
            selection = .pilot(p.callsign)
        } else if let apt = VatsimReference.shared.airports[q] {
            highlight = apt.icao
            focus = CLLocationCoordinate2D(latitude: apt.lat, longitude: apt.lon)
            selection = .airport(apt.icao)
        } else {
            return false
        }
        focusToken += 1
        rebuild()
        return true
    }

    // MARK: Lookups for the info card

    func pilot(_ callsign: String) -> VatsimPilot? { feed?.pilots.first { $0.callsign == callsign } }

    func controller(_ callsign: String) -> VatsimController? { feed?.controllers.first { $0.callsign == callsign } }

    func bookedUntil(_ callsign: String) -> String? {
        let now = Date()
        guard let b = bookings.first(where: { $0.callsign == callsign && ($0.startDate ?? .distantFuture) <= now && ($0.endDate ?? .distantPast) > now }),
              let end = b.endDate else { return nil }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm'z'"
        return f.string(from: end)
    }

    /// Delivery/ground/tower/ATIS stations at an airport, ordered D G T A.
    func airportStations(_ icao: String) -> [VatsimController] {
        guard let feed else { return [] }
        let ref = VatsimReference.shared
        let order = [2: 0, 3: 1, 4: 2]
        return (feed.controllers.filter { [2, 3, 4].contains($0.facility) } + feed.atis)
            .filter { ref.airport(for: $0.prefix)?.icao == icao }
            .sorted { (order[$0.facility] ?? 3) < (order[$1.facility] ?? 3) }
    }

    func traffic(_ icao: String) -> Traffic {
        guard let feed else { return Traffic() }
        return Self.traffic(feed.pilots, icao: icao)
    }

    struct Traffic {
        var departing = 0 // ▲ on the ground at their departure airport
        var landed = 0    // ▬ on the ground at their arrival airport
        var arriving = 0  // ▼ airborne, inbound
        var isEmpty: Bool { departing + landed + arriving == 0 }
    }

    nonisolated static func traffic(_ pilots: [VatsimPilot], icao: String) -> Traffic {
        var t = Traffic()
        let apt = VatsimReference.shared.airports[icao]
        func distanceKm(_ p: VatsimPilot) -> Double {
            guard let apt else { return .infinity }
            let dLat = (p.latitude - apt.lat) * 111.3
            let dLon = (p.longitude - apt.lon) * 111.3 * cos(apt.lat * .pi / 180)
            return (dLat * dLat + dLon * dLon).squareRoot()
        }
        for p in pilots {
            let fp = p.flight_plan
            // Ground counts: aircraft actually at the airport. Arrivals: inbound and within ~80 NM, like VATSIM Radar.
            if fp?.departure == icao && p.onGround && distanceKm(p) < 10 { t.departing += 1 }
            if fp?.arrival == icao {
                let d = distanceKm(p)
                if p.onGround { if d < 10 { t.landed += 1 } } else if d < 150 { t.arriving += 1 }
            }
        }
        return t
    }

    // MARK: Features

    nonisolated static func buildFeatures(_ feed: VatsimFeed, filters: VatsimFilters, myAirports: Set<String>,
                                          highlight: String?, level: Int = 350) -> Data? {
        let ref = VatsimReference.shared
        var features: [[String: Any]] = []
        func point(_ lon: Double, _ lat: Double) -> [String: Any] { ["type": "Point", "coordinates": [lon, lat]] }

        // Online enroute sectors (CTR/FSS).
        // 1. VATGlasses: the airspace each controller actually owns right now (first online position in each block's
        //    owner list), at the selected flight level, merged per controller with one outline and one label.
        // 2. VATSpy fallback for controllers VATGlasses doesn't know: staffed sub-sector green, staffed parent FIR once.
        if filters.sectors {
            let vg = VatGlasses.shared
            var onlinePos: [String: String] = [:] // VATGlasses position id → controller callsign
            var vgControllers = Set<String>()
            for c in feed.controllers where c.facility >= 1 {
                for id in vg.positions(for: c) where onlinePos[id] == nil {
                    onlinePos[id] = c.callsign
                    if c.facility == 6 || c.facility == 1 { vgControllers.insert(c.callsign) }
                }
            }

            var owned: [String: [[[Double]]]] = [:] // owner position → polygons at this level
            for a in vg.airspace {
                guard let owner = a.owner.first(where: { onlinePos[$0] != nil }),
                      let type = vg.positions[owner]?.type, type == "CTR" || type == "FSS" else { continue }
                for b in a.blocks where (b.min ?? 0) <= level && level <= (b.max ?? 999) && b.pts.count >= 3 {
                    owned[owner, default: []].append(b.pts)
                }
            }
            for (owner, polys) in owned {
                guard let callsign = onlinePos[owner] else { continue }
                let colour = vg.colour(of: owner, online: onlinePos)
                for ring in polys {
                    var r = ring
                    if r.first! != r.last! { r.append(r.first!) }
                    features.append(["type": "Feature", "geometry": ["type": "Polygon", "coordinates": [r]],
                                     "properties": ["kind": "vg-area", "key": callsign, "color": colour]])
                }
                features.append(["type": "Feature", "geometry": ["type": "MultiLineString", "coordinates": outerEdges(polys)],
                                 "properties": ["kind": "vg-line", "key": callsign, "color": colour]])
                if let c = labelPoint(polys) {
                    let label = callsign.replacingOccurrences(of: "_CTR", with: "").replacingOccurrences(of: "_FSS", with: "")
                    features.append(["type": "Feature", "geometry": point(c[0], c[1]),
                                     "properties": ["kind": "sector-label", "key": callsign, "label": label]])
                }
            }

            var online: [String: String] = [:] // VATSpy boundary id → controller callsign
            // Only for regions VATGlasses doesn't cover — otherwise an unmatched position would paint a whole FIR.
            for c in feed.controllers where (c.facility == 6 || c.facility == 1) && !vgControllers.contains(c.callsign) && !vg.covers(c) {
                for id in ref.sectors(for: c.prefix) where online[id] == nil { online[id] = c.callsign }
            }
            for (id, callsign) in online {
                guard let s = ref.sectorGeometry[id] else { continue }
                let kind = ref.subSectors(of: id).isEmpty ? "sector" : "sector-parent"
                features.append(["type": "Feature", "geometry": s.geometry, "properties": ["kind": kind, "key": callsign]])
                if let l = s.label {
                    features.append(["type": "Feature", "geometry": point(l[0], l[1]),
                                     "properties": ["kind": "sector-label", "key": callsign, "label": id]])
                }
            }
        }

        // Approach: TRACON polygon (or a 25 NM circle), red ICAO box at its north-west edge.
        if filters.approach {
            for c in feed.controllers where c.facility == 5 {
                let label = ref.airport(for: c.prefix)?.icao ?? c.prefix
                var geoms: [[String: Any]] = ref.tracons(for: c.prefix).compactMap { ref.traconFeatures[$0]?.geometry }
                if geoms.isEmpty, let apt = ref.airport(for: c.prefix) { geoms = [circle(lat: apt.lat, lon: apt.lon, radiusNm: 25)] }
                for g in geoms {
                    features.append(["type": "Feature", "geometry": g, "properties": ["kind": "approach", "key": c.callsign]])
                }
                if let nw = northWestVertex(geoms) {
                    features.append(["type": "Feature", "geometry": point(nw[0], nw[1]),
                                     "properties": ["kind": "approach-label", "key": c.callsign, "label": label]])
                }
            }
        }

        // Airports: ATC letters (bar when zoomed out, badges when zoomed in) and traffic counts.
        var letters: [String: Set<Character>] = [:]
        if filters.localAtc {
            for c in feed.controllers where [2, 3, 4].contains(c.facility) {
                if let icao = ref.airport(for: c.prefix)?.icao {
                    letters[icao, default: []].insert(c.facility == 2 ? "D" : c.facility == 3 ? "G" : "T")
                }
            }
        }
        if filters.atis {
            for a in feed.atis {
                if let icao = ref.airport(for: a.prefix)?.icao { letters[icao, default: []].insert("A") }
            }
        }
        var airportIcaos = Set(letters.keys)
        if filters.idleAirports || filters.trafficCounts {
            for p in feed.pilots {
                if let d = p.flight_plan?.departure, p.onGround { airportIcaos.insert(d) }
                if let a = p.flight_plan?.arrival, !a.isEmpty { airportIcaos.insert(a) }
            }
        }
        for icao in airportIcaos {
            guard let apt = ref.airports[icao] else { continue }
            if filters.onlyMyAirports && !myAirports.contains(icao) && letters[icao] == nil { continue }
            let set = letters[icao] ?? []
            let t = traffic(feed.pilots, icao: icao)
            if set.isEmpty && (!filters.idleAirports || t.isEmpty) { continue }
            let atc = String("DGTA".filter { set.contains($0) })
            var props: [String: Any] = ["key": icao, "icao": icao, "hl": icao == highlight,
                                        "kind": atc.isEmpty ? "airport-idle" : "airport"]
            if !atc.isEmpty {
                props["badge"] = "atc-\(atc)"
                props["bar"] = "atcbar-\(atc)"
            }
            props["counts"] = filters.trafficCounts && !t.isEmpty ? "cnt-\(t.departing)-\(t.landed)-\(t.arriving)" : ""
            features.append(["type": "Feature", "geometry": point(apt.lon, apt.lat), "properties": props])
        }

        // Pilots.
        if filters.pilots {
            for p in feed.pilots {
                if !filters.groundTraffic && p.onGround { continue }
                if Double(filters.minAltitude.rawValue) > p.altitude { continue }
                if filters.onlyMyAirports {
                    let fp = p.flight_plan
                    if !myAirports.contains(fp?.departure ?? "") && !myAirports.contains(fp?.arrival ?? "") { continue }
                }
                features.append(["type": "Feature", "geometry": point(p.longitude, p.latitude),
                                 "properties": ["kind": "pilot", "key": p.callsign, "hdg": p.heading, "label": p.callsign,
                                                "size": p.iconScale, "hl": p.callsign == highlight,
                                                "showLabel": filters.pilotLabels]])
            }
        }

        return try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }

    nonisolated private static func circle(lat: Double, lon: Double, radiusNm: Double) -> [String: Any] {
        let dLat = radiusNm / 60
        let dLon = radiusNm / (60 * cos(lat * .pi / 180))
        var ring = (0..<48).map { i -> [Double] in
            let t = Double(i) / 48 * 2 * .pi
            return [lon + cos(t) * dLon, lat + sin(t) * dLat]
        }
        ring.append(ring[0])
        return ["type": "Polygon", "coordinates": [ring]]
    }

    /// Boundary of a controller's merged area: edges shared by two of its blocks are interior and dropped.
    /// VATGlasses blocks are built from the same coordinate list, so shared edges match exactly.
    nonisolated private static func outerEdges(_ polys: [[[Double]]]) -> [[[Double]]] {
        var count: [String: Int] = [:]
        var edges: [String: [[Double]]] = [:]
        func key(_ p: [Double]) -> String { String(format: "%.4f,%.4f", p[0], p[1]) }
        for ring in polys {
            let pts = ring.first! == ring.last! ? Array(ring.dropLast()) : ring
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                let ka = key(a), kb = key(b)
                guard ka != kb else { continue }
                let k = ka < kb ? "\(ka)|\(kb)" : "\(kb)|\(ka)"
                count[k, default: 0] += 1
                edges[k] = [a, b]
            }
        }
        return count.filter { $0.value == 1 }.compactMap { edges[$0.key] }
    }

    /// Label position: centre of the largest block (by bounding-box area).
    nonisolated private static func labelPoint(_ polys: [[[Double]]]) -> [Double]? {
        func bbox(_ r: [[Double]]) -> (Double, Double, Double, Double) {
            (r.map { $0[0] }.min()!, r.map { $0[1] }.min()!, r.map { $0[0] }.max()!, r.map { $0[1] }.max()!)
        }
        guard let largest = polys.filter({ !$0.isEmpty }).max(by: { a, b in
            let x = bbox(a), y = bbox(b)
            return (x.2 - x.0) * (x.3 - x.1) < (y.2 - y.0) * (y.3 - y.1)
        }) else { return nil }
        let pts = largest.first! == largest.last! ? Array(largest.dropLast()) : largest
        return [pts.map { $0[0] }.reduce(0, +) / Double(pts.count), pts.map { $0[1] }.reduce(0, +) / Double(pts.count)]
    }

    /// The most north-westerly vertex of the polygons, where VATSIM Radar pins the approach label.
    nonisolated private static func northWestVertex(_ geoms: [[String: Any]]) -> [Double]? {
        var best: [Double]?
        var bestScore = -Double.infinity
        func visit(_ any: Any) {
            if let c = any as? [Double], c.count >= 2 {
                let score = c[1] - c[0] * cos(c[1] * .pi / 180)
                if score > bestScore { bestScore = score; best = c }
            } else if let arr = any as? [Any] {
                arr.forEach(visit)
            }
        }
        geoms.forEach { visit($0["coordinates"] as Any) }
        return best
    }
}
