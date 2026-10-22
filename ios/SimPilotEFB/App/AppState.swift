import Combine
import Foundation
import SwiftUI

enum Module: Equatable {
    case map
    case charts
    case aircraft
}

/// App-wide state: settings, the loaded flight, and what's on screen.
@MainActor
final class AppState: ObservableObject {
    let bridge = BridgeClient()
    let vatsim = VatsimStore()
    let vatsimAssistant = VatsimAssistant()
    let chartPack = ChartPack()
    lazy var chartsModel = ChartsModel(bridge: bridge, pack: chartPack)

    // Settings (persisted)
    @Published var bridgeHost: String { didSet { defaults.set(bridgeHost, forKey: "bridgeHost") } }
    @Published var simbriefUser: String { didSet { defaults.set(simbriefUser, forKey: "simbriefUser") } }
    @Published var night: Bool { didSet { defaults.set(night, forKey: "night") } }

    // Testing without the sim: fly the loaded SimBrief route with a simulated aircraft.
    @Published var demoEnabled = false { didSet { updateDemo() } }
    @Published var demoSpeed: Double = 8 { didSet { demo.speed = demoSpeed } }
    private lazy var demo = DemoFlight { [weak self] o in self?.bridge.ownship.updateFromDemo(o) }

    // Flight
    @Published private(set) var ofp: Ofp?
    @Published private(set) var ofpLoading = false
    @Published var ofpError: String?

    // Navigation
    @Published var module: Module = .map
    @Published var chartsAirport: String?
    @Published var sidebarVisible = true
    @Published var showSettings = false
    @Published var showOfp = false
    @Published var showVerticalProfile = false
    @Published var enrouteHigh = true
    @Published var followOwnship = true
    /// A chart laid over the moving map ("Show on map" in the chart viewer).
    @Published var chartOverlay: ChartOverlay?
    @Published var chartOverlayOpacity = 0.85
    /// Chart annotate mode (fingers draw too; the Apple Pencil always draws on charts).
    @Published var annotating = false
    @Published var annotationClearToken = 0
    /// Chart viewer and moving map side by side.
    @Published var splitView = false

    // Airport map data loaded by the moving map: runway geometry (ON RWY / APRCH banners) and taxiway names.
    @Published private(set) var runways: [String: RunwayAwareness] = [:]
    @Published private(set) var taxiwayNames: [String: [String]] = [:]
    /// Taxi route given by ATC, highlighted on the airport map (taxiway names in order).
    @Published var taxiRoute: [String] = []
    @Published var taxiRouteAirport: String?
    /// NAV filters for the enroute map, and the waypoint/navaid/airport whose details card is open.
    @Published var mapFilters = MapFilters.load() { didSet { mapFilters.save() } }
    @Published var mapPick: MapPick?

    func setAirportData(icao: String, features: [[String: Any]]) {
        runways[icao] = RunwayAwareness(features: features)
        let names = features.compactMap { f -> String? in
            guard let p = f["properties"] as? [String: Any], p["kind"] as? String == "taxi-line" else { return nil }
            let ref = (p["ref"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return ref.isEmpty ? nil : ref
        }
        taxiwayNames[icao] = Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Runway banner for the current aircraft position, if any.
    func runwayStatus(_ o: Ownship?) -> RunwayAwareness.Status? {
        guard let o else { return nil }
        for r in runways.values { if let s = r.status(o) { return s } }
        return nil
    }

    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    init() {
        bridgeHost = defaults.string(forKey: "bridgeHost") ?? ""
        simbriefUser = defaults.string(forKey: "simbriefUser") ?? ""
        night = defaults.object(forKey: "night") as? Bool ?? true
        if let data = defaults.data(forKey: "ofp"), let saved = try? JSONDecoder().decode(Ofp.self, from: data) {
            ofp = saved
        }
        // Re-publish bridge changes so views observing AppState see connection updates.
        bridge.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var theme: Theme { Theme(night: night) }

    func connect() {
        bridge.start(manualHost: bridgeHost)
    }

    /// Loads the latest SimBrief OFP directly from simbrief.com (works without the bridge).
    func loadOfp() async {
        ofpLoading = true
        defer { ofpLoading = false }
        do {
            let loaded = try await SimBriefService.fetchLatest(user: simbriefUser)
            ofp = loaded
            ofpError = nil
            if let data = try? JSONEncoder().encode(loaded) { defaults.set(data, forKey: "ofp") }
            // Pre-load charts for every airport of the flight while the sim is running.
            for icao in flightAirports.map(\.icao) { bridge.send(requestCharts: icao) }
            if demoEnabled { demo.start(ofp: loaded) }
        } catch {
            ofpError = error.localizedDescription
        }
    }

    func clearFlight() {
        ofp = nil
        defaults.removeObject(forKey: "ofp")
        demoEnabled = false
    }

    func restartDemo() {
        demo.restart()
    }

    private func updateDemo() {
        bridge.ownship.demoActive = demoEnabled
        if demoEnabled, let ofp {
            demo.speed = demoSpeed
            demo.start(ofp: ofp)
            followOwnship = true
        } else {
            demo.stop()
        }
    }

    var flightAirports: [OfpAirport] {
        guard let ofp else { return [] }
        return [ofp.origin, ofp.destination] + ofp.alternates
    }

    func openCharts(_ icao: String) {
        chartsModel.preferredProcedures = flightProcedures(at: icao)
        chartsAirport = icao
        module = .charts
    }

    /// The flight's SID (departure) or STAR (arrival) at an airport, as named in the OFP navlog (e.g. "CLN5S").
    func flightProcedures(at icao: String) -> Set<String> {
        guard let ofp else { return [] }
        let procs = ofp.navlog.filter(\.isSidStar).map(\.airway).filter { !$0.isEmpty && $0 != "DCT" }
        if icao == ofp.origin.icao, let sid = procs.first { return [sid] }
        if icao == ofp.destination.icao, let star = procs.last, star != procs.first { return [star] }
        return []
    }

    /// "Cycle: 2510" title from the OFP's AIRAC, like the mPilot top bar.
    var cycleTitle: String {
        guard let airac = ofp?.airac, !airac.isEmpty else { return "Cycle: –" }
        if let range = AiracCycle.validity(of: airac) { return "Cycle: \(airac): \(range)" }
        return "Cycle: \(airac)"
    }

    var routeSubtitle: String {
        guard let ofp else { return "No flight loaded" }
        return "\(ofp.origin.icao)-\(ofp.destination.icao)" + (demoEnabled ? " · DEMO FLIGHT" : "")
    }
}

enum AiracCycle {
    /// AIRAC cycles are 28 days from the 2020-01-02 epoch (cycle 2001).
    static func validity(of ident: String) -> String? {
        guard ident.count == 4, let yy = Int(ident.prefix(2)), let nn = Int(ident.suffix(2)), nn >= 1, nn <= 14 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let epoch = cal.date(from: DateComponents(year: 2020, month: 1, day: 2)) else { return nil }
        // First cycle starting in year 20yy.
        var start = epoch
        while cal.component(.year, from: start) < 2000 + yy {
            start = cal.date(byAdding: .day, value: 28, to: start)!
        }
        guard let from = cal.date(byAdding: .day, value: 28 * (nn - 1), to: start),
              cal.component(.year, from: from) == 2000 + yy,
              let to = cal.date(byAdding: .day, value: 27, to: from) else { return nil }
        let f = DateFormatter()
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return "\(f.string(from: from)) - \(f.string(from: to))"
    }
}
