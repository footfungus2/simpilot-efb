import Foundation

/// Real-world weather straight from aviationweather.gov, so weather layers work without the bridge.
/// Worldwide METARs/TAFs come from AWC's gzip cache files (one download each); single airports and SIGMETs from the
/// JSON API.
enum WeatherService {
    enum Failure: LocalizedError {
        case invalidAirport
        case http(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .invalidAirport: return "Enter a valid four-character airport ICAO."
            case let .http(code): return "aviationweather.gov is unavailable (HTTP \(code))."
            case .unreadable: return "aviationweather.gov sent data the app can't read."
            }
        }
    }

    private static let api = "https://aviationweather.gov/api/data"
    private static let cacheFiles = "https://aviationweather.gov/data/cache"
    private static let health = RequestHealth()
    private static let airports = AirportCache()

    private actor RequestHealth {
        private var available: [String: Bool] = [:]

        func report(_ success: Bool, source: String, error: Error? = nil) {
            guard available[source] != success else { return }
            let recovering = available[source] == false
            available[source] = success
            DiagnosticLog.record(success ? .info : .warning, "Weather",
                                 success ? "\(source) data \(recovering ? "recovered" : "loaded")" : "\(source) data unavailable", error: error)
        }
    }

    /// Single-airport weather, kept two minutes so switching airports in the briefing is instant.
    private actor AirportCache {
        private var entries: [String: AirportWeather] = [:]

        func get(_ icao: String) -> AirportWeather? {
            guard let w = entries[icao], Date().timeIntervalSince(w.loadedAt) < 120 else { return nil }
            return w
        }

        func put(_ w: AirportWeather) { entries[w.icao] = w }
    }

    // MARK: Worldwide (map layer)

    /// Every current METAR (about 5 000 stations), unzipped and parsed off the main thread.
    static func worldMetars() async throws -> [MetarReport] {
        let data = try await download("\(cacheFiles)/metars.cache.csv.gz", source: "METAR")
        let reports = try await Task.detached(priority: .utility) {
            WeatherParser.metars(csv: try Gzip.decompressIfNeeded(data))
        }.value
        guard !reports.isEmpty else { throw Failure.unreadable }
        return reports
    }

    /// Every current TAF (about 3 000 stations), unzipped and parsed off the main thread.
    static func worldTafs() async throws -> [TafReport] {
        let data = try await download("\(cacheFiles)/tafs.cache.xml.gz", source: "TAF")
        let reports = try await Task.detached(priority: .utility) {
            WeatherParser.tafs(xml: try Gzip.decompressIfNeeded(data))
        }.value
        guard !reports.isEmpty else { throw Failure.unreadable }
        return reports
    }

    /// International SIGMETs.
    static func sigmets() async throws -> [Sigmet] {
        WeatherParser.sigmets(json: try await getJSON("\(api)/isigmet?format=json", source: "SIGMET"))
    }

    // MARK: One airport (briefing, airport card)

    /// METAR and TAF of one airport. Either may be missing (none issued, or its request failed); throws only when
    /// both requests fail.
    static func airport(_ icao: String, force: Bool = false) async throws -> AirportWeather {
        let icao = icao.uppercased()
        guard isValid(icao) else { throw Failure.invalidAirport }
        if !force, let cached = await airports.get(icao) { return cached }
        async let metar = attempt { try await getJSON("\(api)/metar?ids=\(icao)&format=json", source: "METAR").lazy.compactMap(WeatherParser.metar(json:)).first }
        async let taf = attempt { try await getJSON("\(api)/taf?ids=\(icao)&format=json", source: "TAF").lazy.compactMap(WeatherParser.taf(json:)).first }
        let (m, t) = await (metar, taf)
        if case let .failure(error) = m, case .failure = t { throw error }
        var weather = AirportWeather(icao: icao, loadedAt: Date())
        switch m {
        case let .success(report): weather.metar = report
        case let .failure(error): weather.metarError = message(for: error)
        }
        switch t {
        case let .success(report): weather.taf = report
        case let .failure(error): weather.tafError = message(for: error)
        }
        if weather.metarError == nil && weather.tafError == nil { await airports.put(weather) }
        return weather
    }

    /// Latest raw METAR for one airport (nil if none or offline).
    static func metar(icao: String) async -> String? {
        guard isValid(icao), let list = try? await getJSON("\(api)/metar?ids=\(icao)&format=json", source: "METAR") else { return nil }
        return list.first?["rawOb"] as? String
    }

    /// Four ASCII letters/digits, so nothing else ends up in a request URL.
    static func isValid(_ icao: String) -> Bool {
        icao.count == 4 && icao.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }

    /// Short message for the UI.
    static func message(for error: Error) -> String {
        if let failure = error as? Failure { return failure.errorDescription ?? "Weather unavailable." }
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .networkConnectionLost?, .dataNotAllowed?: return "No internet connection."
        case .timedOut?: return "aviationweather.gov didn't answer in time."
        case .cannotFindHost?, .cannotConnectToHost?, .dnsLookupFailed?: return "aviationweather.gov can't be reached."
        default: return "Weather couldn't be loaded."
        }
    }

    // MARK: Requests

    private static func attempt<T: Sendable>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private static func download(_ rawURL: String, source: String) async throws -> Data {
        do {
            guard let url = URL(string: rawURL) else { throw URLError(.badURL) }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue("SimPilotEFB", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
            try Task.checkCancellation()
            await health.report(true, source: source)
            return data
        } catch {
            if !Task.isCancelled, (error as? URLError)?.code != .cancelled {
                await health.report(false, source: source, error: error)
            }
            throw error
        }
    }

    private static func getJSON(_ rawURL: String, source: String) async throws -> [[String: Any]] {
        do {
            guard let url = URL(string: rawURL) else { throw URLError(.badURL) }
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("SimPilotEFB", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
            let list: [[String: Any]]
            if response.statusCode == 204 || data.isEmpty {
                list = []
            } else {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.unreadable }
                list = parsed
            }
            try Task.checkCancellation()
            await health.report(true, source: source)
            return list
        } catch {
            if !Task.isCancelled, (error as? URLError)?.code != .cancelled {
                await health.report(false, source: source, error: error)
            }
            throw error
        }
    }
}
