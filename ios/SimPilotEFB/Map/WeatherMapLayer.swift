import CoreLocation
import MapLibre
import UIKit

/// The WX layer on the enroute map: style layers, indicator icons and GeoJSON. Data comes from `WeatherStore`.
///
/// METAR/TAF indicators are a symbol layer with collision decluttering, so the map stays readable at every zoom:
/// "metar-indicators" sits low in the layer stack (airports, navaids and route labels keep their place; indicators
/// fill the free space, flight airports, then major airports, then the worst weather first), while "metar-flight"
/// (origin, destination, alternates) sits high and is always drawn. Indicators sit just left of the airport symbol.
enum WeatherMapLayer {
    static let metarLayers = ["metar-indicators", "metar-flight"]
    static let sigmetLayers = ["sigmet-fill", "sigmet-line", "sigmet-label"]
    /// Tap targets, most specific first (SIGMET areas are hit-tested at the tap point, not in the tap box).
    static let metarTappable = ["metar-flight", "metar-indicators"]
    static let sigmetLabelTappable = ["sigmet-label"]
    static let sigmetAreaTappable = ["sigmet-fill"]

    // MARK: Style layers (spliced into MapStyle.write)

    static func metarLayer(flight: Bool, theme: Theme) -> [String: Any] {
        ["id": flight ? "metar-flight" : "metar-indicators", "type": "symbol", "source": MapStyle.metarSource,
         "maxzoom": MapStyle.ammZoom + 0.5,
         "filter": ["==", ["get", "flight"], flight],
         "layout": [
            "icon-image": ["get", "icon"],
            "icon-size": flight ? 1.15 : 1,
            // Left of the airport symbol (its ICAO label is on the right); centred on stations without one.
            "icon-offset": ["case", ["get", "offset"], ["literal", [-19, 0]], ["literal", [0, 0]]],
            "icon-allow-overlap": flight,
            "icon-padding": 1,
            "symbol-sort-key": ["get", "sort"],
            // Stations that aren't in the airport layer get their ICAO when zoomed in.
            "text-field": ["step", ["zoom"], "", 7, ["get", "label"]],
            "text-font": ["Noto Sans Bold"], "text-size": 10,
            "text-anchor": "top", "text-offset": [0, 0.8], "text-optional": true,
         ],
         "paint": ["text-color": theme.mapLabel.hexString, "text-halo-color": theme.mapLabelHalo.hexString, "text-halo-width": 1.2]]
    }

    static func sigmetFillLayer() -> [String: Any] {
        ["id": "sigmet-fill", "type": "fill", "source": MapStyle.sigmetSource, "maxzoom": MapStyle.ammZoom + 0.5,
         "filter": ["==", ["get", "kind"], "area"],
         "paint": ["fill-color": "#9B3FD1", "fill-opacity": sigmetFillOpacity(selected: nil)]]
    }

    static func sigmetLineLayer() -> [String: Any] {
        ["id": "sigmet-line", "type": "line", "source": MapStyle.sigmetSource, "maxzoom": MapStyle.ammZoom + 0.5,
         "filter": ["==", ["get", "kind"], "area"],
         "layout": ["line-join": "round"],
         "paint": ["line-color": "#B45CE8", "line-width": sigmetLineWidth(selected: nil)]]
    }

    /// The SIGMET whose card is open is drawn stronger.
    static func highlight(sigmet id: String?, in style: MLNStyle) {
        (style.layer(withIdentifier: "sigmet-fill") as? MLNFillStyleLayer)?.fillOpacity =
            NSExpression(mglJSONObject: sigmetFillOpacity(selected: id))
        (style.layer(withIdentifier: "sigmet-line") as? MLNLineStyleLayer)?.lineWidth =
            NSExpression(mglJSONObject: sigmetLineWidth(selected: id))
    }

    private static func sigmetFillOpacity(selected id: String?) -> Any {
        guard let id else { return 0.12 }
        return ["case", ["==", ["get", "id"], id], 0.28, 0.12]
    }

    private static func sigmetLineWidth(selected id: String?) -> Any {
        guard let id else { return 1.5 }
        return ["case", ["==", ["get", "id"], id], 3, 1.5]
    }

    /// Hazard and levels ("TS / TOP FL450") at the centre of each SIGMET.
    static func sigmetLabelLayer(theme: Theme) -> [String: Any] {
        ["id": "sigmet-label", "type": "symbol", "source": MapStyle.sigmetSource, "maxzoom": MapStyle.ammZoom + 0.5,
         "filter": ["==", ["get", "kind"], "label"],
         "layout": ["text-field": ["get", "label"], "text-font": ["Noto Sans Bold"], "text-size": 11,
                    "text-line-height": 1.15, "text-max-width": 12],
         "paint": ["text-color": theme.night ? "#D7A8F5" : "#7E2BB5", "text-halo-color": theme.mapLabelHalo.hexString,
                   "text-halo-width": 1.4]]
    }

    // MARK: Icons

    static func iconName(_ prevailing: WxCategory, _ temporary: WxCategory?) -> String {
        guard prevailing != .unknown, let t = temporary, t.severity > prevailing.severity else { return "wx-\(prevailing.rawValue)" }
        return "wx-\(prevailing.rawValue)-\(t.rawValue)"
    }

    /// Registers every indicator image on a freshly loaded style.
    static func addImages(to style: MLNStyle) {
        for p in WxCategory.allCases {
            style.setImage(MapIcons.metarIndicator(p), forName: iconName(p, nil))
            for t in WxCategory.allCases where p != .unknown && t.severity > p.severity {
                style.setImage(MapIcons.metarIndicator(p, temporary: t), forName: iconName(p, t))
            }
        }
    }

    // MARK: GeoJSON (built off the main thread)

    /// Indicators from METARs (now) or from TAFs at `time` (stations without a TAF valid then are left out).
    static func indicatorGeoJSON(metars: [MetarReport], tafs: [TafReport], at time: Date,
                                 flightAirports: Set<String>) -> (data: Data?, count: Int) {
        var features: [[String: Any]] = []
        features.reserveCapacity(metars.count + tafs.count)
        func add(_ icao: String, _ lat: Double, _ lon: Double, _ prevailing: WxCategory, _ temporary: WxCategory?) {
            let info = WeatherAirports.all[icao]
            let flight = flightAirports.contains(icao)
            let rank = flight ? 0 : info?.rank ?? 3
            let worst = prevailing.worse(temporary ?? prevailing)
            features.append([
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [lon, lat]],
                "properties": ["icao": icao, "icon": iconName(prevailing, temporary), "sort": rank * 10 + 2 - worst.severity,
                               "flight": flight, "offset": flight || info != nil, "label": flight || info != nil ? "" : icao],
            ])
        }
        for m in metars { add(m.icao, m.lat, m.lon, m.category, nil) }
        for t in tafs {
            guard let f = t.forecast(at: time) else { continue }
            add(t.icao, t.lat, t.lon, f.prevailing, f.temporary)
        }
        let data = try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
        return (data, features.count)
    }

    /// SIGMET areas valid at `time` plus one label point each.
    static func sigmetGeoJSON(_ sigmets: [Sigmet], at time: Date) -> (data: Data?, count: Int) {
        var features: [[String: Any]] = []
        var count = 0
        for s in sigmets where s.isValid(at: time) {
            count += 1
            let geometry: [String: Any] = s.rings.count == 1
                ? ["type": "Polygon", "coordinates": [s.rings[0]]]
                : ["type": "MultiPolygon", "coordinates": s.rings.map { [$0] }]
            features.append(["type": "Feature", "geometry": geometry, "properties": ["id": s.id, "kind": "area"]])
            if let p = s.labelPoint {
                let label = s.levels.isEmpty ? s.hazard : "\(s.hazard)\n\(s.levels)"
                features.append(["type": "Feature", "geometry": ["type": "Point", "coordinates": p],
                                 "properties": ["id": s.id, "kind": "label", "label": label]])
            }
        }
        let data = try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
        return (data, count)
    }

    // MARK: Taps

    /// The airport card for a tapped indicator, filled from the bundled airport list where the station is in it.
    @MainActor
    static func airportPick(icao: String, coordinate: CLLocationCoordinate2D, ofp: Ofp?, store: WeatherStore) -> MapPick {
        var attrs = ["icao": icao]
        if let info = WeatherAirports.all[icao] {
            attrs["name"] = info.name
            attrs["city"] = info.city
            attrs["iata"] = info.iata
            if let elev = info.elevFt { attrs["elev"] = "\(elev)" }
        } else if let m = store.metars[icao]?.elevationM {
            attrs["elev"] = "\(Int((m * 3.28084).rounded()))"
        }
        if let ofp {
            if ofp.origin.icao == icao { attrs["role"] = "origin" }
            else if ofp.destination.icao == icao { attrs["role"] = "destination" }
            else if ofp.alternates.contains(where: { $0.icao == icao }) { attrs["role"] = "alternate" }
        }
        return MapPick(kind: .airport, id: icao, coordinate: coordinate, attributes: attrs)
    }
}

/// Names and importance of the bundled airports (Basemap/airports.geojson), for weather stations.
enum WeatherAirports {
    struct Info {
        /// 1 = major, 2 = minor (as on the airport layer).
        let rank: Int
        let name: String
        let city: String
        let iata: String
        let elevFt: Int?
    }

    static let all: [String: Info] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Basemap/airports.geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return [:] }
        var out: [String: Info] = [:]
        for f in features {
            guard let p = f["properties"] as? [String: Any], let icao = p["icao"] as? String else { continue }
            out[icao] = Info(rank: p["rank"] as? Int ?? 2, name: p["name"] as? String ?? "", city: p["city"] as? String ?? "",
                             iata: p["iata"] as? String ?? "", elevFt: (p["elev"] as? NSNumber)?.intValue)
        }
        return out
    }()
}

extension MapIcons {
    /// Lido-style weather indicator: a small rounded pill in the category colour. With a worse TEMPO/PROB forecast
    /// the right half shows that category.
    static func metarIndicator(_ prevailing: WxCategory, temporary: WxCategory? = nil) -> UIImage {
        let size = CGSize(width: 18, height: 11)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
            let pill = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
            ctx.cgContext.saveGState()
            pill.addClip()
            UIColor(hex: prevailing.hex).setFill()
            UIRectFill(rect)
            if let temporary {
                UIColor(hex: temporary.hex).setFill()
                UIRectFill(CGRect(x: rect.midX, y: 0, width: size.width / 2, height: size.height))
                UIColor(hex: 0x10161F, alpha: 0.7).setFill()
                UIRectFill(CGRect(x: rect.midX - 0.5, y: 0, width: 1, height: size.height))
            }
            ctx.cgContext.restoreGState()
            UIColor(hex: 0x10161F, alpha: 0.9).setStroke()
            pill.lineWidth = 1.5
            pill.stroke()
        }
    }
}
