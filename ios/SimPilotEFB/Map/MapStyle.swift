import Foundation
import UIKit

/// Builds the Lido-like enroute style as a local style.json (offline basemap + glyphs from the app bundle).
enum MapStyle {
    static let routeSource = "route"
    static let routePointsSource = "route-points"
    static let airportsSource = "flight-airports"
    static let ownshipSource = "ownship"
    static let metarSource = "metars"
    static let sigmetSource = "sigmets"
    static let ammSource = "amm"
    static let vatsimSource = "vatsim"
    static let vatsimLayers = ["vatsim-sector-fill", "vatsim-sector-line", "vatsim-vg-fill", "vatsim-vg-line", "vatsim-approach-line", "vatsim-pilots", "vatsim-company-labels",
                               "vatsim-pilot-labels", "vatsim-airport-dot", "vatsim-airport-bar", "vatsim-airport-badge",
                               "vatsim-airport-counts", "vatsim-airport-idle-labels", "vatsim-airport-labels", "vatsim-sector-label",
                               "vatsim-approach-label"]
    /// Layers a tap can select, most specific first.
    static let vatsimTappable = ["vatsim-pilots", "vatsim-company-labels", "vatsim-airport-badge", "vatsim-airport-bar", "vatsim-airport-labels",
                                 "vatsim-airport-idle-labels", "vatsim-approach-label", "vatsim-sector-label", "vatsim-approach-line", "vatsim-vg-fill", "vatsim-sector-fill"]

    /// Zoom where the enroute map hands over to the airport moving map.
    static let ammZoom = 12.0

    /// Layers behind each NAV filter.
    static func layers(for filters: MapFilters, high: Bool) -> [(String, Bool)] {
        let groups: [([String], Bool)] = [
            (["route-line", "route-points", "route-labels", "airports", "airport-labels"], filters.route),
            (["all-airports-major"], filters.airports),
            (["all-airports-minor"], filters.airports && !high),
            (["fir-lines", "fir-labels"], filters.firs),
            (["navaid-vor"], filters.vor),
            (["navaid-ndb"], filters.ndb && !high),
            (["navaid-dme"], filters.dme),
        ]
        return groups.flatMap { ids, on in ids.map { ($0, on) } }
    }

    /// Layers a tap can pick for the waypoint details card, most specific first.
    static let pickable = ["route-points", "navaid-vor", "navaid-dme", "navaid-ndb", "airports", "all-airports-major", "all-airports-minor"]

    static func write(theme: Theme, customization: CustomizationValues) throws -> URL {
        let base = Bundle.main.resourceURL!.appendingPathComponent("Basemap")
        let file = { (name: String) in base.appendingPathComponent(name).absoluteString }
        let hex = { (c: UIColor) -> String in c.hexString }

        var style: [String: Any] = [
            "version": 8,
            "name": theme.night ? "SimPilot Night" : "SimPilot Day",
            // 3D globe when zoomed out; MapLibre flattens it to a normal map as you zoom in.
            "projection": ["type": customization.globeView ? "globe" : "mercator"],
            "glyphs": base.appendingPathComponent("Glyphs").absoluteString + "/{fontstack}/{range}.pbf",
            "sources": [
                "land": ["type": "geojson", "data": file("ne_50m_land.geojson")],
                "lakes": ["type": "geojson", "data": file("ne_50m_lakes.geojson")],
                ammSource: emptySource(),
                vatsimSource: emptySource(),
                "firs": ["type": "geojson", "data": file("firs.geojson")],
                "fir-labels": ["type": "geojson", "data": file("fir-labels.geojson")],
                "countries": ["type": "geojson", "data": file("country-labels.geojson")],
                "all-airports": ["type": "geojson", "data": file("airports.geojson")],
                "navaids": ["type": "geojson", "data": file("navaids.geojson")],
                "graticule": ["type": "geojson", "data": graticule()],
                routeSource: emptySource(),
                routePointsSource: emptySource(),
                airportsSource: emptySource(),
                ownshipSource: emptySource(),
                metarSource: emptySource(),
                sigmetSource: emptySource(),
                "ruler": emptySource(),
            ],
            "layers": [
                ["id": "background", "type": "background", "paint": ["background-color": hex(theme.mapBackground)]],
                ["id": "land", "type": "fill", "source": "land",
                 "paint": ["fill-color": ["interpolate", ["linear"], ["zoom"], ammZoom - 1, hex(theme.mapLand), ammZoom + 1, hex(theme.ammGround)],
                           "fill-antialias": true]],
                ["id": "lakes", "type": "fill", "source": "lakes", "paint": ["fill-color": hex(theme.mapLakes)]],
                ["id": "graticule", "maxzoom": ammZoom + 0.5, "type": "line", "source": "graticule", "paint": ["line-color": hex(theme.mapGraticule), "line-width": 0.8]],
                ["id": "country-labels", "maxzoom": ammZoom + 0.5, "type": "symbol", "source": "countries",
                 "layout": [
                    "text-field": ["get", "name"], "text-font": ["Noto Sans Italic"],
                    "text-size": ["interpolate", ["linear"], ["zoom"], 2, 10, 6, 15],
                    "text-letter-spacing": 0.08, "text-max-width": 8,
                 ],
                 "paint": ["text-color": hex(theme.countryLabel), "text-halo-color": hex(theme.mapLabelHalo), "text-halo-width": 0.8]],
                // FIR / UIR / oceanic boundaries in Lido green.
                ["id": "fir-lines", "maxzoom": ammZoom + 0.5, "type": "line", "source": "firs",
                 "layout": ["line-join": "round"],
                 "paint": ["line-color": hex(theme.firLine), "line-width": ["interpolate", ["linear"], ["zoom"], 2, 0.8, 7, 1.8]]],
                ["id": "fir-labels", "maxzoom": ammZoom + 0.5, "type": "symbol", "source": "fir-labels", "minzoom": 3.5,
                 "layout": ["text-field": ["get", "label"], "text-font": ["Noto Sans Italic"], "text-size": 11, "text-max-width": 12],
                 "paint": ["text-color": hex(theme.firLine), "text-halo-color": hex(theme.mapLabelHalo), "text-halo-width": 1]],
                // WX: METAR/TAF indicators below the airports, so airports and labels win the space (WeatherMapLayer).
                WeatherMapLayer.metarLayer(flight: false, theme: theme),
                // All airports as blue Lido gears; minor ones appear when zoomed in.
                ["id": "all-airports-major", "maxzoom": ammZoom + 0.5, "type": "symbol", "source": "all-airports", "minzoom": 3.5,
                 "filter": ["==", ["get", "rank"], 1],
                 "layout": [
                    "icon-image": "apt-blue", "icon-size": 0.8,
                    "text-field": ["get", "icao"], "text-font": ["Noto Sans Bold"], "text-size": 10,
                    "text-anchor": "top-left", "text-offset": [0.6, 0.3], "text-optional": true,
                 ],
                 "paint": ["text-color": "#3D8BFF", "text-halo-color": hex(theme.mapLabelHalo), "text-halo-width": 1.2]],
                ["id": "all-airports-minor", "maxzoom": ammZoom + 0.5, "type": "symbol", "source": "all-airports", "minzoom": 5.5,
                 "filter": ["==", ["get", "rank"], 2],
                 "layout": [
                    "icon-image": "apt-blue", "icon-size": 0.7,
                    "text-field": ["get", "icao"], "text-font": ["Noto Sans Bold"], "text-size": 10,
                    "text-anchor": "top-left", "text-offset": [0.6, 0.3], "text-optional": true,
                 ],
                 "paint": ["text-color": "#3D8BFF", "text-halo-color": hex(theme.mapLabelHalo), "text-halo-width": 1.2]],
                // Airport moving map (OpenStreetMap aeroways), shown from ammZoom.
                // Fills use an outline in their own colour so neighbouring polygons don't show hairline seams.
                ["id": "amm-apron", "type": "fill", "source": ammSource, "minzoom": ammZoom,
                 "filter": ["any", ["==", ["get", "kind"], "apron"], ["==", ["get", "kind"], "pavement"]],
                 "paint": ["fill-color": hex(theme.ammPavement), "fill-outline-color": hex(theme.ammPavement)]],
                // Taxiways and runways are thick lines exactly as wide as the real surface (w10/w20 = pixels at z10/z20).
                ["id": "amm-taxiway-surface", "type": "line", "source": ammSource, "minzoom": ammZoom,
                 "filter": ["==", ["get", "kind"], "taxiway-surface"],
                 "layout": ["line-join": "round", "line-cap": "round"],
                 "paint": ["line-color": hex(theme.ammPavement),
                           "line-width": ["interpolate", ["exponential", 2], ["zoom"], 10, ["get", "w10"], 20, ["get", "w20"]]]],
                ["id": "amm-runway", "type": "fill", "source": ammSource, "minzoom": ammZoom,
                 "filter": ["==", ["get", "kind"], "runway-area"],
                 "paint": ["fill-color": hex(theme.ammRunway), "fill-outline-color": hex(theme.ammRunway)]],
                ["id": "amm-runway-surface", "type": "line", "source": ammSource, "minzoom": ammZoom,
                 "filter": ["==", ["get", "kind"], "runway-surface"],
                 "layout": ["line-join": "miter", "line-cap": "butt"],
                 "paint": ["line-color": hex(theme.ammRunway),
                           "line-width": ["interpolate", ["exponential", 2], ["zoom"], 10, ["get", "w10"], 20, ["get", "w20"]]]],
                ["id": "amm-building", "type": "fill", "source": ammSource, "minzoom": ammZoom,
                 "filter": ["==", ["get", "kind"], "building"],
                 "paint": ["fill-color": hex(theme.ammBuilding), "fill-outline-color": hex(theme.ammBuilding)]],
                ["id": "amm-runway-centerline", "type": "line", "source": ammSource, "minzoom": ammZoom + 1,
                 "filter": ["==", ["get", "kind"], "runway-centerline"],
                 "paint": ["line-color": "#FFFFFF", "line-width": ["interpolate", ["linear"], ["zoom"], 13, 0.8, 17, 2.5],
                           "line-dasharray": [6, 5]]],
                ["id": "amm-stand-line", "type": "line", "source": ammSource, "minzoom": ammZoom + 2,
                 "filter": ["==", ["get", "kind"], "stand-line"],
                 "paint": ["line-color": hex(theme.ammTaxiLine), "line-opacity": 0.45, "line-width": 0.7]],
                ["id": "amm-taxi-line", "type": "line", "source": ammSource, "minzoom": ammZoom,
                 "filter": ["==", ["get", "kind"], "taxi-line"],
                 "layout": ["line-join": "round", "line-cap": "round"],
                 "paint": ["line-color": hex(theme.ammTaxiLine), "line-width": ["interpolate", ["linear"], ["zoom"], 12, 0.6, 16, 1.8, 18, 3]]],
                // ATC taxi route: filled in by the map coordinator (taxi-line features of the route, in magenta).
                ["id": "amm-taxi-route", "type": "line", "source": ammSource, "minzoom": ammZoom,
                 "filter": ["==", ["get", "kind"], "none"],
                 "layout": ["line-join": "round", "line-cap": "round"],
                 "paint": ["line-color": "#FF4FD8", "line-opacity": 0.9,
                           "line-width": ["interpolate", ["linear"], ["zoom"], 12, 3, 16, 7, 18, 12]]],
                ["id": "amm-hold", "type": "symbol", "source": ammSource, "minzoom": ammZoom + 1,
                 "filter": ["==", ["get", "kind"], "hold"],
                 "layout": ["icon-image": "amm-hold", "icon-rotate": ["get", "rot"], "icon-rotation-alignment": "map",
                            "icon-allow-overlap": true, "icon-size": ["interpolate", ["linear"], ["zoom"], 13, 0.5, 16, 1.1, 18, 1.8]]],
                ["id": "amm-taxi-label", "type": "symbol", "source": ammSource, "minzoom": ammZoom + 1,
                 "filter": ["all", ["==", ["get", "kind"], "taxi-line"], ["!=", ["get", "ref"], ""]],
                 "layout": ["symbol-placement": "line", "symbol-spacing": 250, "text-field": ["get", "ref"],
                            "text-font": ["Noto Sans Bold"], "text-size": 13, "text-keep-upright": true],
                 "paint": ["text-color": hex(theme.ammLabel), "text-halo-color": hex(theme.ammGround), "text-halo-width": 1.5]],
                ["id": "amm-stand", "type": "symbol", "source": ammSource, "minzoom": ammZoom + 2,
                 "filter": ["==", ["get", "kind"], "stand"],
                 "layout": ["icon-image": "amm-stand", "icon-rotate": ["get", "rot"], "icon-rotation-alignment": "map",
                            "icon-allow-overlap": true,
                            "icon-size": ["interpolate", ["linear"], ["zoom"], 14, 0.7, 16, 1, 18, 1.4],
                            "text-field": ["get", "ref"], "text-font": ["Noto Sans Bold"],
                            "text-size": ["interpolate", ["linear"], ["zoom"], 14, 9, 16, 12, 18, 15],
                            "text-offset": [0, 1.3], "text-optional": true],
                 "paint": ["text-color": hex(theme.ammLabel), "text-halo-color": hex(theme.ammGround), "text-halo-width": 1.2]],
                ["id": "amm-runway-end", "type": "symbol", "source": ammSource, "minzoom": ammZoom,
                 "filter": ["==", ["get", "kind"], "runway-end"],
                 "layout": ["icon-image": "amm-rwy", "icon-allow-overlap": true, "text-allow-overlap": true,
                            "text-field": ["get", "ref"], "text-font": ["Noto Sans Bold"], "text-size": 11],
                 "paint": ["text-color": "#FFFFFF"]],
                ["id": "amm-windsock", "type": "symbol", "source": ammSource, "minzoom": ammZoom + 2,
                 "filter": ["==", ["get", "kind"], "windsock"],
                 "layout": ["icon-image": "amm-windsock", "icon-allow-overlap": true]],
                // VATSIM (styled after VATSIM Radar): online sectors, approach areas, airports, pilots.
                ["id": "vatsim-sector-fill", "type": "fill", "source": vatsimSource,
                 "filter": ["any", ["==", ["get", "kind"], "sector"], ["==", ["get", "kind"], "sector-parent"]],
                 // Parents are lighter so a staffed sub-sector on top of them still reads as its own green area.
                 "paint": ["fill-color": "#4A7A2E",
                           "fill-opacity": ["case", ["==", ["get", "kind"], "sector"], 0.24, 0.12]]],
                ["id": "vatsim-sector-line", "type": "line", "source": vatsimSource,
                 "filter": ["any", ["==", ["get", "kind"], "sector"], ["==", ["get", "kind"], "sector-parent"]],
                 "paint": ["line-color": "#5E9E3C", "line-width": 1.2]],
                // VATGlasses: each controller's real area at the selected level, in its VATGlasses colour.
                // No antialiasing on the fill so adjoining blocks of one controller don't show seams.
                ["id": "vatsim-vg-fill", "type": "fill", "source": vatsimSource,
                 "filter": ["==", ["get", "kind"], "vg-area"],
                 "paint": ["fill-color": ["get", "color"], "fill-opacity": 0.22, "fill-antialias": false]],
                ["id": "vatsim-vg-line", "type": "line", "source": vatsimSource,
                 "filter": ["==", ["get", "kind"], "vg-line"],
                 "layout": ["line-join": "round"],
                 "paint": ["line-color": ["get", "color"], "line-width": 1.8]],
                ["id": "vatsim-approach-line", "type": "line", "source": vatsimSource,
                 "filter": ["==", ["get", "kind"], "approach"], "paint": ["line-color": "#FF5B45", "line-width": 2.4]],
                ["id": "vatsim-pilots", "type": "symbol", "source": vatsimSource,
                 "filter": ["==", ["get", "kind"], "pilot"],
                 "layout": ["icon-image": ["case", ["get", "hl"], "vatsim-plane-hl", "vatsim-plane"],
                            "icon-rotate": ["get", "hdg"], "icon-rotation-alignment": "map",
                            "icon-allow-overlap": true, "icon-ignore-placement": true,
                            // zoom must be the top-level input; the per-aircraft scale goes inside each stop.
                            "icon-size": ["interpolate", ["linear"], ["zoom"],
                                          3, ["*", 0.45, ["get", "size"]], 7, ["*", 0.75, ["get", "size"]], 12, ["*", 1.1, ["get", "size"]]]]],
                ["id": "vatsim-pilot-labels", "type": "symbol", "source": vatsimSource, "minzoom": 7,
                 "filter": ["all", ["==", ["get", "kind"], "pilot"], ["get", "showLabel"], ["!", ["get", "company"]]],
                 "layout": ["text-field": ["get", "label"], "text-font": ["Noto Sans Bold"], "text-size": 14,
                            "text-anchor": "top-left", "text-offset": [0.6, 0.6], "text-optional": true],
                 "paint": ["text-color": ["case", ["get", "hl"], "#FF9F1C", "#4A7BFF"],
                           "text-halo-color": "rgba(0,0,0,0.5)", "text-halo-width": 1]],
                ["id": "vatsim-company-labels", "type": "symbol", "source": vatsimSource,
                 "filter": ["all", ["==", ["get", "kind"], "pilot"], ["get", "company"]],
                 "layout": ["text-field": ["get", "label"], "text-font": ["Noto Sans Bold"], "text-size": 14,
                            "text-anchor": "top-left", "text-offset": [0.6, 0.6], "text-allow-overlap": true],
                 "paint": ["text-color": "#FF9F1C", "text-halo-color": "rgba(0,0,0,0.7)", "text-halo-width": 1]],
                ["id": "vatsim-airport-dot", "type": "circle", "source": vatsimSource, "minzoom": 6,
                 "filter": ["==", ["get", "kind"], "airport-idle"],
                 "paint": ["circle-radius": 2.5, "circle-color": "#8E8E8E"]],
                // Zoomed out: a thin bar of ATC colours under the ICAO; zoomed in: letter badges.
                ["id": "vatsim-airport-bar", "type": "symbol", "source": vatsimSource, "maxzoom": 6.5,
                 "filter": ["==", ["get", "kind"], "airport"],
                 "layout": ["icon-image": ["get", "bar"], "icon-anchor": "top", "icon-offset": [0, 3], "icon-allow-overlap": true]],
                ["id": "vatsim-airport-badge", "type": "symbol", "source": vatsimSource, "minzoom": 6.5,
                 "filter": ["==", ["get", "kind"], "airport"],
                 "layout": ["icon-image": ["get", "badge"], "icon-anchor": "top", "icon-offset": [0, 3], "icon-allow-overlap": true]],
                ["id": "vatsim-airport-counts", "type": "symbol", "source": vatsimSource, "minzoom": 6.5,
                 "filter": ["all", ["any", ["==", ["get", "kind"], "airport"], ["==", ["get", "kind"], "airport-idle"]],
                            ["!=", ["get", "counts"], ""]],
                 "layout": ["icon-image": ["get", "counts"], "icon-anchor": "left", "icon-offset": [26, -12], "icon-allow-overlap": true]],
                ["id": "vatsim-airport-idle-labels", "type": "symbol", "source": vatsimSource, "minzoom": 5,
                 "filter": ["==", ["get", "kind"], "airport-idle"],
                 "layout": ["text-field": ["get", "icao"], "text-font": ["Noto Sans Bold"],
                            "text-size": ["interpolate", ["linear"], ["zoom"], 4, 12, 8, 15],
                            "text-anchor": "bottom", "text-offset": [0, -0.05], "text-allow-overlap": true],
                 "paint": ["text-color": ["case", ["get", "hl"], "#FF9F1C", "#9A9A9A"],
                           "text-halo-color": "rgba(0,0,0,0.55)", "text-halo-width": 1]],
                ["id": "vatsim-airport-labels", "type": "symbol", "source": vatsimSource,
                 "filter": ["==", ["get", "kind"], "airport"],
                 "layout": ["text-field": ["get", "icao"], "text-font": ["Noto Sans Bold"],
                            "text-size": ["interpolate", ["linear"], ["zoom"], 4, 12, 8, 15],
                            "text-anchor": "bottom", "text-offset": [0, -0.05], "text-allow-overlap": true],
                 "paint": ["text-color": ["case", ["get", "hl"], "#FF9F1C", ["==", ["get", "kind"], "airport-idle"], "#9A9A9A", "#E6E6E6"],
                           "text-halo-color": "rgba(0,0,0,0.55)", "text-halo-width": 1]],
                ["id": "vatsim-sector-label", "type": "symbol", "source": vatsimSource,
                 "filter": ["==", ["get", "kind"], "sector-label"],
                 "layout": ["text-field": ["get", "label"], "text-font": ["Noto Sans Bold"], "text-size": 14,
                            "icon-image": "label-box", "icon-text-fit": "both", "icon-text-fit-padding": [4, 7, 4, 7]],
                 "paint": ["text-color": "#EDEDED"]],
                ["id": "vatsim-approach-label", "type": "symbol", "source": vatsimSource,
                 "filter": ["==", ["get", "kind"], "approach-label"],
                 "layout": ["text-field": ["get", "label"], "text-font": ["Noto Sans Bold"], "text-size": 14,
                            "text-anchor": "right", "text-offset": [-0.4, 0],
                            "icon-image": "label-box-red", "icon-text-fit": "both", "icon-text-fit-padding": [4, 7, 4, 7]],
                 "paint": ["text-color": "#FF5B45"]],
                // Navaids (OurAirports): VOR family, DME/TACAN, NDB. Labels: ident, plus frequency when enabled.
                navaidLayer("navaid-vor", kind: "vor", icon: "nav-vor", minzoom: 5.5, color: "#5AB0E8", theme: theme),
                navaidLayer("navaid-dme", kind: "dme", icon: "nav-dme", minzoom: 6.5, color: "#5AB0E8", theme: theme),
                navaidLayer("navaid-ndb", kind: "ndb", icon: "nav-ndb", minzoom: 7, color: "#C467C9", theme: theme),
                WeatherMapLayer.sigmetFillLayer(),
                WeatherMapLayer.sigmetLineLayer(),
                WeatherMapLayer.sigmetLabelLayer(theme: theme),
                ["id": "route-line", "type": "line", "source": routeSource,
                 "layout": ["line-join": "round", "line-cap": "round"],
                 "paint": ["line-color": customization.routeColor.cssHex, "line-width": 3]],
                ["id": "route-points", "maxzoom": ammZoom + 0.5, "type": "symbol", "source": routePointsSource,
                 "layout": ["icon-image": "wpt-triangle", "icon-allow-overlap": true, "icon-size": 1]],
                ["id": "route-labels", "maxzoom": ammZoom + 0.5, "type": "symbol", "source": routePointsSource,
                 "layout": [
                    "text-field": ["get", "ident"], "text-font": ["Noto Sans Bold"], "text-size": 12,
                    "text-anchor": "left", "text-offset": [0.8, 0], "text-optional": true,
                 ],
                 "paint": ["text-color": hex(theme.mapLabel), "text-halo-color": hex(theme.mapLabelHalo), "text-halo-width": 1.6]],
                // The flight's airports always show their indicator.
                WeatherMapLayer.metarLayer(flight: true, theme: theme),
                ["id": "airports", "maxzoom": ammZoom + 0.5, "type": "symbol", "source": airportsSource,
                 "layout": ["icon-image": ["concat", "apt-", ["get", "role"]], "icon-allow-overlap": true]],
                ["id": "airport-labels", "maxzoom": ammZoom + 0.5, "type": "symbol", "source": airportsSource,
                 "layout": [
                    "text-field": ["get", "icao"], "text-font": ["Noto Sans Bold"], "text-size": 12,
                    "text-anchor": "top-left", "text-offset": [0.7, 0.4], "text-allow-overlap": true,
                 ],
                 "paint": ["text-color": "#3D8BFF", "text-halo-color": hex(theme.mapLabelHalo), "text-halo-width": 1.5]],
                ["id": "ruler-line", "type": "line", "source": "ruler", "filter": ["==", ["get", "kind"], "line"],
                 "paint": ["line-color": hex(UIColor(hex: customization.accent.hex)), "line-width": 2.5, "line-dasharray": [3, 2]]],
                ["id": "ruler-points", "type": "circle", "source": "ruler", "filter": ["==", ["get", "kind"], "endpoint"],
                 "paint": ["circle-radius": 5, "circle-color": "#FFFFFF", "circle-stroke-color": customization.routeColor.cssHex, "circle-stroke-width": 2]],
                ["id": "ruler-labels", "type": "symbol", "source": "ruler",
                 "filter": ["!=", ["get", "kind"], "line"],
                 "layout": ["text-field": ["get", "label"], "text-font": ["Noto Sans Bold"], "text-size": 13,
                            "text-offset": [0, 1.2], "text-allow-overlap": true],
                 "paint": ["text-color": hex(theme.mapLabel), "text-halo-color": hex(theme.mapLabelHalo), "text-halo-width": 2]],
                ["id": "ownship-halo", "type": "circle", "source": ownshipSource,
                 "paint": ["circle-radius": 36, "circle-color": "#3D8BFF", "circle-opacity": 0.3, "circle-pitch-alignment": "map"]],
                ["id": "ownship", "type": "symbol", "source": ownshipSource,
                 "layout": [
                    "icon-image": "ownship", "icon-rotate": ["get", "trk"], "icon-rotation-alignment": "map",
                    "icon-allow-overlap": true, "icon-ignore-placement": true,
                 ]],
            ],
        ]

        var layers = style["layers"] as? [[String: Any]] ?? []
        for i in layers.indices {
            var layout = layers[i]["layout"] as? [String: Any] ?? [:]
            if let size = layout["text-size"] { layout["text-size"] = scaledTextSize(size, by: customization.mapTextSize.scale) }
            if layers[i]["id"] as? String == "graticule" { layout["visibility"] = customization.showGraticule ? "visible" : "none" }
            layers[i]["layout"] = layout
        }
        style["layers"] = layers
        let data = try JSONSerialization.data(withJSONObject: style)
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("style-\(theme.night)-\(customization.globeView)-\(customization.mapTextSize.rawValue)-\(customization.routeColor.rawValue)-\(customization.showGraticule)-\(customization.accent.rawValue).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Scale expression outputs, keeping a zoom expression at the top level as MapLibre requires.
    static func scaledTextSize(_ value: Any, by scale: Double) -> Any {
        if let number = value as? NSNumber { return number.doubleValue * scale }
        guard var expression = value as? [Any], let operation = expression.first as? String else { return value }
        if operation == "interpolate" {
            for i in stride(from: 4, to: expression.count, by: 2) { expression[i] = scaledTextSize(expression[i], by: scale) }
        } else if operation == "step", expression.count >= 3 {
            expression[2] = scaledTextSize(expression[2], by: scale)
            for i in stride(from: 4, to: expression.count, by: 2) { expression[i] = scaledTextSize(expression[i], by: scale) }
        } else {
            return ["*", value, scale] as [Any]
        }
        return expression
    }

    private static func navaidLayer(_ id: String, kind: String, icon: String, minzoom: Double, color: String, theme: Theme) -> [String: Any] {
        ["id": id, "type": "symbol", "source": "navaids", "minzoom": minzoom, "maxzoom": ammZoom + 0.5,
         "filter": ["==", ["get", "kind"], kind],
         "layout": ["icon-image": icon, "icon-allow-overlap": true, "icon-size": ["interpolate", ["linear"], ["zoom"], 5, 0.7, 9, 1],
                    "text-field": ["get", "id"], "text-font": ["Noto Sans Bold"], "text-size": 10,
                    "text-anchor": "top", "text-offset": [0, 0.9], "text-optional": true],
         "paint": ["text-color": color, "text-halo-color": hex(theme.mapLabelHalo), "text-halo-width": 1.2]]
    }

    private static func hex(_ c: UIColor) -> String { c.hexString }

    private static func emptySource() -> [String: Any] {
        ["type": "geojson", "data": ["type": "FeatureCollection", "features": [Any]()]]
    }

    /// 10° graticule like the faint grid on Lido enroute charts.
    private static func graticule() -> [String: Any] {
        var features: [[String: Any]] = []
        for lon in stride(from: -180, through: 180, by: 10) {
            features.append(line(stride(from: -80.0, through: 80, by: 2).map { [Double(lon), $0] }))
        }
        for lat in stride(from: -80, through: 80, by: 10) {
            features.append(line(stride(from: -180.0, through: 180, by: 2).map { [$0, Double(lat)] }))
        }
        return ["type": "FeatureCollection", "features": features]
    }

    private static func line(_ coords: [[Double]]) -> [String: Any] {
        ["type": "Feature", "properties": [String: Any](), "geometry": ["type": "LineString", "coordinates": coords]]
    }
}

// MARK: - Icons drawn at runtime (registered on the style)

enum MapIcons {
    /// Blue airplane pointing up, rotated by the style with the ownship track.
    static func ownship() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 15, y: 1))
            p.addLine(to: CGPoint(x: 26, y: 27))
            p.addLine(to: CGPoint(x: 15, y: 21))
            p.addLine(to: CGPoint(x: 4, y: 27))
            p.close()
            UIColor(hex: 0x3D8BFF).setFill()
            p.fill()
            UIColor.white.withAlphaComponent(0.9).setStroke()
            p.lineWidth = 1.2
            p.stroke()
        }
    }

    /// White-outlined waypoint triangle used on the route.
    static func waypointTriangle(night: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 14, height: 13)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 7, y: 1))
            p.addLine(to: CGPoint(x: 13, y: 12))
            p.addLine(to: CGPoint(x: 1, y: 12))
            p.close()
            (night ? UIColor(hex: 0x1B1E23) : UIColor.white).setFill()
            p.fill()
            UIColor(hex: 0xE8B04A).setStroke()
            p.lineWidth = 1.8
            p.stroke()
        }
    }

    /// Lido "gear" airport symbol in the role colour.
    static func airport(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { ctx in
            let c = CGPoint(x: 11, y: 11)
            let r: CGFloat = 5.5
            color.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ring.lineWidth = 2.4
            ring.stroke()
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                let t = UIBezierPath()
                t.move(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                t.addLine(to: CGPoint(x: c.x + cos(a) * r * 1.65, y: c.y + sin(a) * r * 1.65))
                t.lineWidth = 2.4
                t.lineCapStyle = .round
                t.stroke()
            }
        }
    }
}

extension MapIcons {
    /// Yellow holding-point bar (rotated across the taxiway by the style).
    static func holdBar() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 28, height: 7)).image { _ in
            UIColor(hex: 0xF5C518).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 28, height: 7), cornerRadius: 1.5).fill()
        }
    }

    /// Salmon stand triangle pointing along the lead-in line.
    static func stand() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 9, y: 2))
            p.addLine(to: CGPoint(x: 16, y: 16))
            p.addLine(to: CGPoint(x: 2, y: 16))
            p.close()
            UIColor(hex: 0xE07A5F, alpha: 0.25).setFill()
            p.fill()
            UIColor(hex: 0xE07A5F).setStroke()
            p.lineWidth = 2
            p.stroke()
        }
    }

    /// Blue runway-end badge; the designator is drawn on top as text.
    static func runwayBadge(color: UIColor = UIColor(hex: 0x2F7BE5)) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
            let c = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 28, height: 28))
            color.setFill()
            c.fill()
            UIColor.white.setStroke()
            c.lineWidth = 1.5
            c.stroke()
        }
    }

    /// VATSIM traffic: an airliner silhouette pointing up (blue, or orange when highlighted by search).
    static func vatsimPlane(color: UIColor = UIColor(hex: 0x3D6BFF)) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 16, y: 1))
            p.addCurve(to: CGPoint(x: 18, y: 10), controlPoint1: CGPoint(x: 17.5, y: 2), controlPoint2: CGPoint(x: 18, y: 6))
            p.addLine(to: CGPoint(x: 31, y: 18))
            p.addLine(to: CGPoint(x: 31, y: 21))
            p.addLine(to: CGPoint(x: 18, y: 17))
            p.addLine(to: CGPoint(x: 17.5, y: 25))
            p.addLine(to: CGPoint(x: 22, y: 29))
            p.addLine(to: CGPoint(x: 22, y: 31))
            p.addLine(to: CGPoint(x: 16, y: 29.5))
            p.addLine(to: CGPoint(x: 10, y: 31))
            p.addLine(to: CGPoint(x: 10, y: 29))
            p.addLine(to: CGPoint(x: 14.5, y: 25))
            p.addLine(to: CGPoint(x: 14, y: 17))
            p.addLine(to: CGPoint(x: 1, y: 21))
            p.addLine(to: CGPoint(x: 1, y: 18))
            p.addLine(to: CGPoint(x: 14, y: 10))
            p.addCurve(to: CGPoint(x: 16, y: 1), controlPoint1: CGPoint(x: 14, y: 6), controlPoint2: CGPoint(x: 14.5, y: 2))
            p.close()
            color.setFill()
            p.fill()
        }
    }

    static let atcColors: [Character: UIColor] = ["D": UIColor(hex: 0x3B6CF0), "G": UIColor(hex: 0x3E9A3A),
                                                  "T": UIColor(hex: 0xD9301E), "A": UIColor(hex: 0xF2B705)]

    /// Zoomed-in ATC letter badges (D blue, G green, T red, A ATIS yellow), joined with rounded outer corners.
    static func atcBadge(_ letters: String) -> UIImage {
        let size: CGFloat = 26
        let width = max(CGFloat(letters.count), 1) * size
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: size)).image { ctx in
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: size), cornerRadius: 4).addClip()
            for (i, ch) in letters.enumerated() {
                let r = CGRect(x: CGFloat(i) * size, y: 0, width: size, height: size)
                (atcColors[ch] ?? .gray).setFill()
                UIBezierPath(rect: r).fill()
                let text = NSAttributedString(string: String(ch), attributes: [
                    .font: UIFont.systemFont(ofSize: 17, weight: .bold),
                    .foregroundColor: ch == "A" ? UIColor(hex: 0x1A1A1A) : UIColor.white,
                ])
                let ts = text.size()
                text.draw(at: CGPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
            }
        }
    }

    /// Zoomed-out ATC indicator: one thin coloured segment per station type.
    static func atcBar(_ letters: String) -> UIImage {
        let seg: CGFloat = 14, h: CGFloat = 4
        let width = max(CGFloat(letters.count), 1) * seg
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: h)).image { _ in
            for (i, ch) in letters.enumerated() {
                (atcColors[ch] ?? .gray).setFill()
                UIBezierPath(rect: CGRect(x: CGFloat(i) * seg, y: 0, width: seg, height: h)).fill()
            }
        }
    }

    /// Traffic counts beside an airport: green ▲ departing, white ▬ landed, red ▼ arriving (zeros omitted).
    static func trafficCounts(departing: Int, landed: Int, arriving: Int) -> UIImage {
        let rows: [(Int, UIColor, Int)] = [(departing, UIColor(hex: 0x3E9A3A), 0), (landed, UIColor(hex: 0xEDEDED), 1),
                                           (arriving, UIColor(hex: 0xE2401E), 2)].filter { $0.0 > 0 }
        let rowH: CGFloat = 17
        return UIGraphicsImageRenderer(size: CGSize(width: 48, height: max(CGFloat(rows.count), 1) * rowH)).image { _ in
            for (i, row) in rows.enumerated() {
                let y = CGFloat(i) * rowH
                row.1.setFill()
                let icon = UIBezierPath()
                switch row.2 {
                case 0: // up triangle
                    icon.move(to: CGPoint(x: 1, y: y + 13)); icon.addLine(to: CGPoint(x: 9, y: y + 5)); icon.addLine(to: CGPoint(x: 17, y: y + 13))
                case 1: // bar
                    icon.append(UIBezierPath(rect: CGRect(x: 1, y: y + 6, width: 16, height: 6)))
                default: // down triangle
                    icon.move(to: CGPoint(x: 1, y: y + 5)); icon.addLine(to: CGPoint(x: 9, y: y + 13)); icon.addLine(to: CGPoint(x: 17, y: y + 5))
                }
                icon.close()
                icon.fill()
                NSAttributedString(string: "\(row.0)", attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: row.1,
                ]).draw(at: CGPoint(x: 21, y: y))
            }
        }
    }

    /// Stretchable dark label box for sector/approach names (icon-text-fit stretches the middle).
    static func labelBox(border: UIColor, fill: UIColor = UIColor(hex: 0x2B2B2B)) -> UIImage {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            let r = UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 14, height: 14), cornerRadius: 2.5)
            fill.withAlphaComponent(0.95).setFill()
            r.fill()
            border.setStroke()
            r.lineWidth = 2
            r.stroke()
        }
        return img.resizableImage(withCapInsets: UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5), resizingMode: .stretch)
    }

    /// VOR: hexagon with a centre dot (Lido-like, light blue).
    static func vor() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
            let p = UIBezierPath()
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3
                let pt = CGPoint(x: 10 + cos(a) * 7.5, y: 10 + sin(a) * 7.5)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.close()
            UIColor(hex: 0x5AB0E8).setStroke()
            p.lineWidth = 1.8
            p.stroke()
            UIColor(hex: 0x5AB0E8).setFill()
            UIBezierPath(ovalIn: CGRect(x: 8.5, y: 8.5, width: 3, height: 3)).fill()
        }
    }

    /// DME / TACAN: square with a centre dot.
    static func dme() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in
            let r = UIBezierPath(rect: CGRect(x: 3, y: 3, width: 12, height: 12))
            UIColor(hex: 0x5AB0E8).setStroke()
            r.lineWidth = 1.8
            r.stroke()
            UIColor(hex: 0x5AB0E8).setFill()
            UIBezierPath(ovalIn: CGRect(x: 7.5, y: 7.5, width: 3, height: 3)).fill()
        }
    }

    /// NDB: magenta dotted ring with a centre dot.
    static func ndb() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
            UIColor(hex: 0xC467C9).setFill()
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6
                UIBezierPath(ovalIn: CGRect(x: 10 + cos(a) * 7 - 1, y: 10 + sin(a) * 7 - 1, width: 2, height: 2)).fill()
            }
            UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 4, height: 4)).fill()
        }
    }

    static func windsock() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 16)).image { _ in
            let pole = UIBezierPath(rect: CGRect(x: 20, y: 0, width: 2, height: 16))
            UIColor.gray.setFill()
            pole.fill()
            for i in 0..<4 {
                (i % 2 == 0 ? UIColor(hex: 0xE8613A) : UIColor.white).setFill()
                UIBezierPath(rect: CGRect(x: CGFloat(15 - i * 5), y: 2 + CGFloat(i), width: 5, height: 8 - CGFloat(i) * 1.5)).fill()
            }
        }
    }
}

extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
