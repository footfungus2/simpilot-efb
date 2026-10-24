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
    /// Worldwide METAR/TAF/SIGMET data for the map's WX layer.
    let weather = WeatherStore()
    private(set) lazy var fenixCommander = FenixCommander(bridge: bridge)
    let chartPack = ChartPack()
    lazy var chartsModel = ChartsModel(bridge: bridge, pack: chartPack)

    // Settings (persisted)
    @Published var bridgeHost: String { didSet { defaults.set(bridgeHost, forKey: "bridgeHost") } }
    @Published var simbriefUser: String { didSet { defaults.set(simbriefUser, forKey: "simbriefUser") } }
    @Published var night: Bool { didSet { defaults.set(night, forKey: "night") } }

    // Customization (Settings → Customization; persisted)
    /// Night/day follows the iPad's Dark Mode setting instead of the night toggle.
    @Published var followSystemAppearance: Bool { didSet { defaults.set(followSystemAppearance, forKey: "followSystemAppearance") } }
    @Published var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: AccentChoice.defaultsKey) } }
    @Published var motion: MotionLevel { didSet { defaults.set(motion.rawValue, forKey: MotionLevel.defaultsKey) } }
    /// UTC clock in the top bar instead of the version number.
    @Published var showUtcClock: Bool { didSet { defaults.set(showUtcClock, forKey: "showUtcClock") } }
    @Published var mapTextSize: MapTextSize { didSet { defaults.set(mapTextSize.rawValue, forKey: MapTextSize.defaultsKey) } }
    @Published var routeColor: RouteColorChoice { didSet { defaults.set(routeColor.rawValue, forKey: RouteColorChoice.defaultsKey) } }
    /// 3D globe when zoomed out (off: flat map at every zoom).
    @Published var globeView: Bool { didSet { defaults.set(globeView, forKey: "globeView") } }
    @Published var showGraticule: Bool { didSet { defaults.set(showGraticule, forKey: "showGraticule") } }
    /// Charts switch to their dark version in night mode (off: charts stay white at night).
    @Published var invertChartsAtNight: Bool { didSet { defaults.set(invertChartsAtNight, forKey: "invertChartsAtNight") } }
    @Published var startModule: StartModule { didSet { defaults.set(startModule.rawValue, forKey: StartModule.defaultsKey) } }
    @Published var flightFolderAtLaunch: Bool { didSet { defaults.set(flightFolderAtLaunch, forKey: "flightFolderAtLaunch") } }

    // Map layers and tools (persisted unless noted)
    /// Low / High enroute chart in the bottom toolbar.
    @Published var enrouteHigh: Bool { didSet { defaults.set(enrouteHigh, forKey: "enrouteHigh") } }
    /// WX layer: METAR (or, with a time offset, TAF) indicators, and SIGMETs.
    @Published var wxMetars: Bool { didSet { defaults.set(wxMetars, forKey: "wxMetars") } }
    @Published var wxSigmets: Bool { didSet { defaults.set(wxSigmets, forKey: "wxSigmets") } }
    /// Weather time offset from the top bar (+00:00 … +12:00): weather shows the forecast for now + this. Not persisted.
    @Published var wxOffsetHours = 0
    /// Ruler (distance/bearing measuring) mode on the map. Not persisted.
    @Published var rulerActive = false {
        didSet {
            if !rulerActive { ruler = MapRuler() } else {
                mapPick = nil
                vatsim.selection = nil
                weather.selectedSigmet = nil
            }
        }
    }
    @Published var ruler = MapRuler()
    /// CMPY layer: highlight VATSIM traffic of your airline.
    @Published var companyTraffic: Bool { didSet { defaults.set(companyTraffic, forKey: "companyTraffic") } }
    /// Airline code typed in the CMPY panel; empty = taken from the SimBrief callsign.
    @Published var companyCodeOverride: String { didSet { defaults.set(companyCodeOverride, forKey: "companyCode") } }

    // Flight
    @Published private(set) var ofp: Ofp?
    @Published private(set) var ofpLoading = false
    @Published var ofpError: String?

    // Navigation
    @Published var module: Module = .map { didSet { defaults.set(module.storageName, forKey: "lastModule") } }
    @Published var chartsAirport: String?
    @Published var sidebarVisible = true
    @Published var showSettings = false
    @Published var showOfp = false
    @Published var showVerticalProfile = false
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
        followSystemAppearance = defaults.object(forKey: "followSystemAppearance") as? Bool ?? false
        accent = AccentChoice.current
        motion = MotionLevel.current
        showUtcClock = defaults.object(forKey: "showUtcClock") as? Bool ?? false
        mapTextSize = MapTextSize.current
        routeColor = RouteColorChoice.current
        globeView = defaults.object(forKey: "globeView") as? Bool ?? true
        showGraticule = defaults.object(forKey: "showGraticule") as? Bool ?? true
        invertChartsAtNight = defaults.object(forKey: "invertChartsAtNight") as? Bool ?? true
        startModule = StartModule(rawValue: defaults.string(forKey: StartModule.defaultsKey) ?? "") ?? .map
        flightFolderAtLaunch = defaults.object(forKey: "flightFolderAtLaunch") as? Bool ?? true
        enrouteHigh = defaults.object(forKey: "enrouteHigh") as? Bool ?? true
        wxMetars = defaults.object(forKey: "wxMetars") as? Bool ?? false
        wxSigmets = defaults.object(forKey: "wxSigmets") as? Bool ?? false
        companyTraffic = defaults.object(forKey: "companyTraffic") as? Bool ?? true
        companyCodeOverride = defaults.string(forKey: "companyCode") ?? ""
        if let data = defaults.data(forKey: "ofp"), let saved = try? JSONDecoder().decode(Ofp.self, from: data) {
            ofp = saved
        }
        // Start screen and Flight Folder from Settings → Customization.
        switch startModule {
        case .map: module = .map
        case .charts: module = .charts
        case .aircraft: module = .aircraft
        case .last: module = Module(storageName: defaults.string(forKey: "lastModule") ?? "") ?? .map
        }
        if module == .charts { chartsAirport = ofp?.origin.icao }
        sidebarVisible = flightFolderAtLaunch
        // Re-publish bridge changes so views observing AppState see connection updates.
        bridge.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        Publishers.CombineLatest3($companyTraffic, $companyCodeOverride, $ofp)
            .sink { [weak self] on, override, ofp in
                guard let self else { return }
                let code = Self.companyCode(override: override, callsign: ofp?.callsign)
                self.vatsim.companyCode = on ? code : nil
            }.store(in: &cancellables)
    }

    var theme: Theme { Theme(night: night, accent: accent) }

    /// The night/day buttons: a manual choice stops following the iPad's appearance.
    func toggleNight() {
        followSystemAppearance = false
        night.toggle()
    }

    /// Airline code for the CMPY layer: the CMPY panel's override, else the letters of the SimBrief callsign ("EZY128W" → "EZY").
    var companyCode: String? {
        Self.companyCode(override: companyCodeOverride, callsign: ofp?.callsign)
    }

    nonisolated static func companyCode(override: String, callsign: String?) -> String? {
        let code = override.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !code.isEmpty { return code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil ? code : nil }
        return callsign.flatMap(VatsimPilot.airlineCode)
    }

    func connect() {
        bridge.start(manualHost: bridgeHost)
    }

    /// Loads the latest SimBrief OFP directly from simbrief.com (works without the bridge).
    func loadOfp() async {
        guard !ofpLoading else { return }
        ofpLoading = true
        defer { ofpLoading = false }
        do {
            let loaded = try await SimBriefService.fetchLatest(user: simbriefUser)
            ofp = loaded
            ofpError = nil
            if let data = try? JSONEncoder().encode(loaded) { defaults.set(data, forKey: "ofp") }
            // Pre-load charts for every airport of the flight while the sim is running.
            for icao in flightAirports.map(\.icao) { bridge.send(requestCharts: icao) }
            DiagnosticLog.record(.info, "Flight", "SimBrief flight loaded.")
        } catch {
            ofpError = error.localizedDescription
            DiagnosticLog.record(.error, "Flight", "SimBrief flight could not be loaded.", error: error)
        }
    }

    func clearFlight() {
        ofp = nil
        defaults.removeObject(forKey: "ofp")
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
        return "\(ofp.origin.icao)-\(ofp.destination.icao)"
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
