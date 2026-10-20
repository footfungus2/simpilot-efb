import Foundation

/// Fetches the latest SimBrief OFP directly from simbrief.com, so the Flight Folder works without the bridge.
/// Mirrors bridge/src/simbrief.ts (SimBrief's JSON is all strings; numbers are parsed here).
enum SimBriefService {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func fetchLatest(user: String) async throws -> Ofp {
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Failure(message: "Enter your SimBrief username in Settings.") }
        var comps = URLComponents(string: "https://www.simbrief.com/api/xml.fetcher.php")!
        let key = trimmed.allSatisfy(\.isNumber) ? "userid" : "username"
        comps.queryItems = [URLQueryItem(name: key, value: trimmed), URLQueryItem(name: "json", value: "1")]

        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (json?["fetch"] as? [String: Any])?["status"] as? String
        guard let json, (response as? HTTPURLResponse)?.statusCode == 200, status == nil || status == "Success" else {
            throw Failure(message: status ?? "SimBrief returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return normalize(json)
    }

    static func normalize(_ raw: [String: Any]) -> Ofp {
        let general = raw["general"] as? [String: Any] ?? [:]
        let params = raw["params"] as? [String: Any] ?? [:]
        let times = raw["times"] as? [String: Any] ?? [:]
        let fuel = raw["fuel"] as? [String: Any] ?? [:]
        let aircraft = raw["aircraft"] as? [String: Any] ?? [:]
        let files = raw["files"] as? [String: Any] ?? [:]

        var cum = 0.0
        let fixes = list((raw["navlog"] as? [String: Any])?["fix"]).map { f -> OfpFix in
            let leg = num(f["distance"])
            cum += leg
            return OfpFix(ident: str(f["ident"]), name: str(f["name"]), type: str(f["type"]),
                          lat: num(f["pos_lat"]), lon: num(f["pos_long"]), altFt: num(f["altitude_feet"]),
                          airway: str(f["via_airway"]), stage: str(f["stage"]), isSidStar: str(f["is_sid_star"]) == "1",
                          legNm: leg, cumNm: cum, frequency: str(f["frequency"]))
        }

        let pdfLink = str((files["pdf"] as? [String: Any])?["link"])
        let dir = str(files["directory"])
        let callsign = str((raw["atc"] as? [String: Any])?["callsign"])
        let distance = num(general["route_distance"])

        return Ofp(
            fetchedAt: Date().timeIntervalSince1970 * 1000,
            airac: str(params["airac"]),
            callsign: callsign.isEmpty ? str(general["icao_airline"]) + str(general["flight_number"]) : callsign,
            aircraft: .init(icao: str(aircraft["icaocode"]), name: str(aircraft["name"]), reg: str(aircraft["reg"])),
            origin: airport(raw["origin"]),
            destination: airport(raw["destination"]),
            alternates: list(raw["alternate"]).map(airport).filter { !$0.icao.isEmpty },
            route: str(general["route"]),
            distanceNm: distance > 0 ? distance : num(general["gc_distance"]),
            cruiseFl: Int((num(general["initial_altitude"]) / 100).rounded()),
            costIndex: str(general["costindex"]),
            times: .init(schedOut: num(times["sched_out"]), schedOff: num(times["sched_off"]),
                         schedOn: num(times["sched_on"]), schedIn: num(times["sched_in"]), eteSec: num(times["est_time_enroute"])),
            fuel: .init(units: str(params["units"]).isEmpty ? "kgs" : str(params["units"]),
                        ramp: num(fuel["plan_ramp"]), takeoff: num(fuel["plan_takeoff"]),
                        landing: num(fuel["plan_landing"]), minTakeoff: num(fuel["min_takeoff"])),
            navlog: fixes,
            ofpHtml: str((raw["text"] as? [String: Any])?["plan_html"]),
            pdfUrl: !pdfLink.isEmpty && !dir.isEmpty ? dir + pdfLink : nil
        )
    }

    private static func airport(_ any: Any?) -> OfpAirport {
        let a = any as? [String: Any] ?? [:]
        return OfpAirport(icao: str(a["icao_code"]), iata: str(a["iata_code"]), name: str(a["name"]),
                          lat: num(a["pos_lat"]), lon: num(a["pos_long"]), elevFt: num(a["elevation"]),
                          planRwy: str(a["plan_rwy"]), metar: str(a["metar"]))
    }

    /// SimBrief sends a single object instead of a one-element array.
    private static func list(_ any: Any?) -> [[String: Any]] {
        if let arr = any as? [[String: Any]] { return arr }
        if let one = any as? [String: Any] { return [one] }
        return []
    }

    private static func str(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return "" // missing, or {} for empty fields
        }
    }

    private static func num(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        return Double(str(any).trimmingCharacters(in: .whitespaces)) ?? 0
    }
}
