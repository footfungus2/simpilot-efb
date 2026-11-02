import SwiftUI

/// Fuel on board against the SimBrief plan, now and at each waypoint passed. Needs the PC bridge (the fuel comes from
/// the sim) and a loaded flight; the aircraft has to report its total fuel weight.
struct FuelPage: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme
    @ObservedObject var store: FlightToolsStore
    var compact: Bool

    var body: some View {
        if let ofp = app.ofp {
            VStack(spacing: 16) {
                // The aircraft state changes ten times a second; the page only needs it every couple of seconds.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    nowCard(ofp, ownship: bridge.ownship.ownship)
                }
                AdaptiveStack(compact: compact) {
                    planCard(ofp)
                    passesCard(ofp)
                }
            }
        } else {
            Card(title: "Fuel") {
                Text("Load your SimBrief flight in the Flight Folder to compare the fuel on board with the plan.")
                    .font(.system(size: 14)).foregroundColor(theme.textSecondary)
            }
        }
    }

    // MARK: Units

    private func unit(_ ofp: Ofp) -> (name: String, perKg: Double) {
        ofp.fuel.units.lowercased().hasPrefix("lb") ? ("lbs", 1 / 0.45359237) : ("kg", 1)
    }

    private func amount(_ kg: Double, _ ofp: Ofp, signed: Bool = false) -> String {
        let u = unit(ofp)
        let value = (kg * u.perKg).rounded()
        return String(format: signed ? "%+.0f %@" : "%.0f %@", value, u.name)
    }

    // MARK: Cards

    private func nowCard(_ ofp: Ofp, ownship: Ownship?) -> some View {
        let check = ownship.flatMap { FuelCheck(ofp: ofp, ownship: $0) }
        return Card(title: "Now") {
            if let check {
                let ok = abs(check.deltaKg) <= FuelCheck.tolerance(plannedKg: check.plannedKg)
                HStack(spacing: 12) {
                    Fact(label: "On board", value: amount(check.actualKg, ofp))
                    Fact(label: "Planned here", value: amount(check.plannedKg, ofp))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DIFFERENCE").font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary).tracking(0.5)
                        Text(amount(check.deltaKg, ofp, signed: true)).font(.system(size: 20, weight: .bold))
                            .foregroundColor(ok ? Theme.okGreen : Theme.warnOrange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(String(format: "%.0f NM along the planned route · ", check.alongNm) + (ok ? "on plan" : check.deltaKg < 0 ? "less than planned" : "more than planned"))
                    .font(.system(size: 13)).foregroundColor(theme.textSecondary)
            } else {
                Text(reason(ofp, ownship))
                    .font(.system(size: 14)).foregroundColor(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reason(_ ofp: Ofp, _ ownship: Ownship?) -> String {
        if !bridge.isConnected { return "Connect to the PC bridge: the fuel on board comes from the sim." }
        guard let ownship else { return "Waiting for data from the sim." }
        guard let fuel = ownship.fuelKg, fuel > 0 else { return "The sim reports no fuel weight for this aircraft, so there is nothing to compare." }
        if !ofp.navlog.contains(where: { $0.fuelPlanKg != nil }) { return "This flight plan has no fuel per waypoint. Reload it from SimBrief." }
        return "The aircraft is not near the planned route, so the planned fuel can't be placed."
    }

    private func planCard(_ ofp: Ofp) -> some View {
        Card(title: "SimBrief plan") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Fact(label: "Ramp", value: amount(ofp.fuel.ramp / unit(ofp).perKg, ofp))
                    Fact(label: "Takeoff", value: amount(ofp.fuel.takeoff / unit(ofp).perKg, ofp))
                }
                HStack(spacing: 12) {
                    Fact(label: "Landing", value: amount(ofp.fuel.landing / unit(ofp).perKg, ofp))
                    Fact(label: "Min takeoff", value: amount(ofp.fuel.minTakeoff / unit(ofp).perKg, ofp))
                }
            }
        }
    }

    private func passesCard(_ ofp: Ofp) -> some View {
        let passes = store.data.fuelPasses[app.flightKey] ?? []
        return Card(title: "At each waypoint") {
            if passes.isEmpty {
                Text("Each waypoint you pass in flight is noted here with the fuel on board against the plan.")
                    .font(.system(size: 14)).foregroundColor(theme.textSecondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(passes) { pass in
                        let ok = abs(pass.deltaKg) <= FuelCheck.tolerance(plannedKg: pass.plannedKg)
                        HStack {
                            Text(pass.ident).font(.system(size: 15, weight: .semibold)).foregroundColor(theme.text).frame(width: 70, alignment: .leading)
                            Text(amount(pass.actualKg, ofp)).font(.system(size: 14)).foregroundColor(theme.text).monospacedDigit()
                            Text("plan " + amount(pass.plannedKg, ofp)).font(.system(size: 13)).foregroundColor(theme.textSecondary).monospacedDigit()
                            Spacer()
                            Text(amount(pass.deltaKg, ofp, signed: true)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                .foregroundColor(ok ? Theme.okGreen : Theme.warnOrange)
                        }
                        .padding(.horizontal, 10).frame(minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
                    }
                }
            }
        }
    }
}
