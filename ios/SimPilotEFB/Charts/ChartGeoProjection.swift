import CoreGraphics
import Foundation

/// Projects lat/lon onto a georeferenced chart area, in the chart page's own units.
///
/// Port of `ChartUtils.setGeoProjectionFromChartArea` from the MSFS SDK (msfs-sdk 2.3.3): a Lambert
/// conformal conic projection rotated so the central meridian is at 0°, anchored so the area's
/// world upper-left lands on its chart upper-left, uniformly scaled from the diagonal, rotated by
/// −orientation and with Y pointing down.
struct ChartGeoProjection {
    /// Linear charts: chart point = offset + lon/lat × scale, per axis.
    private var linear: (x0: Double, lon0: Double, kx: Double, y0: Double, lat0: Double, ky: Double)?
    /// Fitted Lambert charts (see `ChartArea.similarity`).
    private var fitted: (tx: Double, ty: Double, s: Double, theta: Double)?
    private let n: Double
    private let F: Double
    private let centralMeridian: Double
    private let originRaw: CGPoint
    private let scale: Double
    private let rotation: Double
    private let translation: CGPoint

    init?(area: ChartArea) {
        if let sim = area.similarity, sim.count == 4, let proj = area.projection, area.geoReferenced, sim[2] != 0 {
            let phi1 = proj.standardParallel1 * .pi / 180, phi2 = proj.standardParallel2 * .pi / 180
            n = abs(phi1 - phi2) < 1e-9 ? sin(phi1)
                : log(cos(phi1) / cos(phi2)) / log(tan(.pi / 4 + phi2 / 2) / tan(.pi / 4 + phi1 / 2))
            guard n.isFinite, n != 0 else { return nil }
            F = cos(phi1) * pow(tan(.pi / 4 + phi1 / 2), n) / n
            centralMeridian = proj.centralMeridian
            fitted = (sim[0], sim[1], sim[2], sim[3])
            originRaw = .zero; scale = 1; rotation = 0; translation = .zero
            return
        }
        if area.linear == true {
            guard area.geoReferenced, let w = area.worldRect, w.upperLeft.count == 2, w.lowerRight.count == 2,
                  area.chartRect.upperLeft.count == 2, area.chartRect.lowerRight.count == 2,
                  w.lowerRight[0] != w.upperLeft[0], w.lowerRight[1] != w.upperLeft[1] else { return nil }
            let c = area.chartRect
            linear = (x0: c.upperLeft[0], lon0: w.upperLeft[0], kx: (c.lowerRight[0] - c.upperLeft[0]) / (w.lowerRight[0] - w.upperLeft[0]),
                      y0: c.upperLeft[1], lat0: w.upperLeft[1], ky: (c.lowerRight[1] - c.upperLeft[1]) / (w.lowerRight[1] - w.upperLeft[1]))
            n = 1; F = 1; centralMeridian = 0; originRaw = .zero; scale = 1; rotation = 0; translation = .zero
            return
        }
        guard area.geoReferenced,
              let world = area.worldRect,
              let proj = area.projection,
              world.upperLeft.count == 2, world.lowerRight.count == 2,
              area.chartRect.upperLeft.count == 2, area.chartRect.lowerRight.count == 2
        else { return nil }

        let phi1 = proj.standardParallel1 * .pi / 180
        let phi2 = proj.standardParallel2 * .pi / 180
        if abs(phi1 - phi2) < 1e-9 {
            n = sin(phi1)
        } else {
            n = log(cos(phi1) / cos(phi2)) / log(tan(.pi / 4 + phi2 / 2) / tan(.pi / 4 + phi1 / 2))
        }
        guard n.isFinite, n != 0 else { return nil }
        F = cos(phi1) * pow(tan(.pi / 4 + phi1 / 2), n) / n
        centralMeridian = proj.centralMeridian
        rotation = -world.orientation * .pi / 180

        // Raw projection of the anchor (world upper-left: [lon, lat]).
        let ulLon = world.upperLeft[0], ulLat = world.upperLeft[1]
        let lrLon = world.lowerRight[0], lrLat = world.lowerRight[1]
        let tmpOrigin = Self.raw(lat: ulLat, lon: ulLon, n: n, F: F, cm: proj.centralMeridian)
        originRaw = tmpOrigin

        let lrRaw = Self.raw(lat: lrLat, lon: lrLon, n: n, F: F, cm: proj.centralMeridian)
        let lrUnscaled = Self.orient(CGPoint(x: lrRaw.x - tmpOrigin.x, y: lrRaw.y - tmpOrigin.y), rotation: rotation)
        let projectedDiag = hypot(lrUnscaled.x, lrUnscaled.y)
        let chartDiag = hypot(area.chartRect.lowerRight[0] - area.chartRect.upperLeft[0],
                              area.chartRect.lowerRight[1] - area.chartRect.upperLeft[1])
        guard projectedDiag > 0 else { return nil }
        scale = chartDiag / projectedDiag
        translation = CGPoint(x: area.chartRect.upperLeft[0], y: area.chartRect.upperLeft[1])
    }

    /// Chart-unit coordinates for a position (x right, y down).
    func project(lat: Double, lon: Double) -> CGPoint {
        if let f = fitted {
            let r = Self.raw(lat: lat, lon: lon, n: n, F: F, cm: centralMeridian)
            let a = Double(r.x), b = -Double(r.y)
            return CGPoint(x: f.tx + f.s * (a * cos(f.theta) - b * sin(f.theta)),
                           y: f.ty + f.s * (a * sin(f.theta) + b * cos(f.theta)))
        }
        if let l = linear {
            return CGPoint(x: l.x0 + (lon - l.lon0) * l.kx, y: l.y0 + (lat - l.lat0) * l.ky)
        }
        let r = Self.raw(lat: lat, lon: lon, n: n, F: F, cm: centralMeridian)
        let p = Self.orient(CGPoint(x: r.x - originRaw.x, y: r.y - originRaw.y), rotation: rotation)
        return CGPoint(x: translation.x + p.x * scale, y: translation.y + p.y * scale)
    }

    /// Inverse of `project`: chart-unit position → (lat, lon). Used to pin a chart onto the moving map.
    func unproject(_ p: CGPoint) -> (lat: Double, lon: Double) {
        if let f = fitted {
            let dx = (Double(p.x) - f.tx) / f.s, dy = (Double(p.y) - f.ty) / f.s
            let a = dx * cos(-f.theta) - dy * sin(-f.theta)
            let b = dx * sin(-f.theta) + dy * cos(-f.theta)
            return Self.inverseRaw(x: a, y: -b, n: n, F: F, cm: centralMeridian)
        }
        if let l = linear {
            return (l.lat0 + (Double(p.y) - l.y0) / l.ky, l.lon0 + (Double(p.x) - l.x0) / l.kx)
        }
        // Undo translation/scale, then the rotation, then the Y reflection.
        let ox = (Double(p.x) - Double(translation.x)) / scale
        let oy = (Double(p.y) - Double(translation.y)) / scale
        let ux = ox * cos(-rotation) - oy * sin(-rotation)
        let uy = ox * sin(-rotation) + oy * cos(-rotation)
        let rx = ux + Double(originRaw.x)
        let ry = -uy + Double(originRaw.y)
        let sign: Double = n < 0 ? -1 : 1
        let rho = sign * hypot(rx, ry)
        let theta = atan2(sign * rx, sign * -ry)
        let lon = centralMeridian + theta / n * 180 / .pi
        let lat = (2 * atan(pow(F / rho, 1 / n)) - .pi / 2) * 180 / .pi
        return (lat, lon)
    }

    /// A georeferenced area that fits a lat/lon box into `region` (chart units) at a uniform scale, centred.
    /// Used for the generated test charts, so they georeference exactly like Lido pages do.
    static func area(fitting box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double), into region: CGRect) -> ChartArea? {
        let midLat = (box.minLat + box.maxLat) / 2
        let proj = ChartProjection(standardParallel1: midLat - 0.5, standardParallel2: midLat + 0.5,
                                   centralMeridian: (box.minLon + box.maxLon) / 2)
        let world = ChartRect(upperLeft: [box.minLon, box.maxLat], lowerRight: [box.maxLon, box.minLat], orientation: 0)
        // Probe at an arbitrary scale to learn the box's projected aspect ratio.
        let probe = ChartArea(layer: "plan", geoReferenced: true,
                              chartRect: ChartRect(upperLeft: [0, 0], lowerRight: [100, 100], orientation: 0),
                              worldRect: world, projection: proj)
        guard let lr = ChartGeoProjection(area: probe)?.project(lat: box.minLat, lon: box.maxLon), lr.x > 0, lr.y > 0 else { return nil }
        let k = min(Double(region.width) / Double(lr.x), Double(region.height) / Double(lr.y))
        let w = Double(lr.x) * k, h = Double(lr.y) * k
        let x0 = Double(region.minX) + (Double(region.width) - w) / 2
        let y0 = Double(region.minY) + (Double(region.height) - h) / 2
        return ChartArea(layer: "plan", geoReferenced: true,
                         chartRect: ChartRect(upperLeft: [x0, y0], lowerRight: [x0 + w, y0 + h], orientation: 0),
                         worldRect: world, projection: proj)
    }

    /// Inverse of `raw`.
    private static func inverseRaw(x: Double, y: Double, n: Double, F: Double, cm: Double) -> (lat: Double, lon: Double) {
        let sign: Double = n < 0 ? -1 : 1
        let rho = sign * hypot(x, y)
        let theta = atan2(sign * x, sign * -y)
        return ((2 * atan(pow(F / rho, 1 / n)) - .pi / 2) * 180 / .pi, cm + theta / n * 180 / .pi)
    }

    /// Unit-sphere LCC with Y up, longitudes taken relative to the central meridian.
    private static func raw(lat: Double, lon: Double, n: Double, F: Double, cm: Double) -> CGPoint {
        let phi = lat * .pi / 180
        var dLon = (lon - cm).truncatingRemainder(dividingBy: 360)
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        let rho = F / pow(tan(.pi / 4 + phi / 2), n)
        let theta = n * dLon * .pi / 180
        return CGPoint(x: rho * sin(theta), y: -rho * cos(theta))
    }

    /// Reflects Y (chart Y points down) and applies the area's rotation.
    private static func orient(_ p: CGPoint, rotation: Double) -> CGPoint {
        let x = p.x, y = -p.y
        return CGPoint(x: x * cos(rotation) - y * sin(rotation), y: x * sin(rotation) + y * cos(rotation))
    }
}

extension ChartPage {
    /// Chart-unit position of a coordinate on the first georeferenced area that contains it.
    func position(lat: Double, lon: Double) -> CGPoint? {
        for area in areas where area.geoReferenced {
            guard let proj = ChartGeoProjection(area: area) else { continue }
            let p = proj.project(lat: lat, lon: lon)
            let r = area.chartRect
            let minX = min(r.upperLeft[0], r.lowerRight[0]), maxX = max(r.upperLeft[0], r.lowerRight[0])
            let minY = min(r.upperLeft[1], r.lowerRight[1]), maxY = max(r.upperLeft[1], r.lowerRight[1])
            if p.x >= minX, p.x <= maxX, p.y >= minY, p.y <= maxY { return p }
        }
        return nil
    }
}
