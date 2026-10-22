import SwiftUI

/// "Aircraft" module: Fenix A320 cockpit panels (radios, transponder/TCAS, FCU, lights) drawn like the real
/// hardware and driven through the bridge. Values come back from the sim, so the panels stay in sync with
/// whatever is flipped in the virtual cockpit.
struct AircraftScreen: View {
    @EnvironmentObject private var bridge: BridgeClient

    var body: some View {
        AircraftPanels(vars: bridge.aircraft)
    }
}

private enum AircraftPage: String, CaseIterable, Identifiable {
    case radio = "RADIO", atc = "ATC / TCAS", fcu = "FCU", lights = "LIGHTS"
    var id: String { rawValue }
}

private struct AircraftPanels: View {
    @EnvironmentObject private var bridge: BridgeClient
    @ObservedObject var vars: AircraftVars
    @AppStorage("aircraftPage") private var pageRaw = AircraftPage.radio.rawValue
    @State private var natural: CGSize = .zero

    private var page: AircraftPage { AircraftPage(rawValue: pageRaw) ?? .radio }
    private var fenix: FenixActions { FenixActions(bridge: bridge) }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Panels keep their real proportions and scale down to fit the screen width, centred.
            GeometryReader { g in
                let scale = natural.width > 0 ? min(1, g.size.width / natural.width) : 1
                ScrollView(.vertical, showsIndicators: false) {
                    pageContent
                        .fixedSize()
                        .padding(.horizontal, 28)
                        .background(GeometryReader { c in
                            // Preferences don't leave the ScrollView on iOS 15, so measure here directly.
                            Color.clear
                                .onAppear { natural = c.size }
                                .onChange(of: c.size) { natural = $0 }
                        })
                        .scaleEffect(scale, anchor: .top)
                        .frame(width: g.size.width, height: natural.height * scale, alignment: .top)
                        .padding(.vertical, 28)
                }
            }
        }
        .background(Color(hex: 0x1A1D21))
        .onAppear { bridge.watch(FenixA320.allWatched) }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .radio:
            VStack(spacing: 22) {
                RMPPanel(rmp: FenixA320.rmp1, vars: vars, fenix: fenix)
                RMPPanel(rmp: FenixA320.rmp2, vars: vars, fenix: fenix)
            }
        case .atc: ATCPanel(vars: vars, fenix: fenix)
        case .fcu: FCUPanel(vars: vars, fenix: fenix)
        case .lights: LightsPanel(vars: vars, fenix: fenix)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(AircraftPage.allCases) { p in
                    Button { pageRaw = p.rawValue } label: {
                        Text(p.rawValue).font(.system(size: 13, weight: .bold)).tracking(0.5)
                            .foregroundColor(page == p ? .black : Cockpit.engraving)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(page == p ? Cockpit.amber : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            Spacer()
            statusPill
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color(hex: 0x24282D))
    }

    /// Why the panels might not respond: no bridge, no sim, or a different aircraft loaded.
    private var statusPill: some View {
        let title = bridge.status?.sim.aircraftTitle ?? ""
        let (text, color): (String, Color) = {
            if !bridge.isConnected { return ("PC bridge not connected", Theme.warnOrange) }
            if bridge.status?.sim.connected != true { return ("MSFS not running", Theme.warnOrange) }
            if !title.lowercased().contains("fenix") && !title.lowercased().contains("a320") {
                return ("Load the Fenix A320 · now: \(title.isEmpty ? "unknown" : title)", Theme.warnOrange)
            }
            return (vars.values.isEmpty ? "Connecting to the Fenix A320…" : "Fenix A320 · live", Cockpit.green)
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(Cockpit.engraving).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.35)))
    }
}

/// Sends Fenix commands through the bridge.
@MainActor
struct FenixActions {
    let bridge: BridgeClient

    func run(_ code: String) { bridge.run(code) }
    func set(_ v: String, _ n: Int) { bridge.run(FenixA320.set(v, n)) }
    func step(_ v: String, _ dir: Int) { bridge.run(dir > 0 ? FenixA320.inc(v) : FenixA320.dec(v)) }

    func press(_ v: String, counter: Bool = true) {
        let c = counter ? FenixA320.counterPress(v) : FenixA320.holdPress(v)
        bridge.run(c.press)
        let bridge = bridge
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { bridge.run(c.release) }
    }
}

@MainActor private func lit(_ vars: AircraftVars, _ name: String?) -> Bool {
    guard let name, let v = vars[name] else { return false }
    return v > 0.5
}

private func engraved(_ s: String, size: CGFloat = 10) -> some View {
    Text(s).font(Cockpit.label(size, weight: .heavy)).foregroundColor(Cockpit.engraving).tracking(0.8)
}

// MARK: - RMP

private struct RMPPanel: View {
    let rmp: FenixA320.RMP
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions

    private var powered: Bool { (vars[rmp.power] ?? 1) > 0.5 }

    var body: some View {
        PanelPlate(title: "RMP \(rmp.n)") {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(spacing: 4) {
                    engraved("ACTIVE")
                    SegmentDisplay(text: powered ? FenixA320.frequency(vars[rmp.active]) : "", ghost: "888.888", size: 34)
                }
                AirbusButton(label: "⇆", width: 62, height: 50, fontSize: 24) { fenix.press(rmp.transfer) }
                    .overlay(engraved("TRANSFER", size: 8).offset(y: -36))
                VStack(spacing: 4) {
                    engraved("STBY/CRS")
                    SegmentDisplay(text: powered ? FenixA320.frequency(vars[rmp.standby]) : "", ghost: "888.888", size: 34)
                }
            }
            HStack(alignment: .center, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        VStack(spacing: 3) {
                            engraved("SEL", size: 9)
                            RoundedRectangle(cornerRadius: 2).fill(lit(vars, rmp.selLight) ? Cockpit.white : Color.black.opacity(0.5))
                                .frame(width: 26, height: 14)
                        }
                        ForEach(rmp.comKeys, id: \.label) { k in
                            AirbusButton(label: k.label, lit: lit(vars, k.light)) { fenix.press(k.sw, counter: k.counter) }
                        }
                    }
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 26, height: 1)
                        ForEach(rmp.navKeys, id: \.label) { k in
                            AirbusButton(label: k.label, lit: lit(vars, k.light)) { fenix.press(k.sw, counter: k.counter) }
                        }
                    }
                }
                RotaryKnob(size: 84, onStep: { fenix.step(rmp.outer, $0) }, inner: { fenix.step(rmp.inner, $0) }, caption: "OUTER MHz · INNER kHz")
                ToggleSwitch(title: "RMP", positions: [("ON", 1), ("OFF", 0)], value: vars[rmp.power].map { Int($0.rounded()) }) {
                    fenix.set(rmp.power, $0)
                }
            }
        }
    }
}

// MARK: - ATC / TCAS

private struct ATCPanel: View {
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions
    typealias A = FenixA320.ATC

    private func int(_ v: String) -> Int? { vars[v].map { Int($0.rounded()) } }

    var body: some View {
        PanelPlate(title: "ATC / TCAS") {
            HStack(alignment: .top, spacing: 34) {
                VStack(spacing: 18) {
                    RotarySelector(title: "XPDR", positions: [("STBY", 0), ("AUTO", 1), ("ON", 2)], value: int(A.operation)) { fenix.set(A.operation, $0) }
                    HStack(spacing: 18) {
                        ToggleSwitch(title: "ALT RPTG", positions: [("ON", 1), ("OFF", 0)], value: int(A.altReporting)) { fenix.set(A.altReporting, $0) }
                        ToggleSwitch(title: "SYS", positions: [("1", 0), ("2", 1)], value: int(A.system)) { fenix.set(A.system, $0) }
                    }
                }
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        SegmentDisplay(text: code, ghost: "8888", size: 40)
                        VStack(spacing: 3) {
                            engraved("ATC", size: 9)
                            Text("FAIL").font(Cockpit.label(10, weight: .heavy))
                                .foregroundColor(lit(vars, A.fail) ? Cockpit.amber : Color.black.opacity(0.55))
                                .frame(width: 44, height: 20)
                                .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.6)))
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 4), spacing: 8) {
                        ForEach([1, 2, 3, 4, 5, 6, 7, 0], id: \.self) { d in
                            AirbusButton(label: "\(d)", width: 58, height: 44) { fenix.press(A.digit(d)) }
                        }
                    }
                    HStack(spacing: 8) {
                        AirbusButton(label: "CLR", width: 92, height: 44) { fenix.press(A.clear) }
                        AirbusButton(label: "IDENT", width: 140, height: 44) { fenix.press(A.ident) }
                    }
                }
                VStack(spacing: 18) {
                    RotarySelector(title: "TRAFFIC", positions: [("THRT", 0), ("ALL", 1), ("ABV", 2), ("BLW", 3)], value: int(A.traffic)) { fenix.set(A.traffic, $0) }
                    RotarySelector(title: "TCAS", positions: [("STBY", 0), ("TA", 1), ("TA/RA", 2)], value: int(A.tcasMode)) { fenix.set(A.tcasMode, $0) }
                }
            }
        }
    }

    private var code: String {
        guard let v = vars[A.code] else { return "" }
        return String(format: "%04d", Int(v.rounded()))
    }
}

// MARK: - FCU

private struct FCUPanel: View {
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions
    typealias F = FenixA320.FCU

    var body: some View {
        PanelPlate(title: "FLIGHT CONTROL UNIT") {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    button("SPD MACH")
                    button("LOC")
                }
                .padding(.top, 26)
                window(labels: [("SPD", !mach), ("MACH", mach)], text: speedText, ghost: "888", managed: F.speedManaged, knob: F.speedKnob)
                window(labels: [("HDG", !trk), ("TRK", trk), ("LAT", true)], text: headingText, ghost: "888", managed: F.headingManaged, knob: F.headingKnob)
                VStack(spacing: 10) {
                    button("HDG V/S TRK FPA", width: 70)
                }
                .padding(.top, 26)
                VStack(spacing: 10) {
                    HStack(spacing: 8) { button("AP1"); button("AP2") }
                    button("A/THR", width: 116)
                }
                .padding(.top, 26)
                VStack(spacing: 8) {
                    window(labels: [("ALT", true), ("LVL/CH", true)], text: altitudeText, ghost: "88888", managed: F.altitudeManaged, knob: F.altitudeKnob)
                    ToggleSwitch(title: "", positions: [("100", 0), ("1000", 1)], value: vars[F.altitudeScale].map { Int($0.rounded()) }) {
                        fenix.set(F.altitudeScale, $0)
                    }
                }
                VStack(spacing: 10) {
                    button("METRIC ALT", width: 62)
                    button("EXPED", width: 62)
                }
                .padding(.top, 26)
                window(labels: [("V/S", !trk), ("FPA", trk)], text: vsText, ghost: "+8888", managed: nil, knob: F.vsKnob)
                VStack { button("APPR") }.padding(.top, 26)
            }
        }
    }

    private var mach: Bool { lit(vars, F.mach) }
    private var trk: Bool { lit(vars, F.trackFpa) }
    private var powered: Bool { (vars[F.power] ?? 1) > 0.5 }

    private var speedText: String {
        guard powered, let v = vars[F.speed] else { return "" }
        if lit(vars, F.speedDashed) { return "---" }
        return mach ? String(format: ".%02d", Int((v * 100).rounded()) % 100) : String(format: "%03d", Int(v.rounded()))
    }

    private var headingText: String {
        guard powered, let v = vars[F.heading] else { return "" }
        return lit(vars, F.headingDashed) ? "---" : String(format: "%03d", Int(v.rounded()) % 360)
    }

    private var altitudeText: String {
        guard powered, let v = vars[F.altitude] else { return "" }
        return String(format: "%05d", Int(v.rounded()))
    }

    private var vsText: String {
        guard powered, let v = vars[F.vs] else { return "" }
        if lit(vars, F.vsDashed) { return "-----" }
        if trk { return String(format: "%+.1f", v) }
        let hundreds = Int((abs(v) / 100).rounded())
        return (v < 0 ? "-" : "+") + String(format: "%02doo", hundreds)
    }

    private func button(_ key: String, width: CGFloat = 54) -> some View {
        let b = F.buttons[key]
        return AirbusButton(label: key, lit: lit(vars, b?.light), width: width) {
            if let b { fenix.press(b.sw) }
        }
    }

    private func window(labels: [(String, Bool)], text: String, ghost: String, managed: String?, knob: (String, String)) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i].0).font(Cockpit.label(9, weight: .heavy))
                        .foregroundColor(labels[i].1 && powered ? Cockpit.amber : Color.black.opacity(0.5))
                }
            }
            SegmentDisplay(text: text, ghost: ghost, size: 30, trailing: managed.flatMap { lit(vars, $0) ? "●" : " " })
            RotaryKnob(size: 66, onStep: { fenix.step(knob.0, $0) })
            HStack(spacing: 6) {
                pushPull("PUSH") { fenix.run(FenixA320.dec(knob.1)) }
                pushPull("PULL") { fenix.run(FenixA320.inc(knob.1)) }
            }
        }
    }

    private func pushPull(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            action()
        } label: {
            Text(label).font(Cockpit.label(9, weight: .heavy)).foregroundColor(Cockpit.white)
                .frame(width: 46, height: 24)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .overlay(Capsule().stroke(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lights and signs

private struct LightsPanel: View {
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions

    var body: some View {
        VStack(spacing: 22) {
            PanelPlate(title: "EXT LT") { switches(FenixA320.exteriorLights) }
            HStack(alignment: .top, spacing: 22) {
                PanelPlate(title: "SIGNS") { switches(FenixA320.signs) }
                PanelPlate(title: "INT LT") { switches(FenixA320.interiorLights) }
            }
        }
    }

    private func switches(_ list: [FenixA320.Switch]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(list, id: \.v) { s in
                ToggleSwitch(title: s.title, positions: s.positions, value: vars[s.v].map { Int($0.rounded()) }) {
                    fenix.set(s.v, $0)
                }
            }
        }
    }
}
