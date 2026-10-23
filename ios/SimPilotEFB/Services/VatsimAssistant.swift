import CoreLocation
import Foundation

/// "What did ATC give me?" for your own VATSIM flight. Uses only your callsign's entry in the public data feed:
/// the squawk the controller assigned, flight-plan amendments (cruise level, route, arrival, alternate) and the
/// controllers covering you. Spoken instructions (headings, levels) aren't published, so they can't be shown.
@MainActor
final class VatsimAssistant: ObservableObject {
    struct Flight: Equatable {
        var callsign: String
        var coordinate: CLLocationCoordinate2D
        var altitudeFt: Double
        var groundspeed: Double
        var transponder: String?
        var assignedSquawk: String?
        var departure: String?
        var arrival: String?
        var alternate: String?
        var cruise: String?
        var route: String?
        var remarks: String?
        var revision: Int?

        static func == (a: Flight, b: Flight) -> Bool {
            a.callsign == b.callsign && a.assignedSquawk == b.assignedSquawk && a.cruise == b.cruise && a.route == b.route
                && a.arrival == b.arrival && a.alternate == b.alternate && a.revision == b.revision
                && a.transponder == b.transponder && a.altitudeFt == b.altitudeFt
        }
    }

    struct Change: Identifiable {
        let id = UUID()
        let time: Date
        let title: String
        let detail: String
    }

    struct Contact: Identifiable {
        var id: String { controller.callsign }
        let role: String
        let controller: VatsimController
    }

    /// Your VATSIM callsign; only this entry of the feed is used.
    @Published var callsign: String {
        didSet {
            UserDefaults.standard.set(callsign, forKey: "vatsimCallsign")
            if callsign != oldValue { reset() }
        }
    }
    @Published private(set) var flight: Flight?
    /// nil until the first fetch for this callsign.
    @Published private(set) var online: Bool?
    @Published private(set) var updated: Date?
    /// When your callsign was last in the feed.
    @Published private(set) var lastSeen: Date?
    @Published private(set) var error: String?
    @Published private(set) var changes: [Change] = []
    @Published private(set) var covering: [Contact] = []
    @Published private(set) var departureStations: [Contact] = []
    @Published private(set) var arrivalStations: [Contact] = []

    private var task: Task<Void, Never>?
    private let feedURL = URL(string: "https://data.vatsim.net/v3/vatsim-data.json")!
    private let interval: UInt64 = 20_000_000_000

    init() {
        callsign = UserDefaults.standard.string(forKey: "vatsimCallsign") ?? ""
    }

    /// Polls while the assistant page is on screen.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: self?.interval ?? 20_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The flight shown is from an earlier feed: you're no longer connected, or the feed couldn't be loaded for a while.
    var isStale: Bool {
        guard flight != nil else { return false }
        if online == false { return true }
        guard let seen = lastSeen else { return true }
        return Date().timeIntervalSince(seen) > 90
    }

    private func reset() {
        flight = nil
        online = nil
        error = nil
        updated = nil
        lastSeen = nil
        changes = []
        covering = []
        departureStations = []
        arrivalStations = []
        if task != nil { Task { await refresh() } }
    }

    func refresh() async {
        let wanted = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !wanted.isEmpty else { return }
        do {
            var req = URLRequest(url: feedURL)
            req.setValue("SimPilotEFB/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.statusCode) else { throw NSError(domain: "HTTP", code: response.statusCode) }
            let parsed = try await Task.detached(priority: .utility) { () -> (Flight?, [VatsimController]) in
                let feed = try JSONDecoder().decode(SlimFeed.self, from: data)
                let me = feed.pilots.first { $0.callsign.uppercased() == wanted }
                return (me.map(Flight.init), feed.controllers + (feed.atis ?? []))
            }.value
            try Task.checkCancellation()
            guard wanted == callsign.trimmingCharacters(in: .whitespaces).uppercased() else { return }
            if updated == nil || error != nil {
                DiagnosticLog.record(.info, "VATSIM", error == nil ? "Assistant feed loaded" : "Assistant feed recovered")
            }
            error = nil
            updated = Date()
            online = parsed.0 != nil
            if let new = parsed.0 {
                if let old = flight { logChanges(from: old, to: new) }
                flight = new
                lastSeen = Date()
                findControllers(for: new, in: parsed.1)
            } else {
                // Keep the last known flight for reference; the page marks it as old and won't apply its squawk.
                covering = []
                departureStations = []
                arrivalStations = []
            }
        } catch {
            guard !Task.isCancelled, (error as? URLError)?.code != .cancelled,
                  wanted == callsign.trimmingCharacters(in: .whitespaces).uppercased() else { return }
            if self.error == nil { DiagnosticLog.record(.warning, "VATSIM", "Assistant feed unavailable", error: error) }
            self.error = "VATSIM data unavailable"
        }
    }

    // MARK: Changes from ATC

    private func logChanges(from old: Flight, to new: Flight) {
        var out: [Change] = []
        let now = Date()
        if new.assignedSquawk != old.assignedSquawk, let sq = new.assignedSquawk {
            out.append(Change(time: now, title: "Squawk assigned", detail: sq))
        }
        if new.cruise != old.cruise {
            out.append(Change(time: now, title: "Cruise level changed",
                              detail: "\(Self.level(old.cruise) ?? "–") → \(Self.level(new.cruise) ?? "–")"))
        }
        if new.route != old.route {
            out.append(Change(time: now, title: "Route changed", detail: new.route ?? ""))
        }
        if new.arrival != old.arrival {
            out.append(Change(time: now, title: "Destination changed", detail: "\(old.arrival ?? "–") → \(new.arrival ?? "–")"))
        }
        if new.alternate != old.alternate {
            out.append(Change(time: now, title: "Alternate changed", detail: "\(old.alternate ?? "–") → \(new.alternate ?? "–")"))
        }
        if out.isEmpty, new.revision != old.revision, new.revision != nil {
            out.append(Change(time: now, title: "Flight plan updated", detail: "Revision \(new.revision ?? 0)"))
        }
        changes.insert(contentsOf: out, at: 0)
    }

    /// "35000" → "FL350", "FL320" stays, "5000" → "5000 ft".
    nonisolated static func level(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let s = raw.uppercased()
        if s.hasPrefix("FL") { return s }
        guard let ft = Int(s.filter(\.isNumber)) else { return s }
        return ft >= 10_000 ? "FL\(ft / 100)" : "\(ft) ft"
    }

    // MARK: Who to talk to

    private func findControllers(for f: Flight, in controllers: [VatsimController]) {
        let ref = VatsimReference.shared
        let pos = f.coordinate
        var cover: [Contact] = []
        for c in controllers where !c.isAtis {
            switch c.facility {
            case 6, 1: // centre / FSS: inside one of its boundaries
                if ref.sectors(for: c.prefix).contains(where: { id in
                    ref.sectorGeometry[id].map { Self.contains($0.geometry, pos) } ?? false
                }) { cover.append(Contact(role: c.facility == 6 ? "Centre" : "Radio", controller: c)) }
            case 5: // approach: inside its TRACON
                if ref.tracons(for: c.prefix).contains(where: { id in
                    ref.traconFeatures[id].map { Self.contains($0.geometry, pos) } ?? false
                }) { cover.append(Contact(role: "Approach", controller: c)) }
            default: break
            }
        }
        // Approach before centre: the lower unit is the one that works you there.
        covering = cover.sorted { ($0.role == "Approach" ? 0 : 1) < ($1.role == "Approach" ? 0 : 1) }
        departureStations = Self.stations(at: f.departure, in: controllers)
        arrivalStations = Self.stations(at: f.arrival, in: controllers)
    }

    private static func stations(at icao: String?, in controllers: [VatsimController]) -> [Contact] {
        guard let icao, !icao.isEmpty else { return [] }
        let ref = VatsimReference.shared
        let order = [2: 0, 3: 1, 4: 2, 5: 3]
        return controllers
            .filter { c in
                if c.isAtis { return ref.airport(for: c.prefix)?.icao == icao }
                return [2, 3, 4].contains(c.facility) && ref.airport(for: c.prefix)?.icao == icao
            }
            .sorted { (order[$0.facility] ?? ($0.isAtis ? 4 : 5)) < (order[$1.facility] ?? ($1.isAtis ? 4 : 5)) }
            .map { Contact(role: $0.facilityName, controller: $0) }
    }

    /// Point in a GeoJSON Polygon/MultiPolygon (outer rings only).
    nonisolated static func contains(_ geometry: [String: Any], _ p: CLLocationCoordinate2D) -> Bool {
        var polygons: [[[Double]]] = []
        switch geometry["type"] as? String {
        case "Polygon":
            if let rings = geometry["coordinates"] as? [[[Double]]], let outer = rings.first { polygons = [outer] }
        case "MultiPolygon":
            if let polys = geometry["coordinates"] as? [[[[Double]]]] { polygons = polys.compactMap(\.first) }
        default: break
        }
        let x = p.longitude, y = p.latitude
        return polygons.contains { ring in
            guard ring.count >= 3, ring.allSatisfy({ $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }) else { return false }
            var inside = false
            var j = ring.count - 1
            for i in 0..<ring.count {
                let (xi, yi, xj, yj) = (ring[i][0], ring[i][1], ring[j][0], ring[j][1])
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
            return inside
        }
    }
}

// MARK: - Slim feed model (only what the assistant needs)

private struct SlimFeed: Decodable {
    struct Pilot: Decodable {
        struct Plan: Decodable {
            var departure: String?
            var arrival: String?
            var alternate: String?
            var altitude: String?
            var route: String?
            var remarks: String?
            var assigned_transponder: String?
            var revision_id: Int?
        }
        var callsign: String
        var latitude: Double
        var longitude: Double
        var altitude: Double
        var groundspeed: Double
        var transponder: String?
        var flight_plan: Plan?
    }
    var pilots: [Pilot]
    var controllers: [VatsimController]
    var atis: [VatsimController]?
}

private extension VatsimAssistant.Flight {
    init(_ p: SlimFeed.Pilot) {
        let fp = p.flight_plan
        let assigned = fp?.assigned_transponder.flatMap { $0.isEmpty || $0 == "0000" ? nil : $0 }
        self.init(callsign: p.callsign, coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                  altitudeFt: p.altitude, groundspeed: p.groundspeed, transponder: p.transponder, assignedSquawk: assigned,
                  departure: fp?.departure, arrival: fp?.arrival, alternate: fp?.alternate, cruise: fp?.altitude,
                  route: fp?.route, remarks: fp?.remarks, revision: fp?.revision_id)
    }
}
