import Combine
import Foundation

// Everything the Flight module keeps: checklists and their progress, ATC clearances, approach minima and the
// logbook. One small JSON file in Application Support (not Caches, which iOS purges).

struct ClearanceEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var time = Date()
    var altitude = ""
    var heading = ""
    var speed = ""
    var squawk = ""
    var frequency = ""
    var note = ""

    var isEmpty: Bool {
        [altitude, heading, speed, squawk, frequency, note].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

struct ChecklistItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var challenge: String
    var response: String
}

struct Checklist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [ChecklistItem]
}

/// What the pilot entered for an approach: type/procedure, DA/MDA and visibility/RVR.
struct Minima: Codable, Equatable {
    var approach = ""
    var decision = ""
    var visibility = ""

    var isEmpty: Bool { approach.isEmpty && decision.isEmpty && visibility.isEmpty }
}

struct LogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var callsign = ""
    var origin = ""
    var destination = ""
    var aircraft = ""
    var route = ""
    var blockOff: Date?
    var takeoff: Date?
    var landing: Date?
    var blockOn: Date?
    var notes = ""
    /// Takeoff/landing were picked up from the sim rather than typed in.
    var automatic = false

    /// When the flight happened (for sorting): the first time that is set.
    var sortDate: Date { blockOff ?? takeoff ?? landing ?? blockOn ?? .distantPast }
    var airSeconds: TimeInterval? { span(takeoff, landing) }
    var blockSeconds: TimeInterval? { span(blockOff, blockOn) }

    private func span(_ a: Date?, _ b: Date?) -> TimeInterval? {
        guard let a, let b, b > a else { return nil }
        return b.timeIntervalSince(a)
    }
}

/// A PDF the pilot imported from Files (airline procedures, airport documents…). The file itself lives in
/// Application Support/documents; page bookmarks and the last page read are kept here.
struct ImportedDocument: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var pageCount: Int
    var addedAt = Date()
    var bookmarks: [Int] = []
    var lastPage = 0
}

/// What the pilot changed from the SimBrief plan (Flight Folder → Edit Flight): VATSIM often gives another runway or
/// procedure. Empty fields mean "as planned".
struct FlightEdit: Codable, Equatable {
    var originRunway = ""
    var sid = ""
    var destinationRunway = ""
    var star = ""

    var isEmpty: Bool { originRunway.isEmpty && sid.isEmpty && destinationRunway.isEmpty && star.isEmpty }
}

/// Fuel on board as the aircraft passed a waypoint of the flight plan, next to what the plan said.
struct FuelPass: Codable, Identifiable, Equatable {
    var id: Int { index }
    var index: Int
    var ident: String
    var plannedKg: Double
    var actualKg: Double
    var time: Date

    var deltaKg: Double { actualKg - plannedKg }
}

struct FlightToolsData: Codable, Equatable {
    var checklists: [Checklist] = DefaultChecklists.a320()
    /// Ticked checklist items per flight (checklist item ids as strings).
    var ticks: [String: [String]] = [:]
    var clearances: [String: [ClearanceEntry]] = [:]
    /// Keyed "<flight>|<ICAO>".
    var minima: [String: Minima] = [:]
    var log: [LogEntry] = []
    var documents: [ImportedDocument] = []
    /// Per flight, in route order.
    var fuelPasses: [String: [FuelPass]] = [:]
    var edits: [String: FlightEdit] = [:]

    init() {}

    // Files written by older builds may lack newer fields; missing ones fall back to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checklists = try c.decodeIfPresent([Checklist].self, forKey: .checklists) ?? DefaultChecklists.a320()
        ticks = try c.decodeIfPresent([String: [String]].self, forKey: .ticks) ?? [:]
        clearances = try c.decodeIfPresent([String: [ClearanceEntry]].self, forKey: .clearances) ?? [:]
        minima = try c.decodeIfPresent([String: Minima].self, forKey: .minima) ?? [:]
        log = try c.decodeIfPresent([LogEntry].self, forKey: .log) ?? []
        documents = try c.decodeIfPresent([ImportedDocument].self, forKey: .documents) ?? []
        fuelPasses = try c.decodeIfPresent([String: [FuelPass]].self, forKey: .fuelPasses) ?? [:]
        edits = try c.decodeIfPresent([String: FlightEdit].self, forKey: .edits) ?? [:]
    }
}

/// Spots a takeoff or a landing in the stream of ownship samples. A change of state has to last a few seconds
/// (and a takeoff needs some speed) before it counts, so a bounce on the runway or a glitch isn't logged.
struct FlightPhaseDetector {
    enum Event: Equatable {
        case takeoff(Date)
        case landing(Date)
    }

    /// Seconds a new state must hold.
    static let holdMs = 8_000.0
    static let minTakeoffKt = 50.0

    private var airborne: Bool?
    private var changedAtMs: Double?

    /// `ts` is the sample time in milliseconds since 1970 (Ownship.ts). Returns the event once it is confirmed;
    /// the event carries the time the change began.
    mutating func feed(ts: Double, onGround: Bool, gsKt: Double) -> Event? {
        let sample = !onGround
        guard let state = airborne else {
            airborne = sample // the first sample only tells where we are; no event
            return nil
        }
        guard sample != state else {
            changedAtMs = nil
            return nil
        }
        let since = changedAtMs ?? ts
        changedAtMs = since
        guard ts - since >= Self.holdMs, !sample || gsKt >= Self.minTakeoffKt else { return nil }
        airborne = sample
        changedAtMs = nil
        let at = Date(timeIntervalSince1970: since / 1000)
        return sample ? .takeoff(at) : .landing(at)
    }
}

@MainActor
final class FlightToolsStore: ObservableObject {
    @Published var data: FlightToolsData {
        didSet { if data != oldValue { scheduleSave() } }
    }

    private let url: URL
    private var saveTask: Task<Void, Never>?
    private var detector = FlightPhaseDetector()
    private var lastFuelCheckMs = 0.0

    init(url: URL? = nil) {
        let file = url ?? Self.defaultURL
        self.url = file
        if let bytes = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(FlightToolsData.self, from: bytes) {
            data = saved
        } else {
            data = FlightToolsData()
        }
    }

    private static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("flight-tools.json")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try JSONEncoder().encode(data).write(to: url, options: .atomic)
        } catch {
            DiagnosticLog.record(.error, "Flight", "Couldn't save flight tools", error: error)
        }
    }

    // MARK: Checklists

    func ticked(_ flight: String) -> Set<String> { Set(data.ticks[flight] ?? []) }

    func toggle(_ item: ChecklistItem, flight: String) {
        var set = ticked(flight)
        if set.contains(item.id.uuidString) { set.remove(item.id.uuidString) } else { set.insert(item.id.uuidString) }
        data.ticks[flight] = Array(set)
    }

    func resetTicks(_ list: Checklist, flight: String) {
        let ids = Set(list.items.map(\.id.uuidString))
        data.ticks[flight] = (data.ticks[flight] ?? []).filter { !ids.contains($0) }
    }

    func restoreDefaultChecklists() { data.checklists = DefaultChecklists.a320() }

    // MARK: Clearances

    func clearances(_ flight: String) -> [ClearanceEntry] { data.clearances[flight] ?? [] }

    func addClearance(_ entry: ClearanceEntry, flight: String) {
        guard !entry.isEmpty else { return }
        data.clearances[flight, default: []].insert(entry, at: 0)
    }

    func removeClearance(_ id: UUID, flight: String) {
        data.clearances[flight]?.removeAll { $0.id == id }
    }

    func clearClearances(flight: String) { data.clearances[flight] = nil }

    // MARK: Minima

    func minima(flight: String, icao: String) -> Minima { data.minima["\(flight)|\(icao)"] ?? Minima() }

    func setMinima(_ minima: Minima, flight: String, icao: String) {
        data.minima["\(flight)|\(icao)"] = minima.isEmpty ? nil : minima
    }

    // MARK: Logbook

    func upsert(_ entry: LogEntry) {
        if let i = data.log.firstIndex(where: { $0.id == entry.id }) { data.log[i] = entry } else { data.log.append(entry) }
    }

    func removeLog(_ id: UUID) { data.log.removeAll { $0.id == id } }

    /// Feeds the live aircraft state: takeoffs and landings go into the logbook by themselves (times can be
    /// corrected by hand afterwards). A takeoff starts an entry from the loaded flight; a landing closes it.
    func observe(_ o: Ownship, ofp: Ofp?, aircraftTitle: String?, flight: String = "no-flight") {
        recordFuel(o, ofp: ofp, flight: flight)
        guard let event = detector.feed(ts: o.ts, onGround: o.onGround, gsKt: o.gsKt) else { return }
        switch event {
        case let .takeoff(at):
            var entry = LogEntry(callsign: ofp?.callsign ?? "", origin: ofp?.origin.icao ?? "", destination: ofp?.destination.icao ?? "",
                                 aircraft: ofp?.aircraft.name ?? aircraftTitle ?? "", route: ofp?.route ?? "")
            entry.takeoff = at
            entry.automatic = true
            upsert(entry)
        case let .landing(at):
            if let i = data.log.lastIndex(where: { $0.automatic && $0.takeoff != nil && $0.landing == nil }) {
                data.log[i].landing = at
            } else {
                // Started the app in flight: there's no takeoff to pair it with, but the landing is still worth keeping.
                var entry = LogEntry(callsign: ofp?.callsign ?? "", origin: ofp?.origin.icao ?? "", destination: ofp?.destination.icao ?? "",
                                     aircraft: ofp?.aircraft.name ?? aircraftTitle ?? "", route: ofp?.route ?? "")
                entry.landing = at
                entry.automatic = true
                upsert(entry)
            }
        }
    }

    // MARK: Flight edits

    func edit(_ flight: String) -> FlightEdit { data.edits[flight] ?? FlightEdit() }

    func setEdit(_ edit: FlightEdit, flight: String) { data.edits[flight] = edit.isEmpty ? nil : edit }

    // MARK: Fuel

    /// How close (NM) behind a waypoint the aircraft may be when it is noted, so starting the app in the middle of a
    /// flight doesn't log every waypoint already passed.
    private static let fuelPassWindowNm = 15.0

    private func recordFuel(_ o: Ownship, ofp: Ofp?, flight: String) {
        guard let ofp, !o.onGround, let fuel = o.fuelKg, fuel > 0, o.ts - lastFuelCheckMs >= 1_000 else { return }
        lastFuelCheckMs = o.ts
        guard let along = RouteProgress.alongTrackNm(ofp: ofp, o) else { return }
        let done = Set((data.fuelPasses[flight] ?? []).map(\.index))
        for (index, fix) in ofp.navlog.enumerated() where fix.type != "apt" && !done.contains(index) {
            guard let planned = fix.fuelPlanKg, along >= fix.cumNm, along - fix.cumNm <= Self.fuelPassWindowNm else { continue }
            data.fuelPasses[flight, default: []].append(FuelPass(index: index, ident: fix.ident, plannedKg: planned, actualKg: fuel, time: Date(timeIntervalSince1970: o.ts / 1000)))
        }
        data.fuelPasses[flight]?.sort { $0.index < $1.index }
    }

    // MARK: Documents

    func document(_ id: UUID) -> ImportedDocument? { data.documents.first { $0.id == id } }

    func toggleBookmark(_ id: UUID, page: Int) {
        guard let i = data.documents.firstIndex(where: { $0.id == id }) else { return }
        if let at = data.documents[i].bookmarks.firstIndex(of: page) { data.documents[i].bookmarks.remove(at: at) }
        else { data.documents[i].bookmarks = (data.documents[i].bookmarks + [page]).sorted() }
    }

    func setLastPage(_ id: UUID, page: Int) {
        guard let i = data.documents.firstIndex(where: { $0.id == id }), data.documents[i].lastPage != page else { return }
        data.documents[i].lastPage = page
    }

    /// Removes the document, its file and its Pencil notes.
    func removeDocument(_ id: UUID) {
        guard let doc = document(id) else { return }
        DocumentFiles.remove(doc)
        data.documents.removeAll { $0.id == id }
    }

    // MARK: Checklist editing

    func addChecklist() {
        data.checklists.append(Checklist(name: "New checklist", items: [ChecklistItem(challenge: "Item", response: "CHECKED")]))
    }

    func removeChecklist(_ id: UUID) { data.checklists.removeAll { $0.id == id } }
}

// MARK: - Default checklists

/// Generic normal-procedure checklists for an Airbus A320, in plain words. They are a starting point: every
/// airline and every sim aircraft differs, so all of it can be edited in the app.
enum DefaultChecklists {
    static func a320() -> [Checklist] {
        func list(_ name: String, _ items: [(String, String)]) -> Checklist {
            Checklist(name: name, items: items.map { ChecklistItem(challenge: $0.0, response: $0.1) })
        }
        return [
            list("Cockpit preparation", [
                ("Batteries", "ON"), ("External power", "AS REQUIRED"), ("ADIRS", "NAV"), ("Fuel quantity", "CHECKED"),
                ("Flight plan and performance", "ENTERED"), ("Seat belts and no smoking", "ON"), ("Parking brake", "SET"),
            ]),
            list("Before start", [
                ("Briefing", "CONFIRMED"), ("Baro reference", "SET"), ("Beacon", "ON"), ("Thrust levers", "IDLE"),
                ("Windows and doors", "CLOSED"), ("Pushback and clearance", "OBTAINED"),
            ]),
            list("After start", [
                ("Engine anti-ice", "AS REQUIRED"), ("Flaps", "SET FOR TAKEOFF"), ("Pitch trim", "SET"),
                ("Flight controls", "CHECKED"), ("Ground equipment", "CLEARED"),
            ]),
            list("Taxi", [
                ("Brakes", "CHECKED"), ("Flight instruments", "CHECKED"), ("Taxi route", "BRIEFED"), ("Radar and terrain", "AS REQUIRED"),
            ]),
            list("Before takeoff", [
                ("Takeoff speeds and thrust", "CONFIRMED"), ("Runway", "CONFIRMED"), ("Transponder", "ON / TA/RA"), ("Strobes and landing lights", "ON"),
                ("Cabin", "READY"), ("Takeoff clearance", "RECEIVED"),
            ]),
            list("After takeoff", [
                ("Landing gear", "UP"), ("Flaps", "RETRACTED"), ("Packs", "ON"), ("Altimeters", "SET STD AT TRANSITION"),
            ]),
            list("Cruise", [
                ("Fuel", "CHECKED"), ("Flight plan", "MONITORED"), ("Weather and NOTAMs", "REVIEWED"),
            ]),
            list("Descent preparation", [
                ("ATIS and weather", "OBTAINED"), ("Landing performance", "CHECKED"), ("Approach", "BRIEFED"), ("Minimum", "SET"), ("Autobrake", "SET"),
            ]),
            list("Approach", [
                ("Baro reference", "SET"), ("Seat belts", "ON"), ("Landing lights", "ON"), ("Engine anti-ice", "AS REQUIRED"),
            ]),
            list("Landing", [
                ("Landing gear", "DOWN"), ("Flaps", "FULL / CONF 3"), ("Spoilers", "ARMED"), ("Landing clearance", "RECEIVED"),
            ]),
            list("After landing", [
                ("Spoilers", "DISARMED"), ("Flaps", "RETRACTED"), ("Strobes and landing lights", "OFF"), ("Radar and transponder", "OFF / STBY"), ("APU", "START"),
            ]),
            list("Parking", [
                ("Parking brake", "SET"), ("Engines", "OFF"), ("Seat belts", "OFF"), ("Beacon", "OFF"), ("Fuel pumps", "OFF"),
            ]),
            list("Securing the aircraft", [
                ("ADIRS", "OFF"), ("Oxygen", "CHECKED"), ("APU and batteries", "OFF"), ("Documents", "COMPLETED"),
            ]),
        ]
    }
}
