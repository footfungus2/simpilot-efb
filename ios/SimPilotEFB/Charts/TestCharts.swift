import CoreGraphics
import UIKit

#if DEBUG
/// Georeferenced test charts generated from the airport-map data (OpenStreetMap), so the charts module —
/// viewer, ownship-on-chart, chart-on-map — can be used without the sim. They're labelled as test charts and
/// carry the same georeferencing as Lido pages, so everything downstream behaves exactly as with real charts.
enum TestCharts {
    static let provider = "TEST"

    struct Result {
        let index: ChartIndex
        let details: [String: ChartDetail]  // by chart GUID
        let images: [String: UIImage]       // by page image path ("test:<guid>:<page>")
    }

    /// Page size in chart units (portrait, like Lido pages); rendered at 2× for sharp zooming.
    private static let page = CGSize(width: 1100, height: 1500)
    private static let headerHeight: CGFloat = 150

    static func build(icao: String, name: String?, features: [[String: Any]]) -> Result? {
        var details: [String: ChartDetail] = [:]
        var images: [String: UIImage] = [:]
        var metas: [String: [ChartMeta]] = [:]
        let runways = runwayIdents(features)

        func add(type: String, title: String, box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double), stands: Bool) {
            let guid = "test-\(icao)-\(type)"
            let region = CGRect(x: 30, y: headerHeight + 20, width: page.width - 60, height: page.height - headerHeight - 90)
            guard let area = ChartGeoProjection.area(fitting: box, into: region), let proj = ChartGeoProjection(area: area) else { return }
            let image = render(icao: icao, name: name, title: title, features: features, proj: proj, area: area, showStands: stands)
            let path = "test:\(guid):0"
            images[path] = image
            let meta = ChartMeta(guid: guid, type: type, name: "\(title) (test)", runways: runways, procedures: [],
                                 geoReferenced: true, pageCount: 1, validFrom: nil, validUntil: nil)
            details[guid] = ChartDetail(chart: meta, pages: [ChartPage(index: 0, width: page.width, height: page.height,
                                                                       geoReferenced: true, areas: [area], image: path)])
            metas[type, default: []].append(meta)
        }

        // Generated from the airport map (needs OSM data for the airport).
        if let box = bounds(of: features, kinds: ["runway-area", "runway-surface", "apron", "pavement", "taxiway-surface", "building"], margin: 0.08) {
            add(type: "AGC", title: "Airport Ground Chart", box: box, stands: false)
            // Parking chart: zoomed onto the stands, if the airport has any mapped.
            if let standBox = bounds(of: features, kinds: ["stand"], margin: 0.15) {
                add(type: "APC", title: "Airport Parking Chart", box: standBox, stands: true)
            }
        }

        // Real charts bundled for debugging (Resources/TestCharts/manifest.json).
        for bundled in BundledCharts.charts(for: icao) {
            details[bundled.detail.chart.guid] = bundled.detail
            images[bundled.imagePath] = bundled.image
            metas[bundled.detail.chart.type, default: []].append(bundled.detail.chart)
        }

        guard !details.isEmpty else { return nil }
        let index = ChartIndex(icao: icao, provider: provider, fetchedAt: Date().timeIntervalSince1970 * 1000,
                               categories: metas.keys.sorted().map { ChartCategory(name: $0, charts: metas[$0]!) })
        return Result(index: index, details: details, images: images)
    }

    // MARK: Rendering

    private static func render(icao: String, name: String?, title: String, features: [[String: Any]],
                               proj: ChartGeoProjection, area: ChartArea, showStands: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: page, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: page))

            let r = area.chartRect
            let plan = CGRect(x: r.upperLeft[0], y: r.upperLeft[1], width: r.lowerRight[0] - r.upperLeft[0], height: r.lowerRight[1] - r.upperLeft[1])
            cg.saveGState()
            cg.clip(to: plan)

            func pt(_ c: [Double]) -> CGPoint { proj.project(lat: c[1], lon: c[0]) }
            func path(_ geometry: [String: Any]) -> UIBezierPath {
                let p = UIBezierPath()
                func ring(_ coords: [[Double]], close: Bool) {
                    guard let first = coords.first else { return }
                    p.move(to: pt(first))
                    coords.dropFirst().forEach { p.addLine(to: pt($0)) }
                    if close { p.close() }
                }
                let c = geometry["coordinates"]
                switch geometry["type"] as? String {
                case "Polygon": (c as? [[[Double]]])?.forEach { ring($0, close: true) }
                case "MultiPolygon": (c as? [[[[Double]]]])?.forEach { $0.forEach { ring($0, close: true) } }
                case "LineString": (c as? [[Double]]).map { ring($0, close: false) }
                case "MultiLineString": (c as? [[[Double]]])?.forEach { ring($0, close: false) }
                default: break
                }
                return p
            }
            func each(_ kind: String, _ draw: ([String: Any], [String: Any]) -> Void) {
                for f in features {
                    guard let props = f["properties"] as? [String: Any], props["kind"] as? String == kind,
                          let g = f["geometry"] as? [String: Any] else { continue }
                    draw(props, g)
                }
            }

            // Surfaces: polygons are filled; taxiways/runways are stroked at their real width.
            let unitsPerMetre: CGFloat = {
                let a = proj.unproject(CGPoint(x: plan.midX, y: plan.midY))
                let b = proj.unproject(CGPoint(x: plan.midX + 100, y: plan.midY))
                let m = hypot((b.lat - a.lat) * 111_320, (b.lon - a.lon) * 111_320 * cos(a.lat * .pi / 180))
                return m > 0 ? CGFloat(100 / m) : 1
            }()
            func surface(_ kind: String, _ colour: UIColor, cap: CGLineCap) {
                colour.setStroke()
                each(kind) { props, g in
                    let p = path(g)
                    p.lineWidth = CGFloat(props["width"] as? Double ?? 20) * unitsPerMetre
                    p.lineCapStyle = cap
                    p.lineJoinStyle = cap == .round ? .round : .miter
                    p.stroke()
                }
            }
            UIColor(hex: 0xE4E4E4).setFill()
            each("apron") { _, g in path(g).fill() }
            each("pavement") { _, g in path(g).fill() }
            surface("taxiway-surface", UIColor(hex: 0xE4E4E4), cap: .round)
            UIColor(hex: 0x6E6E6E).setFill()
            each("runway-area") { _, g in path(g).fill() }
            surface("runway-surface", UIColor(hex: 0x6E6E6E), cap: .butt)
            UIColor(hex: 0xA8A8A8).setFill()
            each("building") { _, g in path(g).fill() }
            UIColor.white.setStroke()
            each("runway-centerline") { _, g in
                let p = path(g)
                p.lineWidth = 2
                p.setLineDash([14, 10], count: 2, phase: 0)
                p.stroke()
            }
            UIColor(hex: 0xE0A800).setStroke()
            each("taxi-line") { _, g in
                let p = path(g)
                p.lineWidth = 1.2
                p.stroke()
            }
            if showStands {
                UIColor(hex: 0xE0A800).withAlphaComponent(0.6).setStroke()
                each("stand-line") { _, g in
                    let p = path(g)
                    p.lineWidth = 0.7
                    p.stroke()
                }
            }
            // Holding points as short black bars across the taxiway.
            UIColor.black.setFill()
            each("hold") { props, g in
                guard let c = g["coordinates"] as? [Double] else { return }
                let p = pt(c)
                cg.saveGState()
                cg.translateBy(x: p.x, y: p.y)
                cg.rotate(by: CGFloat((props["rot"] as? Double ?? 0) * .pi / 180))
                cg.fill(CGRect(x: -7, y: -1.5, width: 14, height: 3))
                cg.restoreGState()
            }

            // Labels
            var placed: [CGRect] = []
            func label(_ text: String, at p: CGPoint, size: CGFloat, bold: Bool = true, box: UIColor? = nil, color: UIColor = .black) {
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular),
                                                            .foregroundColor: color]
                let s = NSAttributedString(string: text, attributes: attrs)
                let sz = s.size()
                let rect = CGRect(x: p.x - sz.width / 2 - 3, y: p.y - sz.height / 2 - 1, width: sz.width + 6, height: sz.height + 2)
                guard plan.contains(rect), !placed.contains(where: { $0.intersects(rect) }) else { return }
                placed.append(rect)
                (box ?? UIColor.white.withAlphaComponent(0.85)).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 3).fill()
                if box == nil {
                    UIColor.black.setStroke()
                    let border = UIBezierPath(roundedRect: rect, cornerRadius: 3)
                    border.lineWidth = 0.6
                    border.stroke()
                }
                s.draw(at: CGPoint(x: rect.minX + 3, y: rect.minY + 1))
            }
            each("runway-end") { props, g in
                guard let c = g["coordinates"] as? [Double], let ref = props["ref"] as? String, !ref.hasPrefix("H") else { return }
                label(ref, at: pt(c), size: 16, box: .black, color: .white)
            }
            each("taxi-line") { props, g in
                guard let ref = props["ref"] as? String, !ref.isEmpty, let coords = g["coordinates"] as? [[Double]], !coords.isEmpty else { return }
                label(ref, at: pt(coords[coords.count / 2]), size: 11)
            }
            if showStands {
                each("stand") { props, g in
                    guard let c = g["coordinates"] as? [Double], let ref = props["ref"] as? String, !ref.isEmpty else { return }
                    let p = pt(c)
                    UIColor(hex: 0xC2410C).setFill()
                    UIBezierPath(ovalIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
                    label(ref, at: CGPoint(x: p.x, y: p.y - 9), size: 9, bold: false)
                }
            }
            cg.restoreGState()

            // Frame, header, north arrow, scale bar
            UIColor.black.setStroke()
            let frame = UIBezierPath(rect: plan)
            frame.lineWidth = 1.5
            frame.stroke()
            drawHeader(icao: icao, name: name, title: title)
            drawNorthArrow(at: CGPoint(x: plan.maxX - 40, y: plan.minY + 50))
            drawScaleBar(proj: proj, origin: CGPoint(x: plan.minX + 20, y: plan.maxY - 30))
        }
    }

    private static func drawHeader(icao: String, name: String?, title: String) {
        let black: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44, weight: .heavy), .foregroundColor: UIColor.black]
        NSAttributedString(string: icao, attributes: black).draw(at: CGPoint(x: 30, y: 24))
        let sub: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: UIColor.black]
        NSAttributedString(string: (name ?? "").uppercased(), attributes: sub).draw(at: CGPoint(x: 32, y: 80))
        let t: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: UIColor.black]
        let ts = NSAttributedString(string: title.uppercased(), attributes: t)
        ts.draw(at: CGPoint(x: page.width - 30 - ts.size().width, y: 30))
        let warn: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor(hex: 0xC2410C)]
        let ws = NSAttributedString(string: "TEST CHART · GENERATED FROM OPENSTREETMAP · NOT FOR NAVIGATION", attributes: warn)
        ws.draw(at: CGPoint(x: page.width - 30 - ws.size().width, y: 64))
        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: 30, y: headerHeight - 20))
        rule.addLine(to: CGPoint(x: page.width - 30, y: headerHeight - 20))
        rule.lineWidth = 2
        UIColor.black.setStroke()
        rule.stroke()
    }

    private static func drawNorthArrow(at c: CGPoint) {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: c.x, y: c.y - 26))
        p.addLine(to: CGPoint(x: c.x + 10, y: c.y + 10))
        p.addLine(to: CGPoint(x: c.x, y: c.y + 2))
        p.addLine(to: CGPoint(x: c.x - 10, y: c.y + 10))
        p.close()
        UIColor.black.setFill()
        p.fill()
        NSAttributedString(string: "N", attributes: [.font: UIFont.systemFont(ofSize: 14, weight: .bold)])
            .draw(at: CGPoint(x: c.x - 5, y: c.y + 12))
    }

    private static func drawScaleBar(proj: ChartGeoProjection, origin: CGPoint) {
        // Chart units per metre, measured along the chart.
        let a = proj.unproject(origin)
        let b = proj.unproject(CGPoint(x: origin.x + 100, y: origin.y))
        let metres = hypot((b.lat - a.lat) * 111_320, (b.lon - a.lon) * 111_320 * cos(a.lat * .pi / 180))
        guard metres > 0 else { return }
        let unitsPerMetre = 100 / metres
        let lengthM: Double = [100, 200, 250, 500, 1000, 2000].last { Double($0) * unitsPerMetre < 260 } ?? 100
        let w = CGFloat(lengthM * unitsPerMetre)
        UIColor.white.setFill()
        UIBezierPath(rect: CGRect(x: origin.x - 6, y: origin.y - 20, width: w + 60, height: 30)).fill()
        UIColor.black.setFill()
        UIBezierPath(rect: CGRect(x: origin.x, y: origin.y, width: w, height: 4)).fill()
        NSAttributedString(string: "\(Int(lengthM)) m", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold)])
            .draw(at: CGPoint(x: origin.x, y: origin.y - 18))
    }

    // MARK: Helpers

    private static func bounds(of features: [[String: Any]], kinds: Set<String>, margin: Double)
        -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? {
        var minLat = Double.infinity, minLon = Double.infinity, maxLat = -Double.infinity, maxLon = -Double.infinity
        func visit(_ any: Any?) {
            if let c = any as? [Double], c.count >= 2 {
                minLon = min(minLon, c[0]); maxLon = max(maxLon, c[0]); minLat = min(minLat, c[1]); maxLat = max(maxLat, c[1])
            } else if let arr = any as? [Any] {
                arr.forEach(visit)
            }
        }
        for f in features where kinds.contains((f["properties"] as? [String: Any])?["kind"] as? String ?? "") {
            visit((f["geometry"] as? [String: Any])?["coordinates"])
        }
        guard minLat.isFinite else { return nil }
        let dLat = max(maxLat - minLat, 0.002) * margin, dLon = max(maxLon - minLon, 0.003) * margin
        return (minLat - dLat, minLon - dLon, maxLat + dLat, maxLon + dLon)
    }

    private static func runwayIdents(_ features: [[String: Any]]) -> [String] {
        let refs = features.compactMap { f -> String? in
            guard let p = f["properties"] as? [String: Any], p["kind"] as? String == "runway-end" else { return nil }
            return p["ref"] as? String
        }
        return Array(Set(refs.filter { !$0.hasPrefix("H") })).sorted()
    }
}

/// Real chart PDFs bundled for debugging, georeferenced from their lat/lon grid (see manifest.json).
enum BundledCharts {
    struct Chart {
        let detail: ChartDetail
        let imagePath: String
        let image: UIImage
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            struct Grid: Decodable { let lon0, x0, lon1, x1, lat0, y0, lat1, y1: Double }
            struct Lambert: Decodable { let sp1, sp2, cm: Double; let similarity: [Double] }
            let icao, type, name, file, source: String
            let runways: [String]
            let procedures: [String]
            let grid: Grid?          // straight lat/lon grid (PDF points, y up)
            let lambert: Lambert?    // fitted Lambert conic in display coordinates
            let rotate: Int?         // 90 = turn a sideways page clockwise so north is up
            let frame: [Double]      // x0, yTop0, x1, yTop1 in display chart units from the top-left
        }
        let charts: [Entry]
    }

    private static let folder = Bundle.main.resourceURL?.appendingPathComponent("TestCharts")

    private static let manifest: Manifest? = {
        guard let url = folder?.appendingPathComponent("manifest.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    static func charts(for icao: String) -> [Chart] {
        (manifest?.charts ?? []).filter { $0.icao == icao }.compactMap(load)
    }

    private static func load(_ e: Manifest.Entry) -> Chart? {
        guard let url = folder?.appendingPathComponent(e.file), let doc = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1), e.frame.count == 4 else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let rotated = e.rotate == 90
        // Display size: a page turned clockwise swaps width and height.
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let f = e.frame
        let chartRect = ChartRect(upperLeft: [f[0], f[1]], lowerRight: [f[2], f[3]], orientation: 0)

        let area: ChartArea
        if let l = e.lambert {
            area = ChartArea(layer: "plan", geoReferenced: true, chartRect: chartRect, worldRect: nil,
                             projection: ChartProjection(standardParallel1: l.sp1, standardParallel2: l.sp2, centralMeridian: l.cm),
                             similarity: l.similarity)
        } else if let g = e.grid, !rotated {
            // Grid is measured in PDF points with y up; chart units are PDF points with y down.
            func lon(atX x: Double) -> Double { g.lon0 + (x - g.x0) / (g.x1 - g.x0) * (g.lon1 - g.lon0) }
            func lat(atTop y: Double) -> Double { g.lat0 + ((Double(box.height) - y) - g.y0) / (g.y1 - g.y0) * (g.lat1 - g.lat0) }
            area = ChartArea(layer: "plan", geoReferenced: true, chartRect: chartRect,
                             worldRect: ChartRect(upperLeft: [lon(atX: f[0]), lat(atTop: f[1])],
                                                  lowerRight: [lon(atX: f[2]), lat(atTop: f[3])], orientation: 0),
                             projection: nil, linear: true)
        } else {
            return nil
        }

        // Render the vector PDF at 4× so it stays sharp when zoomed in.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if rotated {
                // PDF (x, y-up) → display (y-up, x): the page turned 90° clockwise, north up.
                ctx.cgContext.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
            } else {
                ctx.cgContext.translateBy(x: 0, y: box.height)
                ctx.cgContext.scaleBy(x: 1, y: -1)
            }
            ctx.cgContext.drawPDFPage(page)
        }

        let guid = "bundled-\(e.icao)-\(e.file)"
        let meta = ChartMeta(guid: guid, type: e.type, name: e.name, runways: e.runways, procedures: e.procedures,
                             geoReferenced: true, pageCount: 1, validFrom: nil, validUntil: nil)
        let path = "test:\(guid):0"
        let detail = ChartDetail(chart: meta, pages: [ChartPage(index: 0, width: Double(size.width), height: Double(size.height),
                                                                geoReferenced: true, areas: [area], image: path)])
        return Chart(detail: detail, imagePath: path, image: image)
    }
}
#endif
