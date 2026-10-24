import Foundation

/// Turns aviationweather.gov data into weather reports: the worldwide METAR cache (CSV), the TAF cache (XML) and the
/// JSON API (single airports, SIGMETs). Pure functions, safe to run off the main thread.
///
/// Unit quirks: AWC's METAR vertical visibility fields are in hundreds of feet (the OVX layer carries it in feet, so
/// METARs use that); TAF vertical visibility is in feet.
enum WeatherParser {
    // MARK: METAR cache (metars.cache.csv)

    static func metars(csv data: Data) -> [MetarReport] {
        let rows = CSVReader.rows(data)
        guard let header = rows.first else { return [] }
        var columns: [String: Int] = [:]
        for (i, name) in header.enumerated() where columns[name] == nil { columns[name] = i }
        let covers = header.indices.filter { header[$0] == "sky_cover" }
        let bases = header.indices.filter { header[$0] == "cloud_base_ft_agl" }
        guard let iRaw = columns["raw_text"], let iId = columns["station_id"],
              let iLat = columns["latitude"], let iLon = columns["longitude"] else { return [] }

        var out: [MetarReport] = []
        out.reserveCapacity(rows.count)
        for row in rows.dropFirst() where row.count == header.count {
            func field(_ name: String) -> String? {
                guard let i = columns[name] else { return nil }
                return nonEmpty(row[i])
            }
            guard let lat = Double(row[iLat]), let lon = Double(row[iLon]), (-90...90).contains(lat), (-180...180).contains(lon),
                  row[iId].count >= 3 else { continue }
            var c = WxConditions()
            setWind(field("wind_dir_degrees"), field("wind_speed_kt"), field("wind_gust_kt"), on: &c)
            (c.visibilitySM, c.visibilityOrMore) = visibility(field("visibility_statute_mi"))
            if c.visibilitySM == nil { (c.visibilitySM, c.visibilityOrMore) = ndvVisibility(row[iRaw]) }
            c.weather = field("wx_string")
            for (ci, bi) in zip(covers, bases) {
                guard let cover = nonEmpty(row[ci]) else { continue }
                c.clouds.append(WxCloud(cover: cover, baseFt: Int(row[bi])))
            }
            out.append(MetarReport(icao: row[iId], name: nil, lat: lat, lon: lon,
                                   elevationM: field("elevation_m").flatMap(Double.init),
                                   observed: field("observation_time").flatMap(date),
                                   raw: row[iRaw], conditions: c,
                                   temperatureC: field("temp_c").flatMap(Double.init),
                                   dewpointC: field("dewpoint_c").flatMap(Double.init),
                                   altimeterHpa: field("altim_in_hg").flatMap(Double.init).map { $0 * 33.8639 }))
        }
        return out
    }

    // MARK: TAF cache (tafs.cache.xml)

    static func tafs(xml data: Data) -> [TafReport] {
        let delegate = TafXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.tafs
    }

    // MARK: JSON API

    /// One entry of `/api/data/metar?format=json`.
    static func metar(json m: [String: Any]) -> MetarReport? {
        guard let icao = m["icaoId"] as? String, let lat = double(m["lat"]), let lon = double(m["lon"]) else { return nil }
        let raw = m["rawOb"] as? String ?? ""
        var c = WxConditions()
        setWind(m["wdir"], m["wspd"], m["wgst"], on: &c)
        (c.visibilitySM, c.visibilityOrMore) = visibility(m["visib"])
        if c.visibilitySM == nil { (c.visibilitySM, c.visibilityOrMore) = ndvVisibility(raw) }
        c.weather = nonEmpty(m["wxString"] as? String)
        c.clouds = clouds(m["clouds"])
        if c.clouds.isEmpty, let cover = m["cover"] as? String, ["CAVOK", "NSC", "NCD", "SKC", "CLR"].contains(cover) {
            c.clouds = [WxCloud(cover: cover)]
        }
        return MetarReport(icao: icao, name: nonEmpty(m["name"] as? String), lat: lat, lon: lon,
                           elevationM: double(m["elev"]), observed: epoch(m["obsTime"]), raw: raw, conditions: c,
                           temperatureC: double(m["temp"]), dewpointC: double(m["dewp"]), altimeterHpa: double(m["altim"]))
    }

    /// One entry of `/api/data/taf?format=json`; `fcsts` are in the order of the raw text.
    static func taf(json t: [String: Any]) -> TafReport? {
        guard let icao = t["icaoId"] as? String, let lat = double(t["lat"]), let lon = double(t["lon"]),
              let from = epoch(t["validTimeFrom"]), let to = epoch(t["validTimeTo"]) else { return nil }
        let fcsts = t["fcsts"] as? [[String: Any]] ?? []
        let groups = fcsts.enumerated().compactMap { i, f -> TafGroup? in
            guard let start = epoch(f["timeFrom"]), let end = epoch(f["timeTo"]) else { return nil }
            var c = WxConditions()
            setWind(f["wdir"], f["wspd"], f["wgst"], on: &c)
            (c.visibilitySM, c.visibilityOrMore) = visibility(f["visib"])
            c.weather = nonEmpty(f["wxString"] as? String)
            c.clouds = clouds(f["clouds"])
            c.verticalVisFt = int(f["vertVis"])
            if let h = int(f["wshearHgt"]), let d = int(f["wshearDir"]), let s = int(f["wshearSpd"]) {
                c.windShear = WxWindShear(heightFt: h, dirDeg: d, speedKt: s)
            }
            return TafGroup(change: change(f["fcstChange"] as? String), probability: int(f["probability"]),
                            from: start, to: end, becomingAt: epoch(f["timeBec"]), conditions: c, rawIndex: i)
        }
        return TafReport(icao: icao, name: nonEmpty(t["name"] as? String), lat: lat, lon: lon,
                         issued: (t["issueTime"] as? String).flatMap(date), validFrom: from, validTo: to,
                         raw: t["rawTAF"] as? String ?? "", groups: groups)
    }

    /// `/api/data/isigmet?format=json`: single areas (`coords` = points) and multi-area SIGMETs (`coords` = rings).
    static func sigmets(json list: [[String: Any]]) -> [Sigmet] {
        var used: [String: Int] = [:]
        return list.compactMap { s in
            guard let from = epoch(s["validTimeFrom"]), let to = epoch(s["validTimeTo"]) else { return nil }
            let rings = sigmetRings(s["coords"])
            guard !rings.isEmpty else { return nil }
            let fir = s["firId"] as? String ?? ""
            let series = nonEmpty(s["seriesId"] as? String)
            var id = "\(fir)-\(series ?? "")-\(Int(from.timeIntervalSince1970))"
            used[id, default: 0] += 1
            if let n = used[id], n > 1 { id += "-\(n)" }
            let raw = s["rawSigmet"] as? String ?? ""
            var movement: String?
            if let dir = nonEmpty(s["dir"] as? String), dir != "-" {
                let speed = int(s["spd"]) ?? 0
                movement = speed > 0 ? "Moving \(dir) at \(speed) kt" : "Moving \(dir)"
            } else if raw.contains(" STNR") {
                movement = "Stationary"
            }
            return Sigmet(id: id, hazard: (s["hazard"] as? String ?? "").uppercased(), qualifier: nonEmpty(s["qualifier"] as? String),
                          firId: fir, firName: nonEmpty(s["firName"] as? String), series: series,
                          baseFt: int(s["base"]), topFt: int(s["top"]), validFrom: from, validTo: to, raw: raw,
                          movement: movement, change: nonEmpty(s["chng"] as? String), rings: rings)
        }
    }

    // MARK: Field helpers

    /// "6+" / "10+" → (6, true); "2.49" or 2.49 → (2.49, false); empty → nil.
    static func visibility(_ any: Any?) -> (Double?, Bool) {
        if let n = any as? NSNumber { return (n.doubleValue, false) }
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return (nil, false) }
        if s.hasSuffix("+") { return (Double(s.dropLast()), true) }
        return (Double(s), false)
    }

    /// Automatic stations reporting "9999NDV" (no directional variation) get no visibility from AWC; read the group.
    static func ndvVisibility(_ raw: String) -> (Double?, Bool) {
        guard let r = raw.range(of: "NDV") else { return (nil, false) }
        let before = raw[..<r.lowerBound]
        let digits = before.suffix(4)
        guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let meters = Double(digits),
              before.dropLast(4).last.map({ $0 == " " }) ?? true else { return (nil, false) }
        return (meters / 1609.344, meters >= 9999)
    }

    /// AWC timestamps: "2026-10-24T10:27:00.000Z" (fractional seconds ignored).
    static func date(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 19, u[4] == 45, u[7] == 45, u[10] == 84 || u[10] == 32, u[13] == 58, u[16] == 58 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int32? {
            var v: Int32 = 0
            for i in start..<start + length {
                guard (48...57).contains(u[i]) else { return nil }
                v = v * 10 + Int32(u[i] - 48)
            }
            return v
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return nil }
        var t = tm()
        t.tm_year = year - 1900
        t.tm_mon = month - 1
        t.tm_mday = day
        t.tm_hour = hour
        t.tm_min = minute
        t.tm_sec = second
        return Date(timeIntervalSince1970: TimeInterval(timegm(&t)))
    }

    fileprivate static func setWind(_ dir: Any?, _ speed: Any?, _ gust: Any?, on c: inout WxConditions) {
        c.windSpeedKt = int(speed)
        c.windGustKt = int(gust)
        if (dir as? String)?.uppercased() == "VRB" {
            c.windVariable = true
        } else if let d = int(dir) {
            // The CSV writes variable wind as direction 0 with a speed (calm is 00000KT).
            if d == 0, let s = c.windSpeedKt, s > 0 { c.windVariable = true } else { c.windDirDeg = d }
        }
    }

    fileprivate static func change(_ code: String?) -> TafGroup.Change {
        switch code?.uppercased() {
        case nil, "": return .base
        case "FM": return .from
        case "BECMG": return .becoming
        case "PROB": return .probability
        default: return .temporary // TEMPO, and Australian INTER
        }
    }

    private static func clouds(_ any: Any?) -> [WxCloud] {
        (any as? [[String: Any]] ?? []).compactMap { c in
            guard let cover = nonEmpty(c["cover"] as? String) else { return nil }
            return WxCloud(cover: cover, baseFt: int(c["base"]), type: nonEmpty(c["type"] as? String))
        }
    }

    private static func sigmetRings(_ any: Any?) -> [[[Double]]] {
        func ring(_ points: [[String: Any]]) -> [[Double]]? {
            var r: [[Double]] = points.compactMap { p in
                guard let lon = double(p["lon"]), let lat = double(p["lat"]),
                      (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
                return [lon, lat]
            }
            guard r.count >= 3, r.count == points.count else { return nil }
            // Keep a ring that crosses the antimeridian continuous (MapLibre accepts longitudes past 180°).
            if let lo = r.map({ $0[0] }).min(), let hi = r.map({ $0[0] }).max(), hi - lo > 180 {
                r = r.map { [$0[0] < 0 ? $0[0] + 360 : $0[0], $0[1]] }
            }
            if r.first != r.last { r.append(r[0]) }
            return r.count >= 4 ? r : nil
        }
        if let points = any as? [[String: Any]] { return ring(points).map { [$0] } ?? [] }
        if let areas = any as? [[[String: Any]]] { return areas.compactMap(ring) }
        return []
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "null" else { return nil }
        return s
    }

    static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return Int(exactly: n.doubleValue.rounded()) }
        if let s = any as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return Int(exactly: d.rounded()) }
        return nil
    }

    static func double(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = any as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
        return nil
    }

    /// Unix seconds (JSON) or an AWC timestamp string.
    static func epoch(_ any: Any?) -> Date? {
        if let s = any as? String { return date(s) }
        return double(any).map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - CSV

/// RFC 4180 rows: quoted fields with "" escapes, \n or \r\n line ends.
enum CSVReader {
    static func rows(_ data: Data) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let b = bytes[i]
                i += 1
                if quoted {
                    if b == 0x22 {
                        if i < bytes.count && bytes[i] == 0x22 {
                            field.append(0x22)
                            i += 1
                        } else {
                            quoted = false
                        }
                    } else {
                        field.append(b)
                    }
                    continue
                }
                switch b {
                case 0x22: quoted = true
                case 0x2C:
                    row.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                case 0x0A:
                    row.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                    rows.append(row)
                    row = []
                case 0x0D: break
                default: field.append(b)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(decoding: field, as: UTF8.self))
            rows.append(row)
        }
        return rows
    }
}

// MARK: - TAF XML

/// SAX reader for AWC's TAF XML (`<TAF>` with `<forecast>` groups in no particular order).
private final class TafXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var tafs: [TafReport] = []

    private var text = ""
    private var station = ""
    private var raw = ""
    private var lat: Double?
    private var lon: Double?
    private var issued: Date?
    private var validFrom: Date?
    private var validTo: Date?
    private var groups: [TafGroup] = []

    private var inForecast = false
    private var change: String?
    private var probability: Int?
    private var from: Date?
    private var to: Date?
    private var becoming: Date?
    private var conditions = WxConditions()
    private var windParts: [String: String] = [:]
    private var shear: (Int?, Int?, Int?) = (nil, nil, nil)

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "TAF":
            station = ""
            raw = ""
            lat = nil
            lon = nil
            issued = nil
            validFrom = nil
            validTo = nil
            groups = []
        case "forecast":
            inForecast = true
            change = nil
            probability = nil
            from = nil
            to = nil
            becoming = nil
            conditions = WxConditions()
            windParts = [:]
            shear = (nil, nil, nil)
        case "sky_condition" where inForecast:
            if let cover = WeatherParser.nonEmpty(attributes["sky_cover"]) {
                conditions.clouds.append(WxCloud(cover: cover, baseFt: WeatherParser.int(attributes["cloud_base_ft_agl"]),
                                                 type: WeatherParser.nonEmpty(attributes["cloud_type"])))
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inForecast {
            switch name {
            case "fcst_time_from": from = WeatherParser.date(value)
            case "fcst_time_to": to = WeatherParser.date(value)
            case "change_indicator": change = value
            case "probability": probability = WeatherParser.int(value)
            case "time_becoming": becoming = WeatherParser.date(value)
            case "wind_dir_degrees", "wind_speed_kt", "wind_gust_kt":
                windParts[name] = value
            case "visibility_statute_mi": (conditions.visibilitySM, conditions.visibilityOrMore) = WeatherParser.visibility(value)
            case "wx_string": conditions.weather = WeatherParser.nonEmpty(value)
            case "vert_vis_ft": conditions.verticalVisFt = WeatherParser.int(value)
            case "wind_shear_hgt_ft_agl": shear.0 = WeatherParser.int(value)
            case "wind_shear_dir_degrees": shear.1 = WeatherParser.int(value)
            case "wind_shear_speed_kt": shear.2 = WeatherParser.int(value)
            case "forecast":
                inForecast = false
                WeatherParser.setWind(windParts["wind_dir_degrees"], windParts["wind_speed_kt"], windParts["wind_gust_kt"], on: &conditions)
                if let h = shear.0, let d = shear.1, let s = shear.2 { conditions.windShear = WxWindShear(heightFt: h, dirDeg: d, speedKt: s) }
                if let from, let to {
                    groups.append(TafGroup(change: WeatherParser.change(change), probability: probability, from: from, to: to,
                                           becomingAt: becoming, conditions: conditions, rawIndex: nil))
                }
            default: break
            }
        } else {
            switch name {
            case "raw_text": raw = value
            case "station_id": station = value
            case "issue_time": issued = WeatherParser.date(value)
            case "valid_time_from": validFrom = WeatherParser.date(value)
            case "valid_time_to": validTo = WeatherParser.date(value)
            case "latitude": lat = Double(value)
            case "longitude": lon = Double(value)
            case "TAF":
                if !station.isEmpty, let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon),
                   let validFrom, let validTo {
                    tafs.append(TafReport(icao: station, lat: lat, lon: lon, issued: issued, validFrom: validFrom,
                                          validTo: validTo, raw: raw, groups: groups))
                }
            default: break
            }
        }
        text = ""
    }
}
