import Foundation

// Weather reports from aviationweather.gov (worldwide cache files and the JSON API), decoded by WeatherParser.

/// Lido-style ceiling/visibility category shown by the METAR/TAF indicators.
enum WxCategory: String, CaseIterable, Sendable {
    case green, amber, red, unknown

    /// Green: visibility ≥ 5 km and ceiling ≥ 1500 ft; amber: ≥ 1.5 km / 500 ft; red: below;
    /// unknown when neither visibility nor a ceiling is reported. A missing element counts as unlimited.
    init(visibilitySM: Double?, ceilingFt: Double?) {
        guard visibilitySM != nil || ceilingFt != nil else {
            self = .unknown
            return
        }
        let visKm = visibilitySM.map { $0 * 1.609344 } ?? .infinity
        let ceiling = ceilingFt ?? .infinity
        if visKm < 1.5 || ceiling < 500 { self = .red }
        else if visKm < 5 || ceiling < 1500 { self = .amber }
        else { self = .green }
    }

    /// Higher is worse; unknown ranks below green so it never makes a known category look worse.
    var severity: Int {
        switch self {
        case .unknown: return -1
        case .green: return 0
        case .amber: return 1
        case .red: return 2
        }
    }

    func worse(_ other: WxCategory) -> WxCategory { other.severity > severity ? other : self }

    var title: String {
        switch self {
        case .green: return "Good"
        case .amber: return "Marginal"
        case .red: return "Poor"
        case .unknown: return "Not reported"
        }
    }

    /// One-line meaning for legends.
    var meaning: String {
        switch self {
        case .green: return "Visibility 5 km or more and ceiling 1500 ft or higher"
        case .amber: return "Visibility from 1.5 km, ceiling from 500 ft"
        case .red: return "Visibility below 1.5 km or ceiling below 500 ft"
        case .unknown: return "Visibility and ceiling not reported"
        }
    }

    var hex: UInt32 {
        switch self {
        case .green: return 0x2FB24F
        case .amber: return 0xE8A33D
        case .red: return 0xD23A3A
        case .unknown: return 0x8A8F98
        }
    }
}

struct WxWindShear: Equatable, Sendable {
    var heightFt: Int
    var dirDeg: Int
    var speedKt: Int
}

struct WxCloud: Equatable, Sendable {
    /// FEW, SCT, BKN, OVC, OVX (sky obscured), or a whole-sky code: CAVOK, NSC, NCD, SKC, CLR.
    var cover: String
    var baseFt: Int?
    /// CB or TCU.
    var type: String?

    var isCeiling: Bool { cover == "BKN" || cover == "OVC" || cover == "OVX" }
}

/// What a METAR reports or a TAF group forecasts. Elements a TAF change group doesn't mention are nil/empty.
struct WxConditions: Equatable, Sendable {
    var windDirDeg: Int?
    var windVariable = false
    var windSpeedKt: Int?
    var windGustKt: Int?
    var visibilitySM: Double?
    /// "6+" / "10+": at least this far (AWC reports 9999 m as 6+ SM).
    var visibilityOrMore = false
    /// Present weather codes, e.g. "-RA BR"; "NSW" = no significant weather.
    var weather: String?
    var clouds: [WxCloud] = []
    var verticalVisFt: Int?
    /// Low-level wind shear (TAF WS group).
    var windShear: WxWindShear?

    /// Lowest broken/overcast layer or vertical visibility.
    var ceilingFt: Double? {
        var bases = clouds.filter(\.isCeiling).compactMap { $0.cover == "OVX" ? (verticalVisFt ?? $0.baseFt) : $0.baseFt }
        if let vv = verticalVisFt { bases.append(vv) }
        return bases.min().map(Double.init)
    }

    var category: WxCategory { WxCategory(visibilitySM: visibilitySM, ceilingFt: ceilingFt) }

    /// This state with a later group's reported elements replacing ours (TAF BECMG/TEMPO semantics).
    func applying(_ change: WxConditions) -> WxConditions {
        var out = self
        if change.windSpeedKt != nil {
            out.windDirDeg = change.windDirDeg
            out.windVariable = change.windVariable
            out.windSpeedKt = change.windSpeedKt
            out.windGustKt = change.windGustKt
        }
        if change.visibilitySM != nil {
            out.visibilitySM = change.visibilitySM
            out.visibilityOrMore = change.visibilityOrMore
        }
        if let wx = change.weather { out.weather = wx == "NSW" ? nil : wx }
        if !change.clouds.isEmpty || change.verticalVisFt != nil {
            out.clouds = change.clouds
            out.verticalVisFt = change.verticalVisFt
        }
        if change.windShear != nil { out.windShear = change.windShear }
        return out
    }
}

struct MetarReport: Equatable, Sendable {
    var icao: String
    var name: String?
    var lat: Double
    var lon: Double
    var elevationM: Double?
    var observed: Date?
    var raw: String
    var conditions: WxConditions
    var temperatureC: Double?
    var dewpointC: Double?
    var altimeterHpa: Double?

    var category: WxCategory { conditions.category }
}

struct TafGroup: Equatable, Sendable {
    enum Change: String, Sendable {
        case base, from = "FM", becoming = "BECMG", temporary = "TEMPO", probability = "PROB"
    }

    var change: Change
    /// PROB30/PROB40 (alone or with TEMPO).
    var probability: Int?
    var from: Date
    var to: Date
    /// BECMG: when the transition is complete (AWC `timeBec`).
    var becomingAt: Date?
    var conditions: WxConditions
    /// Position in the raw TAF text (nil when the source doesn't keep the order).
    var rawIndex: Int?

    /// Base, FM and BECMG groups set the prevailing conditions; TEMPO and PROB groups only overlay them.
    var isPrevailing: Bool { change == .base || change == .from || change == .becoming }

    /// "PROB30 TEMPO", "BECMG", "FM", "" for the base group.
    var code: String {
        switch change {
        case .base: return ""
        case .from: return "FM"
        case .becoming: return "BECMG"
        case .temporary: return probability.map { "PROB\($0) TEMPO" } ?? "TEMPO"
        case .probability: return "PROB\(probability ?? 30)"
        }
    }
}

struct TafReport: Equatable, Sendable {
    var icao: String
    var name: String?
    var lat: Double
    var lon: Double
    var issued: Date?
    var validFrom: Date
    var validTo: Date
    var raw: String
    /// Sorted by start time; base, FM and BECMG before TEMPO/PROB groups starting at the same time.
    var groups: [TafGroup]

    init(icao: String, name: String? = nil, lat: Double, lon: Double, issued: Date?, validFrom: Date, validTo: Date,
         raw: String, groups: [TafGroup]) {
        self.icao = icao
        self.name = name
        self.lat = lat
        self.lon = lon
        self.issued = issued
        self.validFrom = validFrom
        self.validTo = validTo
        self.raw = raw
        let order: (TafGroup) -> Int = { g in
            switch g.change {
            case .base: return 0
            case .from: return 1
            case .becoming: return 2
            case .temporary, .probability: return 3
            }
        }
        self.groups = groups.enumerated().sorted { a, b in
            (a.element.from, order(a.element), a.offset) < (b.element.from, order(b.element), b.offset)
        }.map(\.element)
    }

    struct Forecast: Equatable {
        /// Category of the prevailing conditions (the worse of before/after while a BECMG change is in progress).
        var prevailing: WxCategory
        /// Set when a TEMPO/PROB group covering the time is worse than the prevailing conditions.
        var temporary: WxCategory?
        /// Indices into `groups` in force at the time: the latest prevailing group, BECMG changes in progress,
        /// and TEMPO/PROB groups covering it.
        var activeGroups: Set<Int>
        var conditions: WxConditions
    }

    /// The forecast for `time`, nil outside the TAF's validity.
    ///
    /// Prevailing conditions: the latest base/FM group that has started, with every BECMG group applied once its
    /// change is complete (`becomingAt`). During a BECMG transition the worse of the old and new conditions counts,
    /// like the planning-minima rule. TEMPO/PROB groups covering the time can only make the indicator worse
    /// (`temporary`); they never improve it.
    func forecast(at time: Date) -> Forecast? {
        guard time >= validFrom, time < validTo else { return nil }
        var state: WxConditions?
        var current: Int?
        var transition: WxCategory?
        var changing: [Int] = []
        for (i, g) in groups.enumerated() where g.isPrevailing && g.from <= time {
            guard g.change == .becoming, let before = state else {
                state = g.conditions
                current = i
                transition = nil
                changing = []
                continue
            }
            let after = before.applying(g.conditions)
            if time >= (g.becomingAt ?? g.from) {
                state = after
                current = i
            } else {
                transition = (transition ?? .unknown).worse(after.category)
                changing.append(i)
            }
        }
        guard let state, let current else { return nil }
        let prevailing = transition.map { state.category.worse($0) } ?? state.category
        var temporary: WxCategory?
        var active = Set([current] + changing)
        for (i, g) in groups.enumerated() where !g.isPrevailing && g.from <= time && time < g.to {
            active.insert(i)
            let category = state.applying(g.conditions).category
            if category.severity > prevailing.severity { temporary = (temporary ?? category).worse(category) }
        }
        return Forecast(prevailing: prevailing, temporary: temporary, activeGroups: active, conditions: state)
    }
}

struct Sigmet: Identifiable, Equatable, Sendable {
    var id: String
    /// TS, TURB, ICE, VA, MTW, TC, DS, SS…
    var hazard: String
    /// SEV, EMBD, FRQ… (for VA the volcano).
    var qualifier: String?
    var firId: String
    var firName: String?
    var series: String?
    /// Levels in feet; nil base with a top means "TOP FLxxx", base 0 the surface.
    var baseFt: Int?
    var topFt: Int?
    var validFrom: Date
    var validTo: Date
    var raw: String
    var movement: String?
    /// INTSF, WKN or NC.
    var change: String?
    /// Polygon rings of [lon, lat] (several for multi-area SIGMETs).
    var rings: [[[Double]]]

    func isValid(at time: Date) -> Bool { validFrom <= time && time < validTo }

    /// "FL250–FL400", "SFC–FL140", "TOP FL450".
    var levels: String {
        func fl(_ ft: Int) -> String { String(format: "FL%03d", Int((Double(ft) / 100).rounded())) }
        switch (baseFt, topFt) {
        case let (base?, top?): return "\(base <= 0 ? "SFC" : fl(base))–\(fl(top))"
        case let (nil, top?): return "TOP \(fl(top))"
        case let (base?, nil): return base <= 0 ? "SFC" : "ABV \(fl(base))"
        case (nil, nil): return ""
        }
    }

    var hazardName: String {
        switch hazard {
        case "TS": return "Thunderstorms"
        case "TURB": return "Turbulence"
        case "ICE": return "Icing"
        case "VA": return "Volcanic ash"
        case "MTW": return "Mountain waves"
        case "TC": return "Tropical cyclone"
        case "DS": return "Duststorm"
        case "SS": return "Sandstorm"
        case "RDOACT": return "Radioactive cloud"
        default: return hazard.capitalized
        }
    }

    var qualifierName: String? {
        guard let q = qualifier?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return nil }
        let words = ["SEV": "Severe", "EMBD": "Embedded", "FRQ": "Frequent", "OCNL": "Occasional", "SQL": "Squall line",
                     "OBSC": "Obscured", "ISOL": "Isolated", "HVY": "Heavy"]
        return words[q] ?? q.capitalized
    }

    /// Area-weighted centre of the largest ring, for the map label.
    var labelPoint: [Double]? {
        guard let ring = rings.max(by: { $0.count < $1.count }), ring.count >= 3 else { return nil }
        var area = 0.0, cx = 0.0, cy = 0.0
        for (a, b) in zip(ring, ring.dropFirst() + [ring[0]]) where a.count >= 2 && b.count >= 2 {
            let cross = a[0] * b[1] - b[0] * a[1]
            area += cross
            cx += (a[0] + b[0]) * cross
            cy += (a[1] + b[1]) * cross
        }
        var point: [Double]
        if abs(area) < 1e-9 {
            let n = Double(ring.count)
            point = [ring.map { $0[0] }.reduce(0, +) / n, ring.map { $0[1] }.reduce(0, +) / n]
        } else {
            point = [cx / (3 * area), cy / (3 * area)]
        }
        if point[0] > 180 { point[0] -= 360 } // rings crossing the antimeridian are kept continuous past 180°
        return point
    }
}

/// METAR and TAF of one airport for the briefing and the airport card.
struct AirportWeather: Equatable, Sendable {
    var icao: String
    var metar: MetarReport?
    var taf: TafReport?
    /// Set when that request failed (as opposed to no report being issued).
    var metarError: String?
    var tafError: String?
    var loadedAt: Date

    var name: String? { metar?.name ?? taf?.name }
}
