import SwiftUI

/// VATSIM assistant: what's on your flight plan (assigned squawk, cruise level, route), how it changed, and which
/// controllers probably cover you, from your callsign's entry in the public VATSIM data feed.
struct VatsimAssistantPage: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @ObservedObject var assistant: VatsimAssistant
    @ObservedObject var vars: AircraftVars
    @ObservedObject var commander: FenixCommander
    let fenixLive: Bool
    let compact: Bool
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 16) {
            callsignCard
            if let f = assistant.flight {
                if assistant.isStale {
                    staleBanner
                        .transition(.card)
                }
                Group {
                    AdaptiveStack(compact: compact) {
                        squawkCard(f)
                        levelCard(f)
                    }
                    AdaptiveStack(compact: compact) {
                        controllersCard
                        changesCard
                    }
                    routeCard(f)
                }
                .opacity(assistant.isStale ? 0.5 : 1)
                .transition(.opacity)
            }
            Text("From the public VATSIM data feed, using only your callsign's entry. It shows what's saved on your flight plan: the assigned squawk, cruise level and route, and when they change. Spoken instructions such as headings and levels aren't published by VATSIM.")
                .font(.system(size: 12)).foregroundColor(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.smooth, value: assistant.flight != nil)
        .animation(Motion.smooth, value: assistant.isStale)
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
            AdaptiveStack(compact: compact, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Callsign", text: $draft, onCommit: { assistant.callsign = draft.uppercased() })
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.text)
                        .padding(.horizontal, 12).frame(maxWidth: 220, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 9).fill(theme.pill))
                        .accessibilityLabel("VATSIM callsign")
                    if let cs = app.ofp?.callsign, cs != assistant.callsign {
                        ActionButton(label: "Use \(cs)") { withAnimation(Motion.smooth) { draft = cs; assistant.callsign = cs } }
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                status
            }
            if let f = assistant.flight {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: compact ? 2 : 4), alignment: .leading, spacing: 12) {
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
            if assistant.isStale {
                if assistant.online == false { return ("\(assistant.callsign) isn't in the VATSIM feed now", Theme.warnOrange) }
                return (assistant.error ?? "VATSIM data is out of date", Theme.warnOrange)
            }
            if let e = assistant.error { return (e, Theme.warnOrange) }
            switch assistant.online {
            case nil: return ("Looking for \(assistant.callsign)…", theme.textSecondary)
            case false?: return ("\(assistant.callsign) isn't connected to VATSIM", Theme.warnOrange)
            case true?: return ("Online · updated \(ago(assistant.updated))", Theme.okGreen)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .pulse(active: assistant.online == nil && !assistant.callsign.isEmpty && !assistant.isStale && assistant.error == nil)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary)
        }
        .animation(Motion.smooth, value: color)
        .accessibilityElement(children: .combine)
    }

    private var staleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark").foregroundColor(Theme.warnOrange)
            Text("Old data: \(assistant.callsign) was last seen in the feed \(assistant.lastSeen.map(time) ?? "earlier"). Nothing below is applied to the aircraft.")
                .font(.system(size: 14, weight: .medium)).foregroundColor(theme.text)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warnOrange.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }

    private func squawkCard(_ f: VatsimAssistant.Flight) -> some View {
        let fenixCode = fenixLive ? vars[FenixA320.ATC.code].map { String(format: "%04d", Int($0.rounded())) } : nil
        let current = fenixCode ?? f.transponder
        let busy = commander.isPending("squawk")
        return Card(title: "Assigned squawk") {
            if let sq = f.assignedSquawk {
                HStack(alignment: .firstTextBaseline) {
                    Text(sq).font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundColor(current == sq ? Theme.okGreen : Theme.ownshipBlue)
                        .crossfadeOnChange(of: sq)
                    Spacer()
                    if current == sq {
                        Label("Set", systemImage: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.okGreen)
                            .transition(.pop)
                    }
                }
                if current != sq {
                    HStack(spacing: 10) {
                        Text("You're squawking \(current ?? "–")").font(.system(size: 14)).foregroundColor(theme.textSecondary)
                        Spacer()
                        let canSet = fenixLive && !assistant.isStale && !busy
                        ActionButton(label: busy ? "Setting…" : "Set in Fenix", prominent: true, pending: busy,
                                     accessibilityName: "Set squawk \(sq) in the Fenix") { commander.squawk(sq) }
                            .disabled(!canSet)
                    }
                    .transition(.opacity)
                    if !fenixLive {
                        Text("Connect the Fenix to set it from here.").font(.system(size: 12)).foregroundColor(theme.textSecondary)
                    }
                }
            } else {
                Text("No squawk assigned yet").font(.system(size: 17)).foregroundColor(theme.textSecondary)
                Text("It appears here once a controller assigns one, usually with your clearance.")
                    .font(.system(size: 13)).foregroundColor(theme.textSecondary)
            }
        }
        .animation(Motion.bouncy, value: f.assignedSquawk.map { $0 == current })
        .animation(Motion.smooth, value: f.assignedSquawk)
    }

    private func levelCard(_ f: VatsimAssistant.Flight) -> some View {
        Card(title: "Cruise level in flight plan") {
            Text(VatsimAssistant.level(f.cruise) ?? "–")
                .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(theme.text)
                .crossfadeOnChange(of: f.cruise)
            if let filed = app.ofp?.cruiseFl, let now = VatsimAssistant.level(f.cruise), now != "FL\(filed)" {
                Text("Your SimBrief plan says FL\(filed)").font(.system(size: 13)).foregroundColor(Theme.warnOrange)
            } else {
                Text("As saved on your VATSIM flight plan.").font(.system(size: 13)).foregroundColor(theme.textSecondary)
            }
        }
    }

    private var controllersCard: some View {
        Card(title: "Likely ATC (estimate)") {
            if assistant.covering.isEmpty && assistant.departureStations.isEmpty && assistant.arrivalStations.isEmpty {
                Text("No ATC online for your position or airports. UNICOM 122.800").font(.system(size: 15)).foregroundColor(theme.textSecondary)
            }
            if !assistant.covering.isEmpty {
                section("Probably covering your position", assistant.covering)
            }
            if !assistant.departureStations.isEmpty {
                section("Departure \(assistant.flight?.departure ?? "")", assistant.departureStations)
            }
            if !assistant.arrivalStations.isEmpty {
                section("Arrival \(assistant.flight?.arrival ?? "")", assistant.arrivalStations)
            }
            Text("Estimated from published sector boundaries. The controller actually working you can differ; follow handoffs on frequency.")
                .font(.system(size: 12)).foregroundColor(theme.textSecondary)
        }
        // Controllers logging on or off fade in and out.
        .animation(Motion.smooth, value: (assistant.covering + assistant.departureStations + assistant.arrivalStations).map(\.id))
    }

    private func section(_ title: String, _ list: [VatsimAssistant.Contact]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary)
            ForEach(list) { c in
                HStack(spacing: 10) {
                    Text(c.role).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary).frame(width: 74, alignment: .leading)
                    Text(c.controller.callsign).font(.system(size: 15, weight: .semibold)).foregroundColor(theme.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer()
                    frequency(c.controller.frequency, station: c.controller.callsign)
                }
                .frame(minHeight: 44)
            }
        }
    }

    /// Tap a controller's frequency to load it into a radio's standby window.
    @ViewBuilder private func frequency(_ text: String, station: String) -> some View {
        let khz = FrequencyInput.khz(vatsim: text)
        let label = Text(text).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
        if let khz, fenixLive, !assistant.isStale {
            Menu {
                Button("Radio 1 standby") { commander.tune(rmp: 1, khz: khz) }
                Button("Radio 2 standby") { commander.tune(rmp: 2, khz: khz) }
            } label: {
                HStack(spacing: 6) {
                    label.foregroundColor(Theme.ownshipBlue)
                    Image(systemName: "arrow.down.to.line.compact").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.ownshipBlue)
                }
                .padding(.horizontal, 10).frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ownshipBlue.opacity(0.12)))
            }
            .accessibilityLabel("\(station) \(text)")
            .accessibilityHint("Load into a radio's standby frequency")
        } else {
            label.foregroundColor(Theme.okGreen)
                .accessibilityLabel("\(station) \(text)")
        }
    }

    private var changesCard: some View {
        Card(title: "Flight-plan changes") {
            if assistant.changes.isEmpty {
                Text("Nothing yet. Changes to your squawk, cruise level, route, destination or alternate show up here while this page is open, whether a controller or you made them.")
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
                    .accessibilityElement(children: .combine)
                    .transition(.card)
                }
            }
        }
        .animation(Motion.bouncy, value: assistant.changes.map(\.id))
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
