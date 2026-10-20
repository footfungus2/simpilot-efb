import CoreLocation
import Foundation

/// Flies a simulated aircraft along the loaded SimBrief route, for testing without the sim or the bridge.
@MainActor
final class DemoFlight {
    private struct Point {
        var coord: CLLocationCoordinate2D
        var altFt: Double
        var distNm: Double // cumulative, great-circle
    }

    private var points: [Point] = []
    private var alongNm = 0.0
    private var timer: Timer?
    private var lastTick = Date()
    private let output: (Ownship) -> Void

    /// Time multiplier (1 = real time).
    var speed: Double = 8

    init(output: @escaping (Ownship) -> Void) {
        self.output = output
    }

    var isRunning: Bool { timer != nil }

    func start(ofp: Ofp) {
        var pts: [Point] = [Point(coord: ofp.origin.coordinate, altFt: ofp.origin.elevFt, distNm: 0)]
        for fix in ofp.navlog where !(fix.lat == 0 && fix.lon == 0) {
            let last = pts[pts.count - 1]
            pts.append(Point(coord: fix.coordinate, altFt: fix.altFt, distNm: last.distNm + Self.distanceNm(last.coord, fix.coordinate)))
        }
        if let last = pts.last, Self.distanceNm(last.coord, ofp.destination.coordinate) > 0.5 {
            pts.append(Point(coord: ofp.destination.coordinate, altFt: ofp.destination.elevFt,
                             distNm: last.distNm + Self.distanceNm(last.coord, ofp.destination.coordinate)))
        }
        guard pts.count >= 2 else { return }
        points = pts
        alongNm = 0
        lastTick = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        alongNm = 0
        lastTick = Date()
    }

    private func tick() {
        guard let total = points.last?.distNm, total > 0 else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        let state = sample(at: alongNm)
        let gs = groundSpeed(altFt: state.altFt, along: alongNm, total: total)
        alongNm += gs * dt * speed / 3600
        if alongNm >= total { alongNm = 0 } // loop the flight

        let next = sample(at: min(alongNm + 1, total))
        output(Ownship(lat: state.coord.latitude, lon: state.coord.longitude, altFt: state.altFt,
                       gsKt: gs, trkDeg: Self.bearing(state.coord, next.coord), hdgDeg: Self.bearing(state.coord, next.coord),
                       vsFpm: (next.altFt - state.altFt) / max(1 / gs * 60, 0.01),
                       onGround: alongNm < 1 || total - alongNm < 1, magVarDeg: 0, ts: now.timeIntervalSince1970 * 1000))
    }

    /// Roughly: taxi/takeoff roll, 280 kt climbing, 460 kt in cruise, slowing on approach.
    private func groundSpeed(altFt: Double, along: Double, total: Double) -> Double {
        if along < 1 { return 140 }
        if total - along < 15 { return 150 }
        return 250 + min(altFt, 35_000) / 35_000 * 210
    }

    private func sample(at d: Double) -> (coord: CLLocationCoordinate2D, altFt: Double) {
        guard let i = points.lastIndex(where: { $0.distNm <= d }), i < points.count - 1 else {
            let p = points.last!
            return (p.coord, p.altFt)
        }
        let a = points[i], b = points[i + 1]
        let t = (b.distNm - a.distNm) > 0 ? (d - a.distNm) / (b.distNm - a.distNm) : 0
        let coord = CLLocationCoordinate2D(latitude: a.coord.latitude + (b.coord.latitude - a.coord.latitude) * t,
                                           longitude: a.coord.longitude + (b.coord.longitude - a.coord.longitude) * t)
        return (coord, a.altFt + (b.altFt - a.altFt) * t)
    }

    static func distanceNm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
