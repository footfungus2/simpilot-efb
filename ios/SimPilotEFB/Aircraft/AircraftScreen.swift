import SwiftUI

/// "Aircraft" module: Fenix A320 controls (radios, transponder/TCAS, FCU, lights) in the EFB's own clean style,
/// driven through the bridge. Values come back from the sim, so the controls stay in sync with whatever is
/// flipped in the virtual cockpit.
struct AircraftScreen: View {
    @EnvironmentObject private var bridge: BridgeClient

    var body: some View {
        AircraftPanels(vars: bridge.aircraft)
    }
}

private enum AircraftPage: String, CaseIterable, Identifiable {
    case radio = "Radio", atc = "ATC / TCAS", fcu = "Autopilot", lights = "Lights", vatsim = "VATSIM"
    var id: String { rawValue }
}

private struct AircraftPanels: View {
    @EnvironmentObject private var bridge: BridgeClient
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @ObservedObject var vars: AircraftVars
    @AppStorage("aircraftPageEFB") private var pageRaw = AircraftPage.radio.rawValue

    private var page: AircraftPage { AircraftPage(rawValue: pageRaw) ?? .radio }
    private var fenix: FenixActions { FenixActions(bridge: bridge) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch page {
                    case .radio: RadioPage(vars: vars, fenix: fenix)
                    case .atc: ATCPage(vars: vars, fenix: fenix)
                    case .fcu: FCUPage(vars: vars, fenix: fenix)
                    case .lights: LightsPage(vars: vars, fenix: fenix)
                    case .vatsim: VatsimAssistantPage(assistant: app.vatsimAssistant, vars: vars)
                    }
                }
                .padding(20)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.bar)
        .onAppear { bridge.watch(FenixA320.allWatched) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(page == .vatsim ? "VATSIM" : "Fenix A320").font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
                .frame(width: 100, alignment: .leading)
            Segmented(options: AircraftPage.allCases.map { ($0.rawValue, $0.rawValue) }, value: pageRaw) { pageRaw = $0 }
                .frame(width: 520)
            Spacer()
            statusPill
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// Why the controls might not respond: no bridge, no sim, or a different aircraft loaded.
    private var statusPill: some View {
        let title = bridge.status?.sim.aircraftTitle ?? ""
        let (text, color): (String, Color) = {
            if !bridge.isConnected { return ("PC bridge not connected", Theme.warnOrange) }
            if bridge.status?.sim.connected != true { return ("MSFS not running", Theme.warnOrange) }
            if !title.lowercased().contains("fenix") && !title.lowercased().contains("a320") {
                return ("Load the Fenix A320 · now: \(title.isEmpty ? "unknown" : title)", Theme.warnOrange)
            }
            return (vars.values.isEmpty ? "Connecting…" : "Live", Theme.okGreen)
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(theme.pill))
    }
}

/// Sends Fenix commands through the bridge.
@MainActor
struct FenixActions {
    let bridge: BridgeClient

    func run(_ code: String) { bridge.run(code) }
    func set(_ v: String, _ n: Int) { bridge.run(FenixA320.set(v, n)) }
    func step(_ v: String, _ dir: Int) { bridge.run(dir > 0 ? FenixA320.inc(v) : FenixA320.dec(v)) }

    /// Types a squawk on the transponder keypad, one key at a time.
    func squawk(_ code: String) {
        let digits = code.compactMap { Int(String($0)) }.filter { (0...7).contains($0) }
        guard digits.count == 4 else { return }
        let fenix = self
        Task { @MainActor in
            for d in digits {
                fenix.press(FenixA320.ATC.digit(d))
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

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

// MARK: - Building blocks (EFB style)

/// Rounded card with a small caption title, like the EFB's info cards.
struct Card<Content: View, Accessory: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundColor(theme.textSecondary).tracking(0.6)
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.sidebar))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Segmented picker: the selected option is filled blue.
struct Segmented<Value: Equatable>: View {
    @Environment(\.theme) private var theme
    var options: [(String, Value)]
    var value: Value?
    var onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (label, v) = options[i]
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    onSelect(v)
                } label: {
                    Text(label).font(.system(size: 14, weight: value == v ? .semibold : .regular))
                        .foregroundColor(value == v ? .white : theme.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(value == v ? Theme.selectedBlue : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.pill))
    }
}

/// Push button with an indicator light (AP1, VHF1, …): green dot and outline when lit.
struct LightButton: View {
    @Environment(\.theme) private var theme
    var label: String
    var lit = false
    var minWidth: CGFloat = 64
    var action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 7) {
                Circle().fill(lit ? Theme.okGreen : theme.pillStrong).frame(width: 8, height: 8)
                Text(label).font(.system(size: 14, weight: .semibold)).foregroundColor(theme.text).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 9).fill(lit ? Theme.okGreen.opacity(0.14) : theme.pill))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(lit ? Theme.okGreen.opacity(0.7) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// Plain action button.
struct ActionButton: View {
    @Environment(\.theme) private var theme
    var label: String
    var systemImage: String? = nil
    var prominent = false
    var minWidth: CGFloat = 56
    var height: CGFloat = 40
    var action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
                if !label.isEmpty { Text(label).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .foregroundColor(prominent ? .white : theme.text)
            .padding(.horizontal, 12)
            .frame(minWidth: minWidth, maxWidth: minWidth == 0 ? .infinity : nil, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 9).fill(prominent ? Theme.selectedBlue : theme.pill))
        }
        .buttonStyle(.plain)
    }
}

/// − / + stepper; holding a side keeps stepping.
private struct StepperPair: View {
    @Environment(\.theme) private var theme
    var caption: String? = nil
    var onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let caption {
                Text(caption).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary).frame(minWidth: 34, alignment: .leading)
            }
            RepeatButton(systemImage: "minus") { onStep(-1) }
            RepeatButton(systemImage: "plus") { onStep(1) }
        }
    }
}

private struct RepeatButton: View {
    @Environment(\.theme) private var theme
    var systemImage: String
    var action: () -> Void
    @State private var timer: Timer?
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage).font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
            .frame(width: 52, height: 40)
            .background(RoundedRectangle(cornerRadius: 9).fill(pressed ? theme.pillStrong : theme.pill))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    fire()
                    // After a short hold, keep stepping.
                    timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                        Task { @MainActor in
                            guard pressed else { return }
                            timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in
                                Task { @MainActor in fire() }
                            }
                        }
                    }
                }
                .onEnded { _ in
                    pressed = false
                    timer?.invalidate()
                    timer = nil
                })
    }

    private func fire() {
        UISelectionFeedbackGenerator().selectionChanged()
        action()
    }
}

/// Big readout for a value (frequency, squawk).
struct Readout: View {
    @Environment(\.theme) private var theme
    var caption: String
    var value: String
    var color: Color? = nil
    var size: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 12, weight: .medium)).foregroundColor(theme.textSecondary)
            Text(value.isEmpty ? "–" : value)
                .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundColor(color ?? theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

// MARK: - Radio

private struct RadioPage: View {
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RMPCard(rmp: FenixA320.rmp1, vars: vars, fenix: fenix)
            RMPCard(rmp: FenixA320.rmp2, vars: vars, fenix: fenix)
        }
    }
}

private struct RMPCard: View {
    @Environment(\.theme) private var theme
    let rmp: FenixA320.RMP
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions

    private var powered: Bool { (vars[rmp.power] ?? 1) > 0.5 }

    var body: some View {
        Card(title: "Radio \(rmp.n)") {
            Toggle("", isOn: Binding(get: { powered }, set: { fenix.set(rmp.power, $0 ? 1 : 0) }))
                .labelsHidden()
        } content: {
            HStack(alignment: .center, spacing: 12) {
                Readout(caption: "Active", value: powered ? FenixA320.frequency(vars[rmp.active]) : "", color: Theme.okGreen)
                Spacer(minLength: 4)
                ActionButton(label: "", systemImage: "arrow.left.arrow.right", prominent: true, minWidth: 54, height: 46) { fenix.press(rmp.transfer) }
                Spacer(minLength: 4)
                Readout(caption: "Standby", value: powered ? FenixA320.frequency(vars[rmp.standby]) : "", color: Theme.ownshipBlue)
            }
            HStack(spacing: 16) {
                StepperPair(caption: "MHz") { fenix.step(rmp.outer, $0) }
                StepperPair(caption: "kHz") { fenix.step(rmp.inner, $0) }
            }
            Rectangle().fill(theme.separator).frame(height: 1)
            keyGrid(rmp.comKeys)
            Text("STANDBY NAV").font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary).padding(.top, 2)
            keyGrid(rmp.navKeys)
        }
    }

    private func keyGrid(_ keys: [(label: String, sw: String, light: String, counter: Bool)]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(keys, id: \.label) { k in
                LightButton(label: k.label, lit: lit(vars, k.light), minWidth: 0) { fenix.press(k.sw, counter: k.counter) }
            }
        }
    }
}

// MARK: - ATC / TCAS

private struct ATCPage: View {
    @Environment(\.theme) private var theme
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions
    typealias A = FenixA320.ATC

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Transponder") {
                HStack(alignment: .firstTextBaseline) {
                    Readout(caption: "Squawk", value: code, size: 48)
                    Spacer()
                    if lit(vars, A.fail) {
                        Text("ATC FAIL").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.warnOrange)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach([1, 2, 3, 4, 5, 6, 7, 0], id: \.self) { d in
                        ActionButton(label: "\(d)", minWidth: 0, height: 52) { fenix.press(A.digit(d)) }
                    }
                }
                HStack(spacing: 10) {
                    ActionButton(label: "CLR", minWidth: 0, height: 48) { fenix.press(A.clear) }
                    ActionButton(label: "IDENT", prominent: true, minWidth: 0, height: 48) { fenix.press(A.ident) }
                }
            }
            .frame(width: 400)
            VStack(spacing: 16) {
                Card(title: "Transponder mode") {
                    Segmented(options: [("STBY", 0), ("AUTO", 1), ("ON", 2)], value: int(vars, A.operation)) { fenix.set(A.operation, $0) }
                    row("Altitude reporting") {
                        Segmented(options: [("OFF", 0), ("ON", 1)], value: int(vars, A.altReporting)) { fenix.set(A.altReporting, $0) }
                    }
                    row("System") {
                        Segmented(options: [("1", 0), ("2", 1)], value: int(vars, A.system)) { fenix.set(A.system, $0) }
                    }
                }
                Card(title: "TCAS") {
                    Segmented(options: [("STBY", 0), ("TA", 1), ("TA/RA", 2)], value: int(vars, A.tcasMode)) { fenix.set(A.tcasMode, $0) }
                    row("Traffic") {
                        Segmented(options: [("THRT", 0), ("ALL", 1), ("ABV", 2), ("BLW", 3)], value: int(vars, A.traffic)) { fenix.set(A.traffic, $0) }
                    }
                }
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15)).foregroundColor(theme.text)
            Spacer()
            control().frame(width: 240)
        }
    }

    private var code: String {
        guard let v = vars[A.code] else { return "" }
        return String(format: "%04d", Int(v.rounded()))
    }
}

// MARK: - Autopilot (FCU)

private struct FCUPage: View {
    @Environment(\.theme) private var theme
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions
    typealias F = FenixA320.FCU

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                target(mach ? "Mach" : "Speed", value: speedText, managed: F.speedManaged, knob: F.speedKnob) {
                    ActionButton(label: "SPD / MACH", minWidth: 120) { press("SPD MACH") }
                }
                target(trk ? "Track" : "Heading", value: headingText, managed: F.headingManaged, knob: F.headingKnob) {
                    ActionButton(label: "HDG / TRK", minWidth: 120) { press("HDG V/S TRK FPA") }
                }
                target("Altitude", value: altitudeText, managed: F.altitudeManaged, knob: F.altitudeKnob) {
                    Segmented(options: [("100", 0), ("1000", 1)], value: int(vars, F.altitudeScale)) { fenix.set(F.altitudeScale, $0) }
                        .frame(width: 140)
                }
                target(trk ? "Flight path angle" : "Vertical speed", value: vsText, managed: nil, knob: F.vsKnob) {
                    ActionButton(label: "METRIC ALT", minWidth: 120) { press("METRIC ALT") }
                }
            }
            Card(title: "Autoflight") {
                HStack(spacing: 10) {
                    ForEach(["AP1", "AP2", "A/THR", "LOC", "APPR", "EXPED"], id: \.self) { name in
                        LightButton(label: name, lit: lit(vars, F.buttons[name]?.light), minWidth: 0) { press(name) }
                    }
                }
            }
        }
    }

    private func target<Extra: View>(_ title: String, value: String, managed: String?, knob: (String, String), @ViewBuilder extra: () -> Extra) -> some View {
        let isManaged = managed.map { lit(vars, $0) } ?? false
        return Card(title: title) {
            if isManaged {
                Text("MANAGED").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.okGreen)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.okGreen.opacity(0.15)))
            }
        } content: {
            HStack(alignment: .center) {
                Text(value.isEmpty ? "–" : value)
                    .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundColor(isManaged ? Theme.okGreen : Theme.ownshipBlue)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                StepperPair { fenix.step(knob.0, $0) }
            }
            HStack(spacing: 8) {
                ActionButton(label: "Push", minWidth: 70) { fenix.run(FenixA320.dec(knob.1)) }
                ActionButton(label: "Pull", minWidth: 70) { fenix.run(FenixA320.inc(knob.1)) }
                Spacer()
                extra()
            }
        }
    }

    private func press(_ name: String) {
        if let b = F.buttons[name] { fenix.press(b.sw) }
    }

    private var mach: Bool { lit(vars, F.mach) }
    private var trk: Bool { lit(vars, F.trackFpa) }
    private var powered: Bool { (vars[F.power] ?? 1) > 0.5 }

    private var speedText: String {
        guard powered, let v = vars[F.speed] else { return "" }
        if lit(vars, F.speedDashed) { return "– – –" }
        return mach ? String(format: "M .%02d", Int((v * 100).rounded()) % 100) : "\(Int(v.rounded())) kt"
    }

    private var headingText: String {
        guard powered, let v = vars[F.heading] else { return "" }
        return lit(vars, F.headingDashed) ? "– – –" : String(format: "%03d°", Int(v.rounded()) % 360)
    }

    private var altitudeText: String {
        guard powered, let v = vars[F.altitude] else { return "" }
        let ft = Int(v.rounded())
        return ft >= 10_000 ? "FL\(ft / 100)" : "\(ft) ft"
    }

    private var vsText: String {
        guard powered, let v = vars[F.vs] else { return "" }
        if lit(vars, F.vsDashed) { return "– – –" }
        if trk { return String(format: "%+.1f°", v) }
        return String(format: "%+d fpm", Int(v.rounded()))
    }
}

// MARK: - Lights and signs

private struct LightsPage: View {
    @Environment(\.theme) private var theme
    @ObservedObject var vars: AircraftVars
    let fenix: FenixActions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Exterior lights") { rows(FenixA320.exteriorLights) }
            VStack(spacing: 16) {
                Card(title: "Signs") { rows(FenixA320.signs) }
                Card(title: "Interior") { rows(FenixA320.interiorLights) }
            }
        }
    }

    private func rows(_ list: [FenixA320.Switch]) -> some View {
        VStack(spacing: 10) {
            ForEach(list, id: \.v) { s in
                HStack(spacing: 12) {
                    Text(title(s.title)).font(.system(size: 15)).foregroundColor(theme.text).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    // Panel order is top → bottom (ON first); read left → right as OFF … ON.
                    Segmented(options: s.positions.reversed().map { ($0.label, $0.value) }, value: int(vars, s.v)) { fenix.set(s.v, $0) }
                        .frame(width: CGFloat(s.positions.count) * 70)
                }
            }
        }
    }

    private func title(_ s: String) -> String {
        switch s {
        case "LAND L": return "Landing left"
        case "LAND R": return "Landing right"
        case "NAV & LOGO": return "Nav & logo"
        case "RWY TURN OFF": return "Runway turn off"
        case "ANN LT": return "Annunciator lights"
        case "EMER EXIT LT": return "Emergency exit"
        default: return s.capitalized
        }
    }
}
