import Foundation

/// Real-world weather straight from aviationweather.gov, so weather layers work without the bridge.
/// Mirrors bridge/src/weather.ts.
enum WeatherService {
    private static let base = "https://aviationweather.gov/api/data"
    private static let health = RequestHealth()

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

    /// METAR indicators inside a box, coloured like the Lido graphical METAR indicator.
    static func metars(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) async throws -> [MetarStation] {
        let bbox = String(format: "%.1f,%.1f,%.1f,%.1f", minLat, minLon, maxLat, maxLon)
        let list = try await getJSON("\(base)/metar?bbox=\(bbox)&format=json", source: "METAR")
        return list.compactMap { m in
            guard let icao = m["icaoId"] as? String, let lat = m["lat"] as? Double, let lon = m["lon"] as? Double,
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return MetarStation(icao: icao, lat: lat, lon: lon, category: category(m),
                                raw: m["rawOb"] as? String, obsTime: m["obsTime"] as? Double)
        }
    }

    /// Latest raw METAR for one airport (nil if none or offline).
    static func metar(icao: String) async -> String? {
        guard icao.count == 4, icao.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }),
              let list = try? await getJSON("\(base)/metar?ids=\(icao)&format=json", source: "METAR") else { return nil }
        return list.first?["rawOb"] as? String
    }

    /// International SIGMETs as GeoJSON data (FeatureCollection of polygons).
    static func sigmetsGeoJSON() async throws -> Data {
        let list = try await getJSON("\(base)/isigmet?format=json", source: "SIGMET")
        let features: [[String: Any]] = list.compactMap { s in
            guard let coords = s["coords"] as? [[String: Any]], coords.count >= 3 else { return nil }
            var ring = coords.compactMap { c -> [Double]? in
                guard let lon = c["lon"] as? Double, let lat = c["lat"] as? Double,
                      (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
                return [lon, lat]
            }
            guard ring.count >= 3, ring.count == coords.count else { return nil }
            if ring.first != ring.last, let first = ring.first { ring.append(first) }
            return [
                "type": "Feature",
                "properties": ["hazard": s["hazard"] as? String ?? "", "fir": s["firId"] as? String ?? ""],
                "geometry": ["type": "Polygon", "coordinates": [ring]],
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }

    /// green ≥ 5 km and ceiling ≥ 1500 ft; amber ≥ 1.5 km / 500 ft; red below.
    static func category(_ m: [String: Any]) -> String {
        var visSm = Double.nan
        if let v = m["visib"] as? Double { visSm = v }
        if let v = m["visib"] as? String { visSm = Double(v.replacingOccurrences(of: "+", with: "")) ?? .nan }
        let clouds = m["clouds"] as? [[String: Any]] ?? []
        let ceiling = clouds
            .filter { ["BKN", "OVC", "OVX"].contains($0["cover"] as? String ?? "") }
            .map { ($0["base"] as? Double) ?? 0 }
            .min() ?? .infinity
        if visSm.isNaN && ceiling == .infinity { return "unknown" }
        let visKm = visSm.isNaN ? .infinity : visSm * 1.609
        if visKm < 1.5 || ceiling < 500 { return "red" }
        if visKm < 5 || ceiling < 1500 { return "amber" }
        return "green"
    }

    private static func getJSON(_ rawURL: String, source: String) async throws -> [[String: Any]] {
        do {
            guard let url = URL(string: rawURL) else { throw URLError(.badURL) }
            var req = URLRequest(url: url)
            req.setValue("SimPilotEFB", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.statusCode) else { throw NSError(domain: "HTTP", code: response.statusCode) }
            let list: [[String: Any]]
            if response.statusCode == 204 { list = [] }
            else {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw URLError(.cannotParseResponse)
                }
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
