import Foundation

/// Plain-language weather for the briefing's "Decoded" mode, built from the decoded AWC fields (never from raw text).
enum WeatherDecoder {
    /// UserDefaults key of the "Decoded" switch, shared by the briefing and the airport card.
    static let decodedSettingKey = "wxDecoded"

    /// US, Canadian and Pacific stations report statute miles and inches of mercury.
    static func usesImperial(_ icao: String) -> Bool {
        guard let first = icao.first else { return false }
        return first == "K" || first == "C" || first == "P"
    }

    static func wind(_ c: WxConditions) -> String? {
        guard let speed = c.windSpeedKt else { return nil }
        if speed == 0 && c.windGustKt == nil { return "Calm" }
        var text: String
        if c.windVariable {
            text = "Variable, \(speed) kt"
        } else if let dir = c.windDirDeg {
            text = String(format: "%03d° at %d kt", dir, speed)
        } else {
            text = "\(speed) kt"
        }
        if let gust = c.windGustKt { text += ", gusts \(gust) kt" }
        return text
    }

    static func windShear(_ c: WxConditions) -> String? {
        guard let ws = c.windShear else { return nil }
        return String(format: "Wind shear at %d ft: %03d° at %d kt", ws.heightFt, ws.dirDeg, ws.speedKt)
    }

    static func visibility(_ c: WxConditions, imperial: Bool) -> String? {
        guard let sm = c.visibilitySM else { return nil }
        let metric = metres(sm * 1609.344)
        if c.visibilityOrMore {
            if imperial { return "\(miles(sm)) SM or more" }
            return sm >= 6 ? "10 km or more" : "\(metric) or more"
        }
        return imperial ? "\(miles(sm)) SM (\(metric))" : metric
    }

    static func clouds(_ c: WxConditions) -> String? {
        let whole: [String: String] = ["CAVOK": "CAVOK: no cloud below 5000 ft, no CB, visibility 10 km or more",
                                       "NSC": "No significant cloud", "NCD": "No cloud detected",
                                       "SKC": "Sky clear", "CLR": "No cloud detected"]
        if let sky = c.clouds.first(where: { whole[$0.cover] != nil }) { return whole[sky.cover] }
        let covers = ["FEW": "few", "SCT": "scattered", "BKN": "broken", "OVC": "overcast"]
        let types = ["CB": "cumulonimbus", "TCU": "towering cumulus"]
        let layers = c.clouds.compactMap { layer -> String? in
            if layer.cover == "OVX" {
                let vv = c.verticalVisFt ?? layer.baseFt
                return vv.map { "sky obscured, vertical visibility \($0) ft" } ?? "sky obscured"
            }
            var text = covers[layer.cover] ?? layer.cover.lowercased()
            if let base = layer.baseFt { text += " \(base) ft" }
            if let type = layer.type { text += " (\(types[type] ?? type))" }
            return text
        }
        if layers.isEmpty, let vv = c.verticalVisFt { return "Sky obscured, vertical visibility \(vv) ft" }
        return layers.isEmpty ? nil : capitalized(layers.joined(separator: ", "))
    }

    /// "-RA BR" → "Light rain, mist"; "+TSRA" → "Thunderstorm with heavy rain"; "VCSH" → "Showers in the vicinity".
    static func weather(_ codes: String?) -> String? {
        guard let codes else { return nil }
        let phrases = codes.split(separator: " ").map { phrase(String($0)) }.filter { !$0.isEmpty }
        return phrases.isEmpty ? nil : capitalized(phrases.joined(separator: ", "))
    }

    static func temperature(_ m: MetarReport) -> String? {
        guard let t = m.temperatureC else { return nil }
        var text = "\(degrees(t)) °C"
        if let d = m.dewpointC { text += ", dew point \(degrees(d)) °C" }
        return text
    }

    static func pressure(_ hPa: Double?, imperial: Bool) -> String? {
        guard let hPa, hPa > 800, hPa < 1100 else { return nil }
        // Nearest, not down: US stations' hPa values are converted from inches (A3027 → 1025.1).
        let hpa = String(format: "%.0f hPa", hPa.rounded())
        let inHg = String(format: "%.2f inHg", hPa / 33.8639)
        return imperial ? "\(inHg) (\(hpa))" : "\(hpa) (\(inHg))"
    }

    /// Short summary of a TAF group: wind · visibility · weather · clouds · wind shear.
    static func summary(_ c: WxConditions, imperial: Bool) -> String {
        let parts = [wind(c), visibility(c, imperial: imperial), weather(c.weather), clouds(c), windShear(c)].compactMap { $0 }
        return parts.isEmpty ? "No change reported" : parts.joined(separator: " · ")
    }

    /// "From 10:00Z", "Becoming 11:00–14:00Z", "Temporarily 10:00–18:00Z", "30 % chance, temporarily …".
    static func title(_ g: TafGroup, relativeTo now: Date = Date()) -> String {
        let range = "\(time(g.from, now)) – \(time(g.to, now))"
        switch g.change {
        case .base, .from: return "From \(time(g.from, now))"
        case .becoming: return "Becoming \(time(g.from, now)) – \(time(g.becomingAt ?? g.to, now))"
        case .temporary: return g.probability.map { "\($0) % chance, temporarily \(range)" } ?? "Temporarily \(range)"
        case .probability: return "\(g.probability ?? 30) % chance \(range)"
        }
    }

    // MARK: Helpers

    private static let descriptors = ["MI": "shallow", "PR": "partial", "BC": "patches", "DR": "low drifting",
                                      "BL": "blowing", "SH": "showers", "TS": "thunderstorm", "FZ": "freezing"]
    private static let phenomena = ["DZ": "drizzle", "RA": "rain", "SN": "snow", "SG": "snow grains", "IC": "ice crystals",
                                    "PL": "ice pellets", "GR": "hail", "GS": "small hail", "UP": "unknown precipitation",
                                    "BR": "mist", "FG": "fog", "FU": "smoke", "VA": "volcanic ash", "DU": "widespread dust",
                                    "SA": "sand", "HZ": "haze", "PY": "spray", "PO": "dust whirls", "SQ": "squalls",
                                    "FC": "funnel cloud", "SS": "sandstorm", "DS": "duststorm"]

    /// One weather group: intensity/proximity, at most one descriptor, then two-letter phenomena.
    static func phrase(_ token: String) -> String {
        guard token.contains(where: \.isLetter) else { return "" } // "//" = not observed
        if token == "NSW" { return "no significant weather" }
        if token == "+FC" { return "tornado or waterspout" }
        var rest = Substring(token)
        var intensity: String?
        if rest.hasPrefix("-") { intensity = "light"; rest = rest.dropFirst() }
        else if rest.hasPrefix("+") { intensity = "heavy"; rest = rest.dropFirst() }
        var vicinity = false, recent = false
        if rest.hasPrefix("VC") { vicinity = true; rest = rest.dropFirst(2) }
        if rest.hasPrefix("RE") { recent = true; rest = rest.dropFirst(2) }
        var descriptor: String?
        if rest.count >= 2, descriptors[String(rest.prefix(2))] != nil {
            descriptor = String(rest.prefix(2))
            rest = rest.dropFirst(2)
        }
        var names: [String] = []
        while rest.count >= 2 {
            let code = String(rest.prefix(2))
            names.append(phenomena[code] ?? code)
            rest = rest.dropFirst(2)
        }
        if !rest.isEmpty { names.append(String(rest)) }
        let list = names.joined(separator: " and ")

        var text: String
        switch descriptor {
        case "TS":
            text = list.isEmpty ? "thunderstorm" : "thunderstorm with \(intensity.map { "\($0) " } ?? "")\(list)"
            intensity = nil
        case "SH": text = list.isEmpty ? "showers" : "\(list) showers"
        case "BC": text = "\(list.isEmpty ? "fog" : list) patches"
        case let d?: text = list.isEmpty ? descriptors[d]! : "\(descriptors[d]!) \(list)"
        case nil: text = list
        }
        if let intensity { text = "\(intensity) \(text)" }
        if recent { text = "recent \(text)" }
        if vicinity { text += " in the vicinity" }
        return text
    }

    /// "10:00Z" today (UTC), "Sun 01:00Z" on another day.
    static func time(_ date: Date, _ now: Date = Date()) -> String {
        (utc.isDate(date, inSameDayAs: now) ? timeOfDay : dayAndTime).string(from: date)
    }

    /// "14:32Z" (the top bar's UTC clock).
    static func clock(_ date: Date) -> String { timeOfDay.string(from: date) }

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    private static let timeOfDay = formatter("HH:mm'Z'")
    private static let dayAndTime = formatter("EEE HH:mm'Z'")

    private static func metres(_ m: Double) -> String {
        if m >= 9999 { return "10 km" }
        if m >= 5000 { return String(format: "%.0f km", (m / 1000).rounded()) }
        return String(format: "%.0f m", (m / 100).rounded() * 100)
    }

    /// 2.5 → "2½", 0.25 → "¼", 7 → "7".
    private static func miles(_ sm: Double) -> String {
        let whole = Int(sm), frac = sm - Double(whole)
        let fractions: [(Double, String)] = [(0.125, "⅛"), (0.25, "¼"), (0.375, "⅜"), (0.5, "½"), (0.625, "⅝"), (0.75, "¾"), (0.875, "⅞")]
        guard frac > 0.06, let symbol = fractions.min(by: { abs($0.0 - frac) < abs($1.0 - frac) })?.1 else { return "\(whole)" }
        return whole == 0 ? symbol : "\(whole)\(symbol)"
    }

    private static func degrees(_ v: Double) -> String {
        let r = Int(v.rounded())
        return r < 0 ? "−\(-r)" : "\(r)"
    }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
