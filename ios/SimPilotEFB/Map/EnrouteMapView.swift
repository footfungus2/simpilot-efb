import MapLibre
import SwiftUI

/// MapLibre-backed enroute map: offline basemap, route, flight airports, ownship and weather layers.
struct EnrouteMapView: UIViewRepresentable {
    var night: Bool
    var ofp: Ofp?
    var ownship: Ownship?
    @Binding var follow: Bool
    var mapFilters: MapFilters
    var wxVisible: Bool
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

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: try? MapStyle.write(theme: Theme(night: night)))
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
        c.parent = self
        if c.night != night {
            c.night = night
            c.styleLoaded = false
            map.styleURL = try? MapStyle.write(theme: Theme(night: night))
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
        private var lastRecenterToken = -1
        private var lastFollowCenter: CLLocationCoordinate2D?
        private var wxTask: Task<Void, Never>?
        private var ammFeatures: [String: [[String: Any]]] = [:]
        private var ammLoading = Set<String>()
        private var ammFailedAt: [String: Date] = [:]
        private var lastOnGround: Bool?
        private var lastVatsimVersion = -1
        private var lastFocusToken = 0
        private var shownOverlayID: UUID?
        private var shownTaxiRoute: String?
        private var shownFrequencies: Bool?
        private var shownActiveRefs: [String]?
        private var overlayNight: Bool?
        private var sigmetsLoadedAt: Date?

        init(parent: EnrouteMapView) {
            self.parent = parent
        }

        // MARK: Delegate

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
            updateAMMSource()
            lastVatsimVersion = -1
            shownOverlayID = nil
            styleLoaded = true
            shownRouteStamp = nil
            sigmetsLoadedAt = nil
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
            if parent.vatsimVisible {
                for layer in MapStyle.vatsimTappable {
                    let hits = map.visibleFeatures(in: rect, styleLayerIdentifiers: [layer])
                    guard let f = hits.first, let kind = f.attribute(forKey: "kind") as? String,
                          let key = f.attribute(forKey: "key") as? String else { continue }
                    parent.onMapTap(nil)
                    switch kind {
                    case "pilot": parent.onVatsimTap(.pilot(key))
                    case "airport", "airport-idle": parent.onVatsimTap(.airport(key))
                    default: parent.onVatsimTap(.controller(key))
                    }
                    return
                }
            }
            // Waypoints, navaids and airports open the details card.
            for layer in MapStyle.pickable {
                guard let f = map.visibleFeatures(in: rect, styleLayerIdentifiers: [layer]).first else { continue }
                var attrs: [String: String] = [:]
                for (k, v) in f.attributes { attrs[k] = "\(v)" }
                let kind: MapPick.Kind = layer == "route-points" ? .fix : layer.hasPrefix("navaid") ? .navaid : .airport
                let id = attrs["idx"] ?? attrs["id"] ?? attrs["icao"] ?? attrs["ident"] ?? "?"
                parent.onVatsimTap(nil)
                parent.onMapTap(MapPick(kind: kind, id: id, coordinate: f.coordinate, attributes: attrs))
                return
            }
            parent.onVatsimTap(nil)
            parent.onMapTap(nil)
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            if reason.contains(.gesturePan), parent.follow {
                DispatchQueue.main.async { self.parent.follow = false }
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            scheduleWeatherRefresh()
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
                if parent.ownship == nil { fitRoute(map) }
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

            for (id, on) in MapStyle.layers(for: parent.mapFilters) { style.layer(withIdentifier: id)?.isVisible = on }
            if parent.mapFilters.navaidFrequencies != shownFrequencies {
                shownFrequencies = parent.mapFilters.navaidFrequencies
                let text: [Any] = parent.mapFilters.navaidFrequencies
                    ? ["concat", ["get", "id"] as [Any], "\n", ["get", "freq"] as [Any]]
                    : ["get", "id"]
                for id in ["navaid-vor", "navaid-dme", "navaid-ndb"] {
                    (style.layer(withIdentifier: id) as? MLNSymbolStyleLayer)?.text = NSExpression(mglJSONObject: text)
                }
            }
            for id in MapStyle.wxLayers { style.layer(withIdentifier: id)?.isVisible = parent.wxVisible }
            for id in MapStyle.vatsimLayers { style.layer(withIdentifier: id)?.isVisible = parent.vatsimVisible }
            // With VATSIM on, the online sectors carry the boundaries; dim the base FIR lines so borders don't double up.
            (style.layer(withIdentifier: "fir-lines") as? MLNLineStyleLayer)?.lineOpacity = NSExpression(forConstantValue: parent.vatsimVisible ? 0.3 : 1)
            updateChartOverlay(map: map, style: style)
            updateTaxiRoute(style: style)
            updateActiveRunways(style: style)

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
            if parent.wxVisible { scheduleWeatherRefresh(immediate: sigmetsLoadedAt == nil) }

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
            if overlay?.id != shownOverlayID || (overlay != nil && overlayNight != night) {
                if let layer = style.layer(withIdentifier: "chart-overlay") { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: "chart-overlay") { style.removeSource(source) }
                shownOverlayID = overlay?.id
                overlayNight = night
                guard let overlay else { return }
                let quad = MLNCoordinateQuad(topLeft: overlay.topLeft, bottomLeft: overlay.bottomLeft,
                                             bottomRight: overlay.bottomRight, topRight: overlay.topRight)
                let image = night ? NightChart.render(overlay.image) : overlay.image
                let source = MLNImageSource(identifier: "chart-overlay", coordinateQuad: quad, image: image)
                style.addSource(source)
                let layer = MLNRasterStyleLayer(identifier: "chart-overlay", source: source)
                if let below = style.layer(withIdentifier: "route-line") {
                    style.insertLayer(layer, below: below)
                } else {
                    style.addLayer(layer)
                }
                // Fly to the chart.
                let lats = [overlay.topLeft, overlay.topRight, overlay.bottomRight, overlay.bottomLeft].map(\.latitude)
                let lons = [overlay.topLeft, overlay.topRight, overlay.bottomRight, overlay.bottomLeft].map(\.longitude)
                let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
                                                 ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
                map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 100),
                                               animated: true, completionHandler: nil)
            }
            (style.layer(withIdentifier: "chart-overlay") as? MLNRasterStyleLayer)?.rasterOpacity =
                NSExpression(forConstantValue: parent.chartOverlayOpacity)
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

        private func scheduleWeatherRefresh(immediate: Bool = false) {
            guard parent.wxVisible, styleLoaded else { return }
            wxTask?.cancel()
            wxTask = Task { [weak self] in
                if !immediate { try? await Task.sleep(nanoseconds: 800_000_000) }
                guard !Task.isCancelled else { return }
                await self?.refreshWeather()
            }
        }

        private func refreshWeather() async {
            guard let map, let style = map.style else { return }

            if sigmetsLoadedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                if let data = try? await WeatherService.sigmetsGeoJSON(),
                   let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue) {
                    (style.source(withIdentifier: MapStyle.sigmetSource) as? MLNShapeSource)?.shape = shape
                    sigmetsLoadedAt = Date()
                }
            }

            // METAR indicators only when zoomed in enough for the request to stay small.
            let b = map.visibleCoordinateBounds
            let span = b.ne.longitude - b.sw.longitude
            guard span > 0, span < 40 else {
                (style.source(withIdentifier: MapStyle.metarSource) as? MLNShapeSource)?.shape = nil
                return
            }
            guard let stations = try? await WeatherService.metars(minLat: b.sw.latitude, minLon: b.sw.longitude,
                                                                  maxLat: b.ne.latitude, maxLon: b.ne.longitude) else { return }
            let features: [MLNPointFeature] = stations.map { s in
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
                f.attributes = ["icao": s.icao, "category": s.category]
                return f
            }
            (style.source(withIdentifier: MapStyle.metarSource) as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: features)
        }
    }
}
