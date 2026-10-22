import SwiftUI

/// VATSIM assistant: what ATC has given your flight (assigned squawk, flight-plan amendments) and who to talk to,
/// from your callsign's entry in the public VATSIM data feed.
struct VatsimAssistantPage: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme
    @ObservedObject var assistant: VatsimAssistant
    @ObservedObject var vars: AircraftVars
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 16) {
            callsignCard
            if let f = assistant.flight {
                HStack(alignment: .top, spacing: 16) {
                    squawkCard(f)
                    levelCard(f)
                }
                HStack(alignment: .top, spacing: 16) {
                    controllersCard
                    changesCard
                }
                routeCard(f)
            }
            Text("From the public VATSIM data feed, using only your callsign's entry. Shows what controllers save to your flight: the assigned squawk and flight-plan amendments. Spoken instructions such as headings and levels aren't published by VATSIM.")
                .font(.system(size: 12)).foregroundColor(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if assistant.callsign.isEmpty, let cs = app.ofp?.callsign { assistant.callsign = cs }
            draft = assistant.callsign
            assistant.start()
        }
        .onDisappear { assistant.stop() }
    }

    // MARK: Cards

    private var callsignCard: some View {
        Card(title: "Your flight") {
            HStack(spacing: 14) {
                TextField("Callsign", text: $draft, onCommit: { assistant.callsign = draft.uppercased() })
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.text)
                    .padding(.horizontal, 12).frame(width: 200, height: 44)
                    .background(RoundedRectangle(cornerRadius: 9).fill(theme.pill))
                if let cs = app.ofp?.callsign, cs != assistant.callsign {
                    ActionButton(label: "Use \(cs)") { draft = cs; assistant.callsign = cs }
                }
                Spacer()
                status
            }
            if let f = assistant.flight {
                HStack(spacing: 28) {
                    Readout(caption: "Route", value: "\(f.departure ?? "–") → \(f.arrival ?? "–")", size: 20)
                    Readout(caption: "Altitude", value: "\(Int(f.altitudeFt.rounded())) ft", size: 20)
                    Readout(caption: "Ground speed", value: "\(Int(f.groundspeed.rounded())) kt", size: 20)
                    Readout(caption: "Squawking", value: f.transponder ?? "–", size: 20)
                }
            }
        }
    }

    private var status: some View {
        let (text, color): (String, Color) = {
            if assistant.callsign.isEmpty { return ("Enter your VATSIM callsign", theme.textSecondary) }
            if let e = assistant.error { return (e, Theme.warnOrange) }
            switch assistant.online {
            case nil: return ("Looking for \(assistant.callsign)…", theme.textSecondary)
            case false?: return ("\(assistant.callsign) isn't connected to VATSIM", Theme.warnOrange)
            case true?: return ("Online · updated \(ago(assistant.updated))", Theme.okGreen)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary)
        }
    }

    private func squawkCard(_ f: VatsimAssistant.Flight) -> some View {
        let fenixCode = vars[FenixA320.ATC.code].map { String(format: "%04d", Int($0.rounded())) }
        let current = fenixCode ?? f.transponder
        return Card(title: "Assigned squawk") {
            if let sq = f.assignedSquawk {
                HStack(alignment: .firstTextBaseline) {
                    Text(sq).font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundColor(current == sq ? Theme.okGreen : Theme.ownshipBlue)
                    Spacer()
                    if current == sq {
                        Label("Set", systemImage: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.okGreen)
                    }
                }
                if current != sq {
                    HStack(spacing: 10) {
                        Text("You're squawking \(current ?? "–")").font(.system(size: 14)).foregroundColor(theme.textSecondary)
                        Spacer()
                        ActionButton(label: "Set in Fenix", prominent: true) { FenixActions(bridge: bridge).squawk(sq) }
                            .disabled(!bridge.isConnected)
                            .opacity(bridge.isConnected ? 1 : 0.5)
                    }
                }
            } else {
                Text("No squawk assigned yet").font(.system(size: 17)).foregroundColor(theme.textSecondary)
                Text("It appears here once a controller assigns one (usually with your clearance).")
                    .font(.system(size: 13)).foregroundColor(theme.textSecondary)
            }
        }
    }

    private func levelCard(_ f: VatsimAssistant.Flight) -> some View {
        Card(title: "Cruise level in flight plan") {
            Text(VatsimAssistant.level(f.cruise) ?? "–")
                .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(theme.text)
            if let filed = app.ofp?.cruiseFl, let now = VatsimAssistant.level(f.cruise), now != "FL\(filed)" {
                Text("Filed FL\(filed) in SimBrief").font(.system(size: 13)).foregroundColor(Theme.warnOrange)
            } else {
                Text("Controllers amend this when they change your cruise level.").font(.system(size: 13)).foregroundColor(theme.textSecondary)
            }
        }
    }

    private var controllersCard: some View {
        Card(title: "Controllers") {
            if assistant.covering.isEmpty && assistant.departureStations.isEmpty && assistant.arrivalStations.isEmpty {
                Text("No ATC online for your position or airports — UNICOM 122.800").font(.system(size: 15)).foregroundColor(theme.textSecondary)
            }
            if !assistant.covering.isEmpty {
                section("Covering your position", assistant.covering)
            }
            if !assistant.departureStations.isEmpty {
                section("Departure \(assistant.flight?.departure ?? "")", assistant.departureStations)
            }
            if !assistant.arrivalStations.isEmpty {
                section("Arrival \(assistant.flight?.arrival ?? "")", assistant.arrivalStations)
            }
        }
    }

    private func section(_ title: String, _ list: [VatsimAssistant.Contact]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary)
            ForEach(list) { c in
                HStack(spacing: 10) {
                    Text(c.role).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary).frame(width: 74, alignment: .leading)
                    Text(c.controller.callsign).font(.system(size: 15, weight: .semibold)).foregroundColor(theme.text)
                    Spacer()
                    Text(c.controller.frequency).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundColor(Theme.okGreen)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var changesCard: some View {
        Card(title: "Changes from ATC") {
            if assistant.changes.isEmpty {
                Text("Nothing yet. Squawk, level and route changes made by controllers show up here while this page is open.")
                    .font(.system(size: 14)).foregroundColor(theme.textSecondary)
            } else {
                ForEach(assistant.changes) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Text(time(c.time)).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundColor(theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.system(size: 15, weight: .semibold)).foregroundColor(theme.text)
                            Text(c.detail).font(.system(size: 14)).foregroundColor(Theme.ownshipBlue).lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    private func routeCard(_ f: VatsimAssistant.Flight) -> some View {
        Card(title: "Route in flight plan") {
            Text(f.route?.isEmpty == false ? f.route! : "–")
                .font(.system(size: 15, design: .monospaced)).foregroundColor(theme.text)
                .textSelection(.enabled)
            if let alt = f.alternate, !alt.isEmpty {
                Text("Alternate \(alt)").font(.system(size: 13)).foregroundColor(theme.textSecondary)
            }
        }
    }

    // MARK: Formatting

    private func ago(_ d: Date?) -> String {
        guard let d else { return "–" }
        let s = Int(Date().timeIntervalSince(d))
        return s < 60 ? "\(s) s ago" : "\(s / 60) min ago"
    }

    private func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm'z'"
        return f.string(from: d)
    }
}
