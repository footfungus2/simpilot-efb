import Foundation

/// Fuel on board against the SimBrief plan at the aircraft's position along the planned route.
struct FuelCheck: Equatable {
    var actualKg: Double
    var plannedKg: Double
    /// Distance flown along the planned route, NM.
    var alongNm: Double

    /// Positive: more fuel than planned.
    var deltaKg: Double { actualKg - plannedKg }

    init?(ofp: Ofp, ownship o: Ownship) {
        guard let actual = o.fuelKg, actual > 0,
              let along = RouteProgress.alongTrackNm(ofp: ofp, o),
              let planned = Self.planned(ofp: ofp, alongNm: along) else { return nil }
        actualKg = actual
        plannedKg = planned
        alongNm = along
    }

    /// Planned fuel remaining `alongNm` from the origin, interpolated between the fixes that carry a plan.
    static func planned(ofp: Ofp, alongNm: Double) -> Double? {
        let points = ofp.navlog.compactMap { fix in fix.fuelPlanKg.map { (nm: fix.cumNm, kg: $0) } }
        guard let first = points.first, points.count >= 2 else { return nil }
        if alongNm <= first.nm { return first.kg }
        for i in 1..<points.count where alongNm <= points[i].nm {
            let a = points[i - 1], b = points[i]
            let t = b.nm > a.nm ? (alongNm - a.nm) / (b.nm - a.nm) : 0
            return a.kg + (b.kg - a.kg) * t
        }
        return points[points.count - 1].kg
    }

    /// How far off plan is still "on plan": 1 % of the planned fuel, at least 100 kg.
    static func tolerance(plannedKg: Double) -> Double { max(100, plannedKg * 0.01) }
}
