import CoreGraphics
import UIKit

#if DEBUG
/// Real chart PDFs bundled with debug builds, for the charts module without the sim (Resources/TestCharts/manifest.json;
/// personal-use copies, gitignored). Each is georeferenced from its lat/lon grid, so the viewer, ownship-on-chart and
/// chart-on-map behave exactly as with the sim's Lido charts.
enum BundledCharts {
    /// `ChartIndex.provider` of the offline index (the sim's charts come as "LIDO").
    static let provider = "OFFLINE"

    struct Chart {
        let detail: ChartDetail
        let imagePath: String
        let image: UIImage
        /// Who publishes the chart, e.g. "UK AIP" (from the manifest's source line).
        let publisher: String?
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

    /// The airport's bundled charts, rendered from their PDFs. Slow: call it off the main thread.
    static func charts(for icao: String) -> [Chart] {
        (manifest?.charts ?? []).filter { $0.icao == icao }.compactMap(load)
    }

    /// The chart list for the charts module: one category per chart type.
    static func index(icao: String, charts: [Chart]) -> ChartIndex {
        let byType = Dictionary(grouping: charts.map(\.detail.chart), by: \.type)
        return ChartIndex(icao: icao, provider: provider, fetchedAt: Date().timeIntervalSince1970 * 1000,
                          categories: byType.keys.sorted().map { ChartCategory(name: $0, charts: byType[$0] ?? []) })
    }

    /// "Offline UK AIP charts", or "Offline charts" when the publishers differ or aren't known.
    static func title(for charts: [Chart]) -> String {
        let publishers = Set(charts.map(\.publisher))
        if publishers.count == 1, let only = publishers.first, let publisher = only { return "Offline \(publisher) charts" }
        return "Offline charts"
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

        // The GUID is what pinned flight charts and annotations are stored under: keep its format.
        let guid = "bundled-\(e.icao)-\(e.file)"
        let meta = ChartMeta(guid: guid, type: e.type, name: e.name, runways: e.runways, procedures: e.procedures,
                             geoReferenced: true, pageCount: 1, validFrom: nil, validUntil: nil)
        let path = "offline:\(guid):0"
        let detail = ChartDetail(chart: meta, pages: [ChartPage(index: 0, width: Double(size.width), height: Double(size.height),
                                                                geoReferenced: true, areas: [area], image: path)])
        // "UK AIP AD 2-EGSS-6-3, AIRAC 10-26 (chart 520515)" → "UK AIP"
        let publisher = e.source.range(of: " AD ").map { String(e.source[..<$0.lowerBound]) }
        return Chart(detail: detail, imagePath: path, image: image, publisher: publisher)
    }
}
#endif
