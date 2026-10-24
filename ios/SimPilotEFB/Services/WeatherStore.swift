import Foundation

/// Worldwide weather for the map's WX layer: METAR indicators (TAF-based with a weather time offset) and SIGMETs.
///
/// Loads only while a WX layer is on and a map is on screen. Refreshes when a layer is turned on, when the offset
/// changes, when the camera comes to rest and on a timer: METARs every 5 min, TAFs and SIGMETs every 10 min.
/// A running download is never cancelled; the map picks up the result through the version counters.
@MainActor
final class WeatherStore: ObservableObject {
    enum Feed: String, CaseIterable {
        case metars = "METARs", tafs = "TAFs", sigmets = "SIGMETs"

        var refreshInterval: TimeInterval { self == .metars ? 300 : 600 }
    }

    struct FeedStatus: Equatable {
        var loading = false
        var updated: Date?
        var error: String?
        var attempted: Date?
    }

    @Published private(set) var status: [Feed: FeedStatus] = [:]
    /// Bumped whenever the GeoJSON below changes.
    @Published private(set) var indicatorVersion = 0
    @Published private(set) var sigmetVersion = 0
    /// Stations and SIGMETs in the current GeoJSON.
    @Published private(set) var indicatorCount = 0
    @Published private(set) var sigmetCount = 0
    /// SIGMET whose card is open on the map.
    @Published var selectedSigmet: String?

    private(set) var indicatorGeoJSON: Data?
    private(set) var sigmetGeoJSON: Data?
    private(set) var metars: [String: MetarReport] = [:]
    private(set) var tafs: [String: TafReport] = [:]
    private(set) var sigmets: [Sigmet] = []

    /// Mirrors of the WX settings, set by `update` (published so the WX popover's status line follows).
    @Published private(set) var showMetars = false
    @Published private(set) var showSigmets = false
    @Published private(set) var offsetHours = 0
    private var flightAirports: Set<String> = []
    private var mapsOnScreen = 0
    private var ticker: Task<Void, Never>?
    private var builtAt: Date?
    private var indicatorBuild = 0
    private var sigmetBuild = 0

    /// Now plus the time offset the GeoJSON is built for.
    private var weatherTime: Date { Date().addingTimeInterval(Double(offsetHours) * 3600) }

    /// Indicators come from METARs now, from TAFs with an offset.
    var indicatorFeed: Feed { offsetHours == 0 ? .metars : .tafs }

    var neededFeeds: [Feed] {
        (showMetars ? [indicatorFeed] : []) + (showSigmets ? [.sigmets] : [])
    }

    func sigmet(_ id: String) -> Sigmet? { sigmets.first { $0.id == id } }

    // MARK: Inputs

    func update(metars: Bool, sigmets: Bool, offsetHours: Int, flightAirports: Set<String>) {
        let timeChanged = offsetHours != self.offsetHours
        let indicatorsChanged = timeChanged || flightAirports != self.flightAirports
        if showMetars != metars { showMetars = metars }
        if showSigmets != sigmets { showSigmets = sigmets }
        if timeChanged { self.offsetHours = offsetHours }
        self.flightAirports = flightAirports
        if !sigmets, selectedSigmet != nil { selectedSigmet = nil }
        if indicatorsChanged { rebuildIndicators() }
        if timeChanged { rebuildSigmets() }
        updateTicker()
        refreshIfStale()
    }

    func mapAppeared() {
        mapsOnScreen += 1
        updateTicker()
        refreshIfStale()
    }

    func mapDisappeared() {
        mapsOnScreen = max(0, mapsOnScreen - 1)
        updateTicker()
    }

    /// Starts any download that's due (cheap to call often, e.g. whenever the camera stops).
    func refreshIfStale() {
        guard mapsOnScreen > 0 else { return }
        let now = Date()
        for feed in neededFeeds {
            let s = status[feed] ?? FeedStatus()
            guard !s.loading else { continue }
            if let updated = s.updated, now.timeIntervalSince(updated) < feed.refreshInterval { continue }
            // After a failure, wait a minute before trying again on our own (Retry is immediate).
            if s.error != nil, let attempted = s.attempted, now.timeIntervalSince(attempted) < 60 { continue }
            load(feed)
        }
    }

    /// Retries every needed feed that failed.
    func retry() {
        for feed in neededFeeds where status[feed]?.error != nil { load(feed) }
    }

    // MARK: Loading

    private func load(_ feed: Feed) {
        guard status[feed]?.loading != true else { return }
        var s = status[feed] ?? FeedStatus()
        s.loading = true
        s.attempted = Date()
        status[feed] = s
        Task {
            do {
                switch feed {
                case .metars:
                    let list = try await WeatherService.worldMetars()
                    metars = Dictionary(list.map { ($0.icao, $0) }) { a, b in
                        (a.observed ?? .distantPast) >= (b.observed ?? .distantPast) ? a : b
                    }
                case .tafs:
                    let list = try await WeatherService.worldTafs()
                    tafs = Dictionary(list.map { ($0.icao, $0) }) { a, b in
                        (a.issued ?? .distantPast) >= (b.issued ?? .distantPast) ? a : b
                    }
                case .sigmets:
                    sigmets = try await WeatherService.sigmets()
                }
                status[feed] = FeedStatus(loading: false, updated: Date(), error: nil, attempted: Date())
                if feed == .sigmets { rebuildSigmets() } else { rebuildIndicators() }
            } catch {
                var failed = status[feed] ?? FeedStatus()
                failed.loading = false
                failed.error = WeatherService.message(for: error)
                status[feed] = failed
            }
        }
    }

    // MARK: Map data

    private func rebuildIndicators() {
        indicatorBuild += 1
        let build = indicatorBuild
        let time = weatherTime, flight = flightAirports
        let metars = offsetHours == 0 ? Array(self.metars.values) : []
        let tafs = offsetHours == 0 ? [] : Array(self.tafs.values)
        builtAt = Date()
        Task {
            let result = await Task.detached(priority: .utility) {
                WeatherMapLayer.indicatorGeoJSON(metars: metars, tafs: tafs, at: time, flightAirports: flight)
            }.value
            guard build == indicatorBuild else { return } // a newer build is on its way
            indicatorGeoJSON = result.data
            indicatorCount = result.count
            indicatorVersion += 1
        }
    }

    private func rebuildSigmets() {
        sigmetBuild += 1
        let build = sigmetBuild
        let time = weatherTime, list = sigmets
        builtAt = Date()
        Task {
            let result = await Task.detached(priority: .utility) { WeatherMapLayer.sigmetGeoJSON(list, at: time) }.value
            guard build == sigmetBuild else { return }
            sigmetGeoJSON = result.data
            sigmetCount = result.count
            sigmetVersion += 1
            if let id = selectedSigmet, sigmet(id).map({ !$0.isValid(at: time) }) ?? true { selectedSigmet = nil }
        }
    }

    /// Once a minute while the layer is visible: start due downloads, and every 5 min move the weather time on
    /// (TAF groups and SIGMET validity depend on it).
    private func updateTicker() {
        let active = mapsOnScreen > 0 && (showMetars || showSigmets)
        guard active != (ticker != nil) else { return }
        if active {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.refreshIfStale()
                    if let built = self.builtAt, Date().timeIntervalSince(built) >= 300 {
                        if self.offsetHours > 0 { self.rebuildIndicators() }
                        self.rebuildSigmets()
                    }
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }
}

extension AppState {
    /// Now plus the top bar's weather time offset: the time the WX layers, the briefing and airport cards show.
    var weatherTime: Date { Date().addingTimeInterval(Double(wxOffsetHours) * 3600) }
}
