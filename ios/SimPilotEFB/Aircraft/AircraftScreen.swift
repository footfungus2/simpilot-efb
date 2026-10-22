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

@MainActor private func int(_ vars: AircraftVars, _ name: String) -> Int? {
    vars[name].map { Int($0.rounded()) }
}

// MARK: - RMP (pedestal)

/// Radio management panel as on the A320 pedestal: ACTIVE and STBY/CRS windows with the green transfer key
/// between them, VHF/HF/AM keys with lights above, the STBY NAV row, the dual knob and the ON/OFF switch.
private struct RMPPanel: View {
    let rmp: FenixA320.RMP
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions

    private var powered: Bool { (vars[rmp.power] ?? 1) > 0.5 }

    var body: some View {
        PanelPlate(area: .pedestal) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(spacing: 4) {
                        Engraved("ACTIVE", size: 13, heavy: true)
                        BezelLCD(text: powered ? FenixA320.frequency(vars[rmp.active]) : "", ghost: "888.888", size: 30)
                    }
                    transferKey
                    VStack(spacing: 4) {
                        Engraved("STBY/CRS", size: 13, heavy: true)
                        BezelLCD(text: powered ? FenixA320.frequency(vars[rmp.standby]) : "", ghost: "888.888", size: 30)
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            key(rmp.comKeys[0]); key(rmp.comKeys[1]); key(rmp.comKeys[2])
                        }
                        HStack(alignment: .bottom, spacing: 10) {
                            key(rmp.comKeys[3])
                            // SEL light: lit when this RMP tunes a radio normally tuned by another one.
                            Circle().fill(lit(vars, rmp.selLight) ? Cockpit.engraving : Color.black.opacity(0.65))
                                .frame(width: 26, height: 26)
                                .overlay(Engraved("SEL", size: 9, heavy: true, color: lit(vars, rmp.selLight) ? .black : Cockpit.engraving.opacity(0.4)))
                                .frame(width: 54)
                            key(rmp.comKeys[4]); key(rmp.comKeys[5])
                        }
                        HStack(spacing: 8) {
                            Rectangle().fill(Cockpit.engraving.opacity(0.8)).frame(width: 90, height: 1.2)
                            Engraved("STBY NAV", size: 12, heavy: true)
                            Rectangle().fill(Cockpit.engraving.opacity(0.8)).frame(height: 1.2)
                        }
                        .frame(width: 400)
                        HStack(spacing: 10) {
                            ForEach(Array(rmp.navKeys.enumerated()), id: \.offset) { i, k in
                                key(k, guarded: i == 0)
                            }
                        }
                    }
                    VStack(spacing: 18) {
                        KnurledKnob(size: 84, onStep: { fenix.step(rmp.outer, $0) }, inner: { fenix.step(rmp.inner, $0) })
                            .padding(.top, 4)
                        BatToggle(positions: [("ON", 1), ("OFF", 0)], value: int(vars, rmp.power)) { fenix.set(rmp.power, $0) }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Engraved("RMP \(rmp.n)", size: 10, heavy: true, color: Cockpit.engraving.opacity(0.55)).padding(.leading, 24).padding(.top, 6)
        }
    }

    private var transferKey: some View {
        VStack(spacing: 4) {
            Circle().fill(Color(white: 0.85)).frame(width: 8, height: 8).opacity(0.8)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                fenix.press(rmp.transfer)
            } label: {
                Image(systemName: "arrow.left.and.right").font(.system(size: 22, weight: .heavy))
                    .foregroundColor(powered ? Cockpit.green : Cockpit.green.opacity(0.15))
                    .shadow(color: powered ? Cockpit.green.opacity(0.7) : .clear, radius: 4)
                    .frame(width: 58, height: 40)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Cockpit.key))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 10)
    }

    private func key(_ k: (label: String, sw: String, light: String, counter: Bool), guarded: Bool = false) -> some View {
        BlackKey(label: k.label, width: 54, height: 30, led: lit(vars, k.light)) { fenix.press(k.sw, counter: k.counter) }
            .overlay(guarded ? guardCover : nil, alignment: .bottom)
    }

    /// Clear guard over the NAV key.
    private var guardCover: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.45)))
            .frame(width: 62, height: 38)
            .allowsHitTesting(false)
    }
}

// MARK: - ATC / TCAS (pedestal)

private struct ATCPanel: View {
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions
    typealias A = FenixA320.ATC

    var body: some View {
        PanelPlate(area: .pedestal) {
            HStack(alignment: .center, spacing: 24) {
                // Transponder mode, altitude reporting and system selection.
                VStack(spacing: 10) {
                    PointerSelector(title: "XPDR", positions: [("STBY", 0), ("AUTO", 1), ("ON", 2)], value: int(vars, A.operation)) { fenix.set(A.operation, $0) }
                    HStack(spacing: 22) {
                        BatToggle(title: "ALT RPTG", positions: [("ON", 1), ("OFF", 0)], value: int(vars, A.altReporting)) { fenix.set(A.altReporting, $0) }
                        BatToggle(title: "SYS", positions: [("1", 0), ("2", 1)], value: int(vars, A.system)) { fenix.set(A.system, $0) }
                    }
                }
                // Keypad 1 2 3 / 4 5 6 / 7 0 CLR, as on the panel.
                VStack(spacing: 10) {
                    ForEach([[1, 2, 3], [4, 5, 6]], id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(row, id: \.self) { d in digit(d) }
                        }
                    }
                    HStack(spacing: 12) {
                        digit(7); digit(0)
                        BlackKey(label: "CLR", width: 50, height: 42, fontSize: 15) { fenix.press(A.clear) }
                    }
                }
                // Code window, ATC FAIL light and IDENT.
                VStack(alignment: .trailing, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Engraved("ATC", size: 10, heavy: true, color: Cockpit.amber)
                            LCDText(text: code, ghost: "8888", size: 38)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Cockpit.lcd))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.8), lineWidth: 2))
                        RoundButton(label: "IDENT", size: 34) { fenix.press(A.ident) }
                    }
                    HStack(spacing: 6) {
                        Circle().fill(lit(vars, A.fail) ? Cockpit.amber : Color(hex: 0x3A2A16))
                            .frame(width: 14, height: 14)
                            .shadow(color: lit(vars, A.fail) ? Cockpit.amber : .clear, radius: 4)
                        VStack(alignment: .leading, spacing: 0) {
                            Engraved("ATC", size: 10, heavy: true)
                            Engraved("FAIL", size: 10, heavy: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle().fill(Cockpit.engraving.opacity(0.7)).frame(width: 1.2, height: 210)
                // TCAS.
                VStack(spacing: 6) {
                    Engraved("TCAS", size: 14, heavy: true)
                    PointerSelector(positions: [("THRT", 0), ("ALL", 1), ("ABV", 2), ("BLW", 3)], value: int(vars, A.traffic)) { fenix.set(A.traffic, $0) }
                    PointerSelector(positions: [("STBY", 0), ("TA", 1), ("TA/RA", 2)], value: int(vars, A.tcasMode)) { fenix.set(A.tcasMode, $0) }
                }
            }
        }
    }

    private func digit(_ d: Int) -> some View {
        BlackKey(label: "\(d)", width: 50, height: 42, fontSize: 20) { fenix.press(A.digit(d)) }
    }

    private var code: String {
        guard let v = vars[A.code] else { return "" }
        return String(format: "%04d", Int(v.rounded()))
    }
}

// MARK: - FCU (glareshield)

/// Flight control unit as on the A320 glareshield: one long LCD across the top with amber legends, round
/// SPD-MACH / HDG-V/S TRK-FPA / METRIC ALT buttons, silver knobs and green-lit AP/A-THR/LOC/EXPED/APPR keys,
/// separated by white engraved lines.
private struct FCUPanel: View {
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions
    typealias F = FenixA320.FCU

    private let lcdHeight: CGFloat = 64

    var body: some View {
        PanelPlate(area: .glareshield) {
            HStack(alignment: .top, spacing: 0) {
                column(width: 70, lcd: { Color.clear }) {
                    RoundButton(label: "SPD\nMACH") { press("SPD MACH") }
                }
                column(width: 130, lcd: {
                    field(labels: [("SPD", !mach), ("MACH", mach)], text: speedText, ghost: "888", managed: F.speedManaged)
                }) { knob(F.speedKnob) }
                column(width: 140, lcd: {
                    field(labels: [("HDG", !trk), ("TRK", trk), ("LAT", powered)], text: headingText, ghost: "888", managed: F.headingManaged)
                }) {
                    knob(F.headingKnob)
                    key("LOC").padding(.top, 6)
                }
                separator
                column(width: 160, lcd: {
                    VStack(spacing: 4) {
                        HStack(spacing: 14) { legend("HDG", !trk); legend("V/S", !trk) }
                        HStack(spacing: 14) { legend("TRK", trk); legend("FPA", trk) }
                    }
                }) {
                    HStack(spacing: 6) {
                        Engraved("HDG\nTRK", size: 10, heavy: true).multilineTextAlignment(.trailing)
                        RoundButton { press("HDG V/S TRK FPA") }
                        Engraved("V/S\nFPA", size: 10, heavy: true)
                    }
                    HStack(spacing: 10) { key("AP1"); key("AP2") }.padding(.top, 8)
                    key("A/THR").padding(.top, 8)
                }
                separator
                column(width: 170, lcd: {
                    field(labels: [("ALT", powered), ("LVL/CH", powered)], text: altitudeText, ghost: "88888", managed: F.altitudeManaged)
                }) {
                    HStack(alignment: .center, spacing: 6) {
                        PointerSelector(positions: [("100", 0), ("1000", 1)], value: int(vars, F.altitudeScale), onSelect: { fenix.set(F.altitudeScale, $0) }, size: 26)
                            .frame(width: 70, height: 60)
                        knob(F.altitudeKnob)
                    }
                    key("EXPED").padding(.top, 6)
                }
                column(width: 70, lcd: { Color.clear }) {
                    RoundButton(label: "METRIC\nALT") { press("METRIC ALT") }
                }
                column(width: 150, lcd: {
                    field(labels: [("V/S", !trk), ("FPA", trk)], text: vsText, ghost: "+8888", managed: nil)
                }) {
                    HStack(spacing: 4) {
                        knob(F.vsKnob)
                        VStack(alignment: .leading, spacing: 18) {
                            Engraved("UP", size: 10, heavy: true)
                            Engraved("DN", size: 10, heavy: true)
                        }
                    }
                    key("APPR").padding(.top, 6)
                }
            }
            .padding(.top, 4)
        }
    }

    // Layout helpers: each column contributes its slice of the shared LCD strip, then its controls.

    private func column<L: View, C: View>(width: CGFloat, @ViewBuilder lcd: () -> L, @ViewBuilder controls: () -> C) -> some View {
        VStack(spacing: 14) {
            lcd()
                .frame(width: width, height: lcdHeight)
                .background(Cockpit.lcd)
            VStack(spacing: 0) { controls() }
                .frame(width: width)
        }
    }

    private var separator: some View {
        VStack(spacing: 0) {
            Cockpit.lcd.frame(width: 1.5, height: lcdHeight)
            Rectangle().fill(Cockpit.engraving.opacity(0.75)).frame(width: 1.5, height: 150).padding(.top, 20)
        }
    }

    private func legend(_ s: String, _ on: Bool) -> some View {
        Text(s).font(Cockpit.label(12, heavy: true)).foregroundColor(on && powered ? Cockpit.amber : Cockpit.amber.opacity(0.08)).fixedSize()
    }

    private func field(labels: [(String, Bool)], text: String, ghost: String, managed: String?) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                ForEach(labels.indices, id: \.self) { i in legend(labels[i].0, labels[i].1) }
            }
            HStack(spacing: 4) {
                LCDText(text: text, ghost: ghost, size: 28)
                if let managed {
                    Circle().fill(lit(vars, managed) && powered ? Cockpit.amber : Cockpit.amber.opacity(0.06))
                        .frame(width: 9, height: 9)
                }
            }
        }
    }

    private func knob(_ k: (String, String)) -> some View {
        VStack(spacing: 6) {
            KnurledKnob(size: 62, onStep: { fenix.step(k.0, $0) })
            HStack(spacing: 6) {
                pushPull("PUSH") { fenix.run(FenixA320.dec(k.1)) }
                pushPull("PULL") { fenix.run(FenixA320.inc(k.1)) }
            }
        }
    }

    private func key(_ name: String) -> some View {
        let b = F.buttons[name]
        return BlackKey(label: name, width: name == "A/THR" ? 64 : 52, height: 34, fontSize: 12, bars: lit(vars, b?.light)) { press(name) }
    }

    private func press(_ name: String) {
        if let b = F.buttons[name] { fenix.press(b.sw) }
    }

    private func pushPull(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            action()
        } label: {
            Text(label).font(Cockpit.label(10, heavy: true)).foregroundColor(Cockpit.engraving.opacity(0.85))
                .frame(width: 42, height: 20)
                .background(Capsule().fill(Color.black.opacity(0.4)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private var mach: Bool { lit(vars, F.mach) }
    private var trk: Bool { lit(vars, F.trackFpa) }
    private var powered: Bool { (vars[F.power] ?? 1) > 0.5 && !vars.values.isEmpty }

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
}

// MARK: - Lights and signs (overhead)

/// The overhead's EXT LT, INT LT and SIGNS areas, laid out as on the A320 panel.
private struct LightsPanel: View {
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions

    private func sw(_ title: String) -> FenixA320.Switch? {
        (FenixA320.exteriorLights + FenixA320.signs + FenixA320.interiorLights).first { $0.title == title }
    }

    var body: some View {
        PanelPlate(area: .overhead) {
            HStack(alignment: .top, spacing: 34) {
                VStack(spacing: 16) {
                    GroupHeading(title: "EXT LT")
                    HStack(alignment: .top, spacing: 26) {
                        toggle("STROBE"); toggle("BEACON"); toggle("WING"); toggle("NAV & LOGO")
                    }
                    HStack(alignment: .top, spacing: 26) {
                        toggle("RWY TURN OFF")
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Rectangle().fill(Cockpit.engraving.opacity(0.8)).frame(height: 1.2)
                                Engraved("LAND", size: 11, heavy: true)
                                Rectangle().fill(Cockpit.engraving.opacity(0.8)).frame(height: 1.2)
                            }
                            HStack(alignment: .top, spacing: 22) {
                                toggle("LAND L", title: "L"); toggle("LAND R", title: "R")
                            }
                        }
                        .frame(width: 190)
                        toggle("NOSE")
                    }
                }
                Rectangle().fill(Cockpit.engraving.opacity(0.8)).frame(width: 1.4, height: 330)
                VStack(spacing: 16) {
                    GroupHeading(title: "INT LT")
                    HStack(alignment: .top, spacing: 30) { toggle("DOME"); toggle("ANN LT") }
                    GroupHeading(title: "SIGNS").padding(.top, 6)
                    HStack(alignment: .top, spacing: 24) { toggle("SEAT BELTS"); toggle("NO SMOKING"); toggle("EMER EXIT LT") }
                }
                .frame(width: 330)
            }
        }
    }

    @ViewBuilder private func toggle(_ name: String, title: String? = nil) -> some View {
        if let s = sw(name) {
            BatToggle(title: title ?? s.title, positions: s.positions, value: int(vars, s.v)) { fenix.set(s.v, $0) }
        }
    }
}
