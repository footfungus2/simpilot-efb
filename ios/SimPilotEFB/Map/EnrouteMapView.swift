import MapLibre
import SwiftUI

/// MapLibre-backed enroute map: offline basemap, route, flight airports, ownship and weather layers.
struct EnrouteMapView: UIViewRepresentable {
    var night: Bool
    var ofp: Ofp?
    var ownship: Ownship?
    @Binding var follow: Bool
    var mapFilters: MapFilters
    var customization: CustomizationValues
    var enrouteHigh: Bool
    var rulerActive: Bool
    var ruler: MapRuler
    var onRulerTap: (MapRuler.Point) -> Void
    var companyVisible: Bool
    /// WX layer: data comes from the store; the WX popover's toggles show or hide the indicator and SIGMET layers.
    let weather: WeatherStore
    var wxMetars: Bool
    var wxSigmets: Bool
    /// The store's data versions; a change pushes its new GeoJSON to the map.
    var wxIndicatorVersion = 0
    var wxSigmetVersion = 0
    /// Bump to re-centre on the ownship (if following) or fit the route.
    var recenterToken: Int
    let bridge: BridgeClient
    var vatsimVisible = false
    var vatsimVersion = 0
    var vatsimData: Data?
    var vatsimFocus: CLLocationCoordinate2D?
    var vatsimFocusToken = 0
    var onVatsimTap: (VatsimSelection?) -> Void = { _ in }
    var chartOverlay: ChartOverlay?
    var chartOverlayOpacity = 0.85
    var onAirportData: (String, [[String: Any]]) -> Void = { _, _ in }
    var taxiRoute: [String] = []
    var taxiRouteAirport: String?
    var activeRunwayRefs: [String] = []
    var onMapTap: (MapPick?) -> Void = { _ in }
    /// A tapped SIGMET (its id), nil when something else was tapped.
    var onSigmetTap: (String?) -> Void = { _ in }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: try? MapStyle.write(theme: Theme(night: night, accent: customization.accent), customization: customization))
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        map.allowsTilting = false
        map.minimumZoomLevel = 0.5 // far enough out to see the whole globe
        map.maximumZoomLevel = 18 // close enough on the airport moving map to read stands and holding points
        map.showsScale = true
        map.scaleBarPosition = .bottomLeft
        map.scaleBarMargins = CGPoint(x: 16, y: 16)
        map.compassViewPosition = .bottomLeft
        map.compassViewMargins = CGPoint(x: 16, y: 52)
        map.setCenter(CLLocationCoordinate2D(latitude: 50, longitude: 10), zoomLevel: 3.5, animated: false)
        context.coordinator.map = map
        context.coordinator.night = night

        // Taps select VATSIM traffic/ATC; wait for the map's own double-tap-to-zoom to fail first.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        for g in map.gestureRecognizers ?? [] {
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { tap.require(toFail: t) }
        }
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        let previous = c.parent.customization
        c.parent = self
        if c.night != night || previous.globeView != customization.globeView || previous.mapTextSize != customization.mapTextSize
            || previous.routeColor != customization.routeColor || previous.showGraticule != customization.showGraticule || previous.accent != customization.accent {
            c.night = night
            c.styleLoaded = false
            map.styleURL = try? MapStyle.write(theme: Theme(night: night, accent: customization.accent), customization: customization)
            return // apply() runs again once the new style has loaded
        }
        c.apply()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var parent: EnrouteMapView
        weak var map: MLNMapView?
        var night = true
        var styleLoaded = false

        private var shownRouteStamp: Double?
        private var fittedRouteStamp: Double?
        private var lastRecenterToken = -1
        private var lastFollowCenter: CLLocationCoordinate2D?
        private var ammFeatures: [String: [[String: Any]]] = [:]
        private var ammLoading = Set<String>()
        private var ammFailedAt: [String: Date] = [:]
        private var lastOnGround: Bool?
        private var lastVatsimVersion = -1
        private var lastFocusToken = 0
        private var shownOverlayID: UUID?
        private var focusedOverlayID: UUID?
        private var shownRuler: MapRuler?
        private var shownRulerStart: MapRuler.Point?
        private var shownTaxiRoute: String?
        private var shownFrequencies: Bool?
        private var shownActiveRefs: [String]?
        private var overlayNight: Bool?
        private var shownIndicatorVersion = -1
        private var shownSigmetVersion = -1
        /// The highlighted SIGMET on the current style (outer nil: not applied yet).
        private var shownSelectedSigmet: String??

        init(parent: EnrouteMapView) {
            self.parent = parent
        }

        // MARK: Delegate

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DiagnosticLog.record(.error, "Map", "Map could not be loaded.", error: error)
        }

        // MapLibre calls its delegate on the main thread.
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            style.setImage(MapIcons.ownship(), forName: "ownship")
            style.setImage(MapIcons.waypointTriangle(night: night), forName: "wpt-triangle")
            style.setImage(MapIcons.airport(color: UIColor(hex: 0x3FB860)), forName: "apt-origin")
            style.setImage(MapIcons.airport(color: UIColor(hex: 0xF0962E)), forName: "apt-destination")
            style.setImage(MapIcons.airport(color: UIColor(hex: 0xC85C9A)), forName: "apt-alternate")
            style.setImage(MapIcons.airport(color: UIColor(hex: 0x3D8BFF)), forName: "apt-blue")
            style.setImage(MapIcons.holdBar(), forName: "amm-hold")
            style.setImage(MapIcons.stand(), forName: "amm-stand")
            style.setImage(MapIcons.runwayBadge(), forName: "amm-rwy")
            style.setImage(MapIcons.vor(), forName: "nav-vor")
            style.setImage(MapIcons.dme(), forName: "nav-dme")
            style.setImage(MapIcons.ndb(), forName: "nav-ndb")
            shownFrequencies = nil
            style.setImage(MapIcons.runwayBadge(color: UIColor(hex: 0x2FA84F)), forName: "amm-rwy-green")
            shownTaxiRoute = nil
            shownActiveRefs = nil
            style.setImage(MapIcons.windsock(), forName: "amm-windsock")
            style.setImage(MapIcons.vatsimPlane(), forName: "vatsim-plane")
            style.setImage(MapIcons.vatsimPlane(color: UIColor(hex: 0xFF9F1C)), forName: "vatsim-plane-hl")
            style.setImage(MapIcons.labelBox(border: UIColor(hex: 0x4A4A4A)), forName: "label-box")
            style.setImage(MapIcons.labelBox(border: UIColor(hex: 0xFF5B45), fill: UIColor(hex: 0x1A1A1A)), forName: "label-box-red")
            WeatherMapLayer.addImages(to: style)
            shownIndicatorVersion = -1
            shownSigmetVersion = -1
            shownSelectedSigmet = nil
            updateAMMSource()
            lastVatsimVersion = -1
            shownOverlayID = nil
            shownRuler = nil
            styleLoaded = true
            DiagnosticLog.record(.info, "Map", "Map loaded.")
            shownRouteStamp = nil
            apply()
        }

        /// VATSIM images are made on demand: "atc-DGT" badges, "atcbar-GT" bars, "cnt-8-2-1" traffic counts.
        func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
            if imageName.hasPrefix("atcbar-") { return MapIcons.atcBar(String(imageName.dropFirst(7))) }
            if imageName.hasPrefix("atc-") { return MapIcons.atcBadge(String(imageName.dropFirst(4))) }
            if imageName.hasPrefix("cnt-") {
                let n = imageName.dropFirst(4).split(separator: "-").compactMap { Int($0) }
                if n.count == 3 { return MapIcons.trafficCounts(departing: n[0], landed: n[1], arriving: n[2]) }
            }
            return nil
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let map else { return }
            let p = g.location(in: map)
            let rect = CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)
            if parent.rulerActive {
                let snap = CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44)
                let f = firstFeature(in: snap, layers: MapStyle.pickable)
                let coordinate = f?.coordinate ?? map.convert(p, toCoordinateFrom: map)
                let label = f.flatMap { feature in
                    ["ident", "icao", "id"].compactMap { feature.attribute(forKey: $0) as? String }.first
                } ?? String(format: "%.2f, %.2f", coordinate.latitude, coordinate.longitude)
                select()
                parent.onRulerTap(MapRuler.Point(coordinate: coordinate, label: label))
                return
            }
            // Symbols first (traffic, ATC badges, fixes, navaids, airports, weather indicators), then areas.
            if parent.vatsimVisible || parent.companyVisible,
               let hit = vatsimHit(in: rect, layers: parent.vatsimVisible ? MapStyle.vatsimTappable.filter { !Self.vatsimAreas.contains($0) } : ["vatsim-pilots", "vatsim-company-labels"]) {
                select(vatsim: hit)
                return
            }
            // A weather indicator right under the finger wins over a fix or navaid next to it.
            if parent.wxMetars, let pick = metarPick(in: rect.insetBy(dx: 10, dy: 10)) {
                select(pick: pick)
                return
            }
            // Waypoints, navaids and airports open the details card.
            for layer in MapStyle.pickable {
                guard let f = map.visibleFeatures(in: rect, styleLayerIdentifiers: [layer]).first else { continue }
                var attrs: [String: String] = [:]
                for (k, v) in f.attributes { attrs[k] = "\(v)" }
                let kind: MapPick.Kind = layer == "route-points" ? .fix : layer.hasPrefix("navaid") ? .navaid : .airport
                let id = attrs["idx"] ?? attrs["id"] ?? attrs["icao"] ?? attrs["ident"] ?? "?"
                select(pick: MapPick(kind: kind, id: id, coordinate: f.coordinate, attributes: attrs))
                return
            }
            // A METAR/TAF indicator opens its airport's card (METAR + TAF).
            if parent.wxMetars, let pick = metarPick(in: rect) {
                select(pick: pick)
                return
            }
            if parent.wxSigmets,
               let f = firstFeature(in: rect, layers: WeatherMapLayer.sigmetLabelTappable)
                ?? map.visibleFeatures(at: p, styleLayerIdentifiers: Set(WeatherMapLayer.sigmetAreaTappable)).first,
               let id = f.attribute(forKey: "id") as? String {
                select(sigmet: id)
                return
            }
            if parent.vatsimVisible, let hit = vatsimHit(in: rect, layers: Self.vatsimAreas) {
                select(vatsim: hit)
                return
            }
            select()
        }

        /// VATSIM layers that cover areas; they only win a tap when no symbol is under it.
        private static let vatsimAreas = ["vatsim-approach-line", "vatsim-vg-fill", "vatsim-sector-fill"]

        private func vatsimHit(in rect: CGRect, layers: [String]) -> VatsimSelection? {
            guard let map else { return nil }
            for layer in layers {
                guard let f = map.visibleFeatures(in: rect, styleLayerIdentifiers: [layer]).first,
                      let kind = f.attribute(forKey: "kind") as? String, let key = f.attribute(forKey: "key") as? String else { continue }
                switch kind {
                case "pilot": return .pilot(key)
                case "airport", "airport-idle": return .airport(key)
                default: return .controller(key)
                }
            }
            return nil
        }

        private func metarPick(in rect: CGRect) -> MapPick? {
            guard let f = firstFeature(in: rect, layers: WeatherMapLayer.metarTappable),
                  let icao = f.attribute(forKey: "icao") as? String else { return nil }
            return WeatherMapLayer.airportPick(icao: icao, coordinate: f.coordinate, ofp: parent.ofp, store: parent.weather)
        }

        private func firstFeature(in rect: CGRect, layers: [String]) -> MLNFeature? {
            guard let map else { return nil }
            for layer in layers {
                if let f = map.visibleFeatures(in: rect, styleLayerIdentifiers: [layer]).first { return f }
            }
            return nil
        }

        /// Opens one card (VATSIM, waypoint/airport or SIGMET) and closes the others.
        private func select(vatsim: VatsimSelection? = nil, pick: MapPick? = nil, sigmet: String? = nil) {
            parent.onVatsimTap(vatsim)
            parent.onMapTap(pick)
            parent.onSigmetTap(sigmet)
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            if reason.contains(.gesturePan), parent.follow {
                DispatchQueue.main.async { self.parent.follow = false }
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            parent.weather.refreshIfStale()
            // Zoomed in on an airport: fetch its moving map.
            if mapView.zoomLevel >= MapStyle.ammZoom - 1, let icao = AirportIndex.nearest(to: mapView.centerCoordinate, withinKm: 8) {
                loadAMM(icao)
            }
        }

        // MARK: Updates

        func apply() {
            guard styleLoaded, let map, let style = map.style else { return }

            if shownRouteStamp != parent.ofp?.fetchedAt {
                shownRouteStamp = parent.ofp?.fetchedAt
                setRoute(style: style)
                if parent.ownship == nil, fittedRouteStamp != parent.ofp?.fetchedAt {
                    fittedRouteStamp = parent.ofp?.fetchedAt
                    fitRoute(map)
                }
                parent.ofp.map { [$0.origin, $0.destination] + $0.alternates }?.forEach { loadAMM($0.icao) }
            }

            // Like mPilot: on the ground the map switches to the airport moving map, in the air back to enroute.
            if parent.follow, let o = parent.ownship, o.onGround != lastOnGround {
                let wasKnown = lastOnGround != nil
                lastOnGround = o.onGround
                if o.onGround {
                    if let icao = AirportIndex.nearest(to: o.coordinate, withinKm: 8) { loadAMM(icao) }
                    map.setCenter(o.coordinate, zoomLevel: 15, animated: wasKnown)
                } else if wasKnown {
                    map.setCenter(o.coordinate, zoomLevel: 7, animated: true)
                }
                lastFollowCenter = o.coordinate
            }

            setOwnship(style: style)

            for (id, on) in MapStyle.layers(for: parent.mapFilters, high: parent.enrouteHigh) { style.layer(withIdentifier: id)?.isVisible = on }
            if parent.mapFilters.navaidFrequencies != shownFrequencies {
                shownFrequencies = parent.mapFilters.navaidFrequencies
                let text: [Any] = parent.mapFilters.navaidFrequencies
                    ? ["concat", ["get", "id"] as [Any], "\n", ["get", "freq"] as [Any]]
                    : ["get", "id"]
                for id in ["navaid-vor", "navaid-dme", "navaid-ndb"] {
                    (style.layer(withIdentifier: id) as? MLNSymbolStyleLayer)?.text = NSExpression(mglJSONObject: text)
                }
            }
            updateWeather(style: style)
            for id in MapStyle.vatsimLayers {
                let companyLayer = ["vatsim-pilots", "vatsim-company-labels"].contains(id)
                style.layer(withIdentifier: id)?.isVisible = parent.vatsimVisible || (parent.companyVisible && companyLayer)
            }
            (style.layer(withIdentifier: "vatsim-pilots") as? MLNSymbolStyleLayer)?.predicate = NSPredicate(mglJSONObject:
                parent.vatsimVisible ? ["==", ["get", "kind"], "pilot"] : ["all", ["==", ["get", "kind"], "pilot"], ["get", "company"]])
            // With VATSIM on, the online sectors carry the boundaries; dim the base FIR lines so borders don't double up.
            (style.layer(withIdentifier: "fir-lines") as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: parent.vatsimVisible ? 0.3 : 1)
            updateChartOverlay(map: map, style: style)
            updateTaxiRoute(style: style)
            updateActiveRunways(style: style)
            updateRuler(style: style)

            if parent.vatsimFocusToken != lastFocusToken {
                lastFocusToken = parent.vatsimFocusToken
                if let target = parent.vatsimFocus {
                    if parent.follow { DispatchQueue.main.async { self.parent.follow = false } }
                    map.setCenter(target, zoomLevel: max(map.zoomLevel, 8), animated: true)
                }
            }
            if parent.vatsimVersion != lastVatsimVersion, let source = style.source(withIdentifier: MapStyle.vatsimSource) as? MLNShapeSource {
                lastVatsimVersion = parent.vatsimVersion
                source.shape = parent.vatsimData.flatMap { try? MLNShape(data: $0, encoding: String.Encoding.utf8.rawValue) }
            }

            if parent.recenterToken != lastRecenterToken {
                lastRecenterToken = parent.recenterToken
                if parent.follow, let o = parent.ownship {
                    map.setCenter(o.coordinate, zoomLevel: max(map.zoomLevel, 6), animated: true)
                } else if lastRecenterToken > 0 {
                    fitRoute(map)
                }
            } else if parent.follow, let o = parent.ownship {
                // Only move when the aircraft has moved noticeably, so pinch-zooming stays smooth.
                if let last = lastFollowCenter, abs(last.latitude - o.lat) + abs(last.longitude - o.lon) < 0.0005 { return }
                lastFollowCenter = o.coordinate
                map.setCenter(o.coordinate, animated: false)
            }
        }

        private func setRoute(style: MLNStyle) {
            guard let ofp = parent.ofp else {
                (style.source(withIdentifier: MapStyle.routeSource) as? MLNShapeSource)?.shape = nil
                (style.source(withIdentifier: MapStyle.routePointsSource) as? MLNShapeSource)?.shape = nil
                (style.source(withIdentifier: MapStyle.airportsSource) as? MLNShapeSource)?.shape = nil
                return
            }
            var coords = [ofp.origin.coordinate] + ofp.navlog.map(\.coordinate)
            if coords.last.map({ abs($0.latitude - ofp.destination.lat) > 1e-6 }) ?? true { coords.append(ofp.destination.coordinate) }
            let line = MLNPolylineFeature(coordinates: coords, count: UInt(coords.count))
            (style.source(withIdentifier: MapStyle.routeSource) as? MLNShapeSource)?.shape = line

            let points: [MLNPointFeature] = ofp.navlog.enumerated()
                .filter { $0.element.type != "apt" && $0.element.ident != "TOC" && $0.element.ident != "TOD" }
                .map { idx, fix in
                    let f = MLNPointFeature()
                    f.coordinate = fix.coordinate
                    f.attributes = ["ident": fix.ident, "idx": idx]
                    return f
                }
            (style.source(withIdentifier: MapStyle.routePointsSource) as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: points)

            var airports: [MLNPointFeature] = []
            func add(_ a: OfpAirport, _ role: String) {
                let f = MLNPointFeature()
                f.coordinate = a.coordinate
                f.attributes = ["icao": a.icao, "role": role]
                airports.append(f)
            }
            add(ofp.origin, "origin")
            add(ofp.destination, "destination")
            ofp.alternates.forEach { add($0, "alternate") }
            (style.source(withIdentifier: MapStyle.airportsSource) as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: airports)
        }

        private func setOwnship(style: MLNStyle) {
            let source = style.source(withIdentifier: MapStyle.ownshipSource) as? MLNShapeSource
            guard let o = parent.ownship else {
                source?.shape = nil
                return
            }
            let f = MLNPointFeature()
            f.coordinate = o.coordinate
            f.attributes = ["trk": o.trkDeg]
            source?.shape = f
        }

        private func fitRoute(_ map: MLNMapView) {
            guard let ofp = parent.ofp else { return }
            let coords = [ofp.origin.coordinate, ofp.destination.coordinate] + ofp.navlog.map(\.coordinate) + ofp.alternates.map(\.coordinate)
            guard var ne = coords.first, var sw = coords.first else { return }
            for c in coords {
                ne.latitude = max(ne.latitude, c.latitude); ne.longitude = max(ne.longitude, c.longitude)
                sw.latitude = min(sw.latitude, c.latitude); sw.longitude = min(sw.longitude, c.longitude)
            }
            map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne),
                                           edgePadding: UIEdgeInsets(top: 80, left: 60, bottom: 80, right: 120),
                                           animated: true, completionHandler: nil)
        }

        // MARK: Taxi route and runway awareness

        private func updateTaxiRoute(style: MLNStyle) {
            let key = "\(parent.taxiRouteAirport ?? "")|\(parent.taxiRoute.joined(separator: " "))"
            guard key != shownTaxiRoute, let layer = style.layer(withIdentifier: "amm-taxi-route") as? MLNLineStyleLayer else { return }
            shownTaxiRoute = key
            if let icao = parent.taxiRouteAirport, !parent.taxiRoute.isEmpty {
                layer.predicate = NSPredicate(mglJSONObject: ["all", ["==", ["get", "kind"], "taxi-line"], ["==", ["get", "apt"], icao],
                                                              ["in", ["get", "ref"], ["literal", parent.taxiRoute]]])
            } else {
                layer.predicate = NSPredicate(mglJSONObject: ["==", ["get", "kind"], "none"])
            }
        }

        /// The runway you're on or approaching gets green end badges, like mPilot.
        private func updateActiveRunways(style: MLNStyle) {
            guard parent.activeRunwayRefs != shownActiveRefs,
                  let layer = style.layer(withIdentifier: "amm-runway-end") as? MLNSymbolStyleLayer else { return }
            shownActiveRefs = parent.activeRunwayRefs
            layer.iconImageName = NSExpression(mglJSONObject: ["case", ["in", ["get", "ref"], ["literal", parent.activeRunwayRefs]],
                                                               "amm-rwy-green", "amm-rwy"])
        }

        // MARK: Chart on map

        /// Pins the selected chart page onto the map at its georeferenced corners, under the route and aircraft.
        private func updateChartOverlay(map: MLNMapView, style: MLNStyle) {
            let overlay = parent.chartOverlay
            let dark = night && parent.customization.invertChartsAtNight
            if overlay?.id != shownOverlayID || (overlay != nil && overlayNight != dark) {
                if let layer = style.layer(withIdentifier: "chart-overlay") { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: "chart-overlay") { style.removeSource(source) }
                shownOverlayID = overlay?.id
                overlayNight = dark
                guard let overlay else { return }
                let quad = MLNCoordinateQuad(topLeft: overlay.topLeft, bottomLeft: overlay.bottomLeft,
                                             bottomRight: overlay.bottomRight, topRight: overlay.topRight)
                let image = dark ? NightChart.render(overlay.image) : overlay.image
                let source = MLNImageSource(identifier: "chart-overlay", coordinateQuad: quad, image: image)
                style.addSource(source)
                let layer = MLNRasterStyleLayer(identifier: "chart-overlay", source: source)
                if let below = style.layer(withIdentifier: "route-line") {
                    style.insertLayer(layer, below: below)
                } else {
                    style.addLayer(layer)
                }
                // A style/appearance change must not move the user's map.
                if focusedOverlayID != overlay.id {
                    focusedOverlayID = overlay.id
                    let lats = [overlay.topLeft, overlay.topRight, overlay.bottomRight, overlay.bottomLeft].map(\.latitude)
                    let lons = [overlay.topLeft, overlay.topRight, overlay.bottomRight, overlay.bottomLeft].map(\.longitude)
                    let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
                                                     ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
                    map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 100),
                                                   animated: true, completionHandler: nil)
                }
            }
            (style.layer(withIdentifier: "chart-overlay") as? MLNRasterStyleLayer)?.rasterOpacity =
                NSExpression(forConstantValue: parent.chartOverlayOpacity)
        }

        private func updateRuler(style: MLNStyle) {
            let ruler = parent.rulerActive ? parent.ruler : MapRuler()
            let a = ruler.start(parent.ownship)
            guard ruler != shownRuler || a != shownRulerStart else { return }
            shownRuler = ruler
            shownRulerStart = a
            var features: [[String: Any]] = []
            func point(_ p: MapRuler.Point, kind: String = "endpoint") -> [String: Any] {
                ["type": "Feature", "properties": ["kind": kind, "label": p.label],
                 "geometry": ["type": "Point", "coordinates": [p.coordinate.longitude, p.coordinate.latitude]]]
            }
            if let a {
                features.append(point(a))
                if let b = ruler.b {
                    features.append(point(b))
                    let segments = MapRuler.segments(a.coordinate, b.coordinate)
                    features.append(["type": "Feature", "properties": ["kind": "line"],
                                     "geometry": ["type": "MultiLineString", "coordinates": segments]])
                    let coords = segments.flatMap { $0 }, mid = coords[coords.count / 2]
                    let label = String(format: "%.1f NM · %03.0f° T", MapRuler.distanceNM(a.coordinate, b.coordinate), RunwayAwareness.bearing(a.coordinate, b.coordinate))
                    features.append(point(MapRuler.Point(coordinate: CLLocationCoordinate2D(latitude: mid[1], longitude: mid[0]), label: label), kind: "label"))
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features]) {
                (style.source(withIdentifier: "ruler") as? MLNShapeSource)?.shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
            }
        }

        // MARK: Airport moving map

        private func loadAMM(_ icao: String) {
            guard !icao.isEmpty, ammFeatures[icao] == nil, !ammLoading.contains(icao) else { return }
            // After a failure, wait a minute before asking the servers again (they rate-limit).
            if let failed = ammFailedAt[icao], Date().timeIntervalSince(failed) < 60 { return }
            ammLoading.insert(icao)
            Task { @MainActor [weak self] in
                let feats = try? await AirportMapService.features(icao: icao)
                guard let self else { return }
                self.ammLoading.remove(icao)
                guard let feats else {
                    self.ammFailedAt[icao] = Date() // offline or every server busy: retry later on a pan
                    return
                }
                self.ammFeatures[icao] = feats
                self.parent.onAirportData(icao, feats)
                self.updateAMMSource()
            }
        }

        private func updateAMMSource() {
            guard let style = map?.style, let source = style.source(withIdentifier: MapStyle.ammSource) as? MLNShapeSource else { return }
            let all = ammFeatures.values.flatMap { $0 }
            guard let data = try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": all]),
                  let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue) else { return }
            source.shape = shape
        }

        // MARK: Weather

        /// Shows the WX layers per the WX popover and pushes new indicator/SIGMET data from the store.
        /// Never starts or cancels a download: this runs on every SwiftUI update (ownship at 10 Hz).
        private func updateWeather(style: MLNStyle) {
            for id in WeatherMapLayer.metarLayers { setVisible(style, id, parent.wxMetars) }
            for id in WeatherMapLayer.sigmetLayers { setVisible(style, id, parent.wxSigmets) }
            let wx = parent.weather
            if parent.wxIndicatorVersion != shownIndicatorVersion,
               let source = style.source(withIdentifier: MapStyle.metarSource) as? MLNShapeSource {
                shownIndicatorVersion = parent.wxIndicatorVersion
                source.shape = wx.indicatorGeoJSON.flatMap { try? MLNShape(data: $0, encoding: String.Encoding.utf8.rawValue) }
            }
            if parent.wxSigmetVersion != shownSigmetVersion,
               let source = style.source(withIdentifier: MapStyle.sigmetSource) as? MLNShapeSource {
                shownSigmetVersion = parent.wxSigmetVersion
                source.shape = wx.sigmetGeoJSON.flatMap { try? MLNShape(data: $0, encoding: String.Encoding.utf8.rawValue) }
            }
            if wx.selectedSigmet != shownSelectedSigmet {
                shownSelectedSigmet = wx.selectedSigmet
                WeatherMapLayer.highlight(sigmet: wx.selectedSigmet, in: style)
            }
        }

        private func setVisible(_ style: MLNStyle, _ id: String, _ visible: Bool) {
            guard let layer = style.layer(withIdentifier: id), layer.isVisible != visible else { return }
            layer.isVisible = visible
        }
    }
}
