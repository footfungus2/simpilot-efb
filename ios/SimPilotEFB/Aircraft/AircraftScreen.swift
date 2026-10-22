import SwiftUI

/// "Aircraft" module: Fenix A320 controls (radios, transponder/TCAS, FCU, lights) in the EFB's own clean style,
/// plus the VATSIM assistant. Every control shows its value as reported back by the sim; a change is shown as
/// pending until the sim confirms it, and the controls are disabled unless the Fenix is live.
struct AircraftScreen: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient

    var body: some View {
        AircraftPanels(vars: bridge.aircraft, ownship: bridge.ownship, commander: app.fenixCommander)
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var vars: AircraftVars
    @ObservedObject var ownship: OwnshipStore
    @ObservedObject var commander: FenixCommander
    @AppStorage("aircraftPageEFB") private var pageRaw = AircraftPage.radio.rawValue

    private var page: AircraftPage { AircraftPage(rawValue: pageRaw) ?? .radio }
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        // Re-evaluated every second so "no data from the sim" shows up even when nothing else changes.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let link = linkState(now: context.date)
            VStack(spacing: 0) {
                header(link)
                if let n = commander.notice { noticeBar(n) }
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        switch page {
                        case .radio: RadioPage(vars: vars, cmd: commander, compact: compact)
                        case .atc: ATCPage(vars: vars, cmd: commander, compact: compact)
                        case .fcu: FCUPage(vars: vars, cmd: commander, compact: compact)
                        case .lights: LightsPage(vars: vars, cmd: commander, compact: compact)
                        case .vatsim:
                            VatsimAssistantPage(assistant: app.vatsimAssistant, vars: vars, commander: commander,
                                                fenixLive: link.isLive, compact: compact)
                        }
                    }
                    // Fenix pages only work with a live Fenix; the VATSIM page works without it.
                    .disabled(page != .vatsim && !link.isLive)
                    .opacity(page != .vatsim && !link.isLive ? 0.45 : 1)
                    .padding(compact ? 12 : 20)
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(theme.bar)
        .onAppear { bridge.watch(FenixA320.allWatched) }
    }

    private func linkState(now: Date) -> FenixLink {
        FenixLink.evaluate(bridgeConnected: bridge.isConnected,
                           simConnected: bridge.status?.sim.connected == true,
                           aircraftTitle: bridge.status?.sim.aircraftTitle,
                           demoActive: ownship.demoActive,
                           lastSimData: ownship.ownship.map { Date(timeIntervalSince1970: $0.ts / 1000) },
                           hasCockpitValues: !vars.values.isEmpty, now: now)
    }

    @ViewBuilder private func header(_ link: FenixLink) -> some View {
        let picker = Segmented(options: AircraftPage.allCases.map { ($0.rawValue, $0.rawValue) }, value: pageRaw) { pageRaw = $0 }
        if compact {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    title
                    Spacer()
                    statusPill(link)
                }
                picker
            }
            .padding(12)
        } else {
            HStack(spacing: 14) {
                title
                picker.frame(maxWidth: 560)
                Spacer(minLength: 8)
                statusPill(link)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    private var title: some View {
        Text(page == .vatsim ? "VATSIM" : "Fenix A320").font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
            .fixedSize()
    }

    /// Fenix connection state; on the VATSIM page it still tells you whether "Set in Fenix" will work.
    private func statusPill(_ link: FenixLink) -> some View {
        HStack(spacing: 8) {
            Circle().fill(link.isLive ? Theme.okGreen : Theme.warnOrange).frame(width: 8, height: 8)
            Text(link.message).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary)
                .lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(theme.pill))
        .accessibilityElement(children: .combine)
    }

    private func noticeBar(_ n: FenixCommander.Notice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: n.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(n.isError ? Theme.warnOrange : Theme.okGreen)
            Text(n.text).font(.system(size: 14, weight: .medium)).foregroundColor(theme.text)
            Spacer()
            Button { commander.dismissNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(theme.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .background((n.isError ? Theme.warnOrange : Theme.okGreen).opacity(0.14))
        .accessibilityElement(children: .combine)
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
                    .accessibilityAddTraits(.isHeader)
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

/// Side by side when there's room, stacked in compact width (split view, narrow windows).
struct AdaptiveStack<Content: View>: View {
    var compact: Bool
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        if compact {
            VStack(spacing: spacing) { content }
        } else {
            HStack(alignment: .top, spacing: spacing) { content }
        }
    }
}

/// Segmented picker: the selected option is filled blue; a pending target gets a blue outline and a spinner.
struct Segmented<Value: Equatable>: View {
    @Environment(\.theme) private var theme
    var options: [(String, Value)]
    var value: Value?
    var pending: Value? = nil
    var accessibilityName: String? = nil
    var onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (label, v) = options[i]
                let isPending = pending == v && value != v
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    onSelect(v)
                } label: {
                    HStack(spacing: 6) {
                        if isPending { ProgressView().scaleEffect(0.7) }
                        Text(label).font(.system(size: 14, weight: value == v ? .semibold : .regular))
                            .foregroundColor(value == v ? .white : theme.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 8).fill(value == v ? Theme.selectedBlue : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isPending ? Theme.selectedBlue : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityName.map { "\($0): \(label)" } ?? label)
                .accessibilityAddTraits(value == v ? .isSelected : [])
                .accessibilityHint(isPending ? "Waiting for the sim" : "")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.pill))
    }
}

/// Push button with an indicator light (AP1, VHF1, …): green dot and outline when lit, spinner while pending.
struct LightButton: View {
    @Environment(\.theme) private var theme
    var label: String
    var lit = false
    var pending = false
    var minWidth: CGFloat = 64
    var action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 7) {
                if pending {
                    ProgressView().scaleEffect(0.65).frame(width: 8, height: 8)
                } else {
                    Circle().fill(lit ? Theme.okGreen : theme.pillStrong).frame(width: 8, height: 8)
                }
                Text(label).font(.system(size: 14, weight: .semibold)).foregroundColor(theme.text).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(lit ? Theme.okGreen.opacity(0.14) : theme.pill))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(lit ? Theme.okGreen.opacity(0.7) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .accessibilityLabel(label)
        .accessibilityValue(pending ? "waiting for the sim" : (lit ? "on" : "off"))
    }
}

/// Plain action button (44 pt tall by default).
struct ActionButton: View {
    @Environment(\.theme) private var theme
    var label: String
    var systemImage: String? = nil
    var prominent = false
    var pending = false
    var minWidth: CGFloat = 56
    var height: CGFloat = 44
    var accessibilityName: String? = nil
    var action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if pending { ProgressView().scaleEffect(0.75).tint(prominent ? .white : nil) }
                else if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
                if !label.isEmpty { Text(label).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .foregroundColor(prominent ? .white : theme.text)
            .padding(.horizontal, 12)
            .frame(minWidth: minWidth, maxWidth: minWidth == 0 ? .infinity : nil, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 9).fill(prominent ? Theme.selectedBlue : theme.pill))
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .accessibilityLabel(accessibilityName ?? label)
    }
}

/// − / + pair; holding keeps stepping. VoiceOver gets one adjustable element instead of the hold gesture.
private struct StepperPair: View {
    @Environment(\.theme) private var theme
    var caption: String? = nil
    var name: String
    var onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let caption {
                Text(caption).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary).frame(minWidth: 34, alignment: .leading)
            }
            RepeatButton(systemImage: "minus") { onStep(-1) }
            RepeatButton(systemImage: "plus") { onStep(1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityHint("Swipe up or down to adjust")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }
}

/// Steps once on touch, then repeats while held. Always stops on release, when disabled, and when the view goes away.
private struct RepeatButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var systemImage: String
    var action: () -> Void
    @State private var timer: Timer?
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage).font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
            .frame(width: 52, height: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(pressed ? theme.pillStrong : theme.pill))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed, isEnabled else { return }
                    pressed = true
                    fire()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                        Task { @MainActor in
                            guard pressed else { return }
                            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                                Task { @MainActor in fire() }
                            }
                        }
                    }
                }
                .onEnded { _ in stop() })
            .onDisappear { stop() }
            .onChange(of: isEnabled) { if !$0 { stop() } }
    }

    private func stop() {
        pressed = false
        timer?.invalidate()
        timer = nil
    }

    private func fire() {
        guard pressed, isEnabled else { return }
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Radio

private struct RadioPage: View {
    @ObservedObject var vars: AircraftVars
    let cmd: FenixCommander
    let compact: Bool

    var body: some View {
        AdaptiveStack(compact: compact) {
            RMPCard(rmp: FenixA320.rmp1, vars: vars, cmd: cmd)
            RMPCard(rmp: FenixA320.rmp2, vars: vars, cmd: cmd)
        }
    }
}

private struct RMPCard: View {
    @Environment(\.theme) private var theme
    let rmp: FenixA320.RMP
    @ObservedObject var vars: AircraftVars
    @ObservedObject var cmd: FenixCommander
    @State private var entering = false
    @State private var typed = ""

    private var powered: Bool { (vars[rmp.power] ?? 1) > 0.5 }
    private var tuning: Bool { cmd.isPending("tune\(rmp.n)") }

    var body: some View {
        Card(title: "Radio \(rmp.n)") {
            HStack(spacing: 6) {
                if cmd.isPending(rmp.power) { ProgressView().scaleEffect(0.7) }
                Toggle("Radio \(rmp.n) power", isOn: Binding(get: { powered }, set: { cmd.set(rmp.power, $0 ? 1 : 0, label: "Radio \(rmp.n) power") }))
                    .labelsHidden()
            }
        } content: {
            HStack(alignment: .center, spacing: 12) {
                Readout(caption: "Active", value: powered ? FenixA320.frequency(vars[rmp.active]) : "", color: Theme.okGreen)
                Spacer(minLength: 4)
                ActionButton(label: "", systemImage: "arrow.left.arrow.right", prominent: true, pending: cmd.isPending(rmp.transfer),
                             minWidth: 56, height: 48, accessibilityName: "Swap active and standby frequencies on radio \(rmp.n)") {
                    cmd.press(rmp.transfer, label: "Radio \(rmp.n) transfer")
                }
                Spacer(minLength: 4)
                Button { typed = ""; entering = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Standby").font(.system(size: 12, weight: .medium)).foregroundColor(theme.textSecondary)
                            Image(systemName: "keyboard").font(.system(size: 11)).foregroundColor(Theme.ownshipBlue)
                        }
                        HStack(spacing: 6) {
                            Text(powered ? FenixA320.frequency(vars[rmp.standby]) : "–")
                                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundColor(Theme.ownshipBlue).lineLimit(1).minimumScaleFactor(0.6)
                            if tuning { ProgressView() }
                        }
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Standby frequency \(FenixA320.frequency(vars[rmp.standby]))")
                .accessibilityHint("Double tap to type a new standby frequency")
                .popover(isPresented: $entering) { entry }
            }
            HStack(spacing: 16) {
                StepperPair(caption: "MHz", name: "Radio \(rmp.n) standby MHz") { cmd.step(rmp.outer, $0, label: "Radio \(rmp.n) MHz knob") }
                StepperPair(caption: "kHz", name: "Radio \(rmp.n) standby kHz") { cmd.step(rmp.inner, $0, label: "Radio \(rmp.n) kHz knob") }
            }
            .disabled(tuning)
            Rectangle().fill(theme.separator).frame(height: 1)
            keyGrid(rmp.comKeys)
            Text("STANDBY NAV").font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary).padding(.top, 2)
            keyGrid(rmp.navKeys)
        }
    }

    /// Typed standby frequency; the bridge turns the knobs and reads the window back after every click.
    private var entry: some View {
        let khz = FrequencyInput.khz(typed)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Radio \(rmp.n) standby").font(.system(size: 15, weight: .semibold)).foregroundColor(theme.text)
            TextField("121.800", text: $typed, onCommit: { load(khz) })
                .keyboardType(.decimalPad)
                .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .padding(.horizontal, 12).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 9).fill(theme.pill))
            Text(typed.isEmpty || khz != nil ? "118.000 to 136.990" : "Not a VHF frequency")
                .font(.system(size: 13)).foregroundColor(typed.isEmpty || khz != nil ? theme.textSecondary : Theme.warnOrange)
            ActionButton(label: "Load into standby", prominent: true, minWidth: 0) { load(khz) }
                .disabled(khz == nil)
                .opacity(khz == nil ? 0.5 : 1)
        }
        .padding(18)
        .frame(width: 300)
    }

    private func load(_ khz: Int?) {
        guard let khz else { return }
        entering = false
        cmd.tune(rmp: rmp.n, khz: khz)
    }

    private func keyGrid(_ keys: [(label: String, sw: String, light: String, counter: Bool)]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(keys, id: \.label) { k in
                LightButton(label: k.label, lit: lit(vars, k.light), pending: cmd.isPending(k.sw), minWidth: 0) {
                    cmd.press(k.sw, counter: k.counter, label: "Radio \(rmp.n) \(k.label)")
                }
            }
        }
    }
}

// MARK: - ATC / TCAS

private struct ATCPage: View {
    @Environment(\.theme) private var theme
    @ObservedObject var vars: AircraftVars
    @ObservedObject var cmd: FenixCommander
    let compact: Bool
    typealias A = FenixA320.ATC

    var body: some View {
        AdaptiveStack(compact: compact) {
            Card(title: "Transponder") {
                HStack(alignment: .firstTextBaseline) {
                    Readout(caption: "Squawk", value: code, size: 48)
                    if cmd.isPending("squawk") { ProgressView() }
                    Spacer()
                    if lit(vars, A.fail) {
                        Text("ATC FAIL").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.warnOrange)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach([1, 2, 3, 4, 5, 6, 7, 0], id: \.self) { d in
                        ActionButton(label: "\(d)", pending: cmd.isPending(A.digit(d)), minWidth: 0, height: 52) {
                            cmd.press(A.digit(d), label: "Transponder key \(d)")
                        }
                    }
                }
                .disabled(cmd.isPending("squawk"))
                HStack(spacing: 10) {
                    ActionButton(label: "CLR", pending: cmd.isPending(A.clear), minWidth: 0, height: 48) { cmd.press(A.clear, label: "Transponder CLR") }
                    ActionButton(label: "IDENT", prominent: true, pending: cmd.isPending(A.ident), minWidth: 0, height: 48) { cmd.press(A.ident, label: "IDENT") }
                }
            }
            .frame(maxWidth: compact ? .infinity : 420)
            VStack(spacing: 16) {
                Card(title: "Transponder mode") {
                    picker("Transponder mode", A.operation, [("STBY", 0), ("AUTO", 1), ("ON", 2)])
                    row("Altitude reporting") { picker("Altitude reporting", A.altReporting, [("OFF", 0), ("ON", 1)]) }
                    row("System") { picker("Transponder system", A.system, [("1", 0), ("2", 1)]) }
                }
                Card(title: "TCAS") {
                    picker("TCAS mode", A.tcasMode, [("STBY", 0), ("TA", 1), ("TA/RA", 2)])
                    row("Traffic") { picker("TCAS traffic", A.traffic, [("THRT", 0), ("ALL", 1), ("ABV", 2), ("BLW", 3)]) }
                }
            }
        }
    }

    private func picker(_ name: String, _ v: String, _ options: [(String, Int)]) -> some View {
        Segmented(options: options, value: int(vars, v), pending: cmd.pendingTargets[v], accessibilityName: name) {
            cmd.set(v, $0, label: name)
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15)).foregroundColor(theme.text).fixedSize()
            Spacer(minLength: 8)
            control().frame(maxWidth: 260)
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
    @ObservedObject var cmd: FenixCommander
    let compact: Bool
    typealias F = FenixA320.FCU

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: compact ? 1 : 2), spacing: 16) {
                target(mach ? "Mach" : "Speed", value: speedText, managed: F.speedManaged, knob: F.speedKnob) {
                    button("SPD MACH", title: "SPD / MACH")
                }
                target(trk ? "Track" : "Heading", value: headingText, managed: F.headingManaged, knob: F.headingKnob) {
                    button("HDG V/S TRK FPA", title: "HDG / TRK")
                }
                target("Altitude", value: altitudeText, managed: F.altitudeManaged, knob: F.altitudeKnob) {
                    Segmented(options: [("100", 0), ("1000", 1)], value: int(vars, F.altitudeScale),
                              pending: cmd.pendingTargets[F.altitudeScale], accessibilityName: "Altitude step") {
                        cmd.set(F.altitudeScale, $0, label: "Altitude step")
                    }
                    .frame(maxWidth: 150)
                }
                target(trk ? "Flight path angle" : "Vertical speed", value: vsText, managed: nil, knob: F.vsKnob) {
                    button("METRIC ALT", title: "METRIC ALT")
                }
            }
            Card(title: "Autoflight") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: compact ? 3 : 6), spacing: 10) {
                    ForEach(["AP1", "AP2", "A/THR", "LOC", "APPR", "EXPED"], id: \.self) { name in
                        let b = F.buttons[name]
                        LightButton(label: name, lit: lit(vars, b?.light), pending: b.map { cmd.isPending($0.sw) } ?? false, minWidth: 0) {
                            if let b { cmd.press(b.sw, label: name) }
                        }
                    }
                }
            }
        }
    }

    private func button(_ key: String, title: String) -> some View {
        let b = F.buttons[key]
        return ActionButton(label: title, pending: b.map { cmd.isPending($0.sw) } ?? false, minWidth: 110) {
            if let b { cmd.press(b.sw, label: title) }
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
                    .accessibilityLabel("\(title) \(value)")
                Spacer()
                StepperPair(name: "\(title) knob") { cmd.step(knob.0, $0, label: "\(title) knob") }
            }
            HStack(spacing: 8) {
                ActionButton(label: "Push", pending: cmd.isPending(knob.1 + ".push"), minWidth: 70, accessibilityName: "Push \(title) knob (managed)") {
                    cmd.send(FenixA320.dec(knob.1), key: knob.1 + ".push", label: "Push \(title)")
                }
                ActionButton(label: "Pull", pending: cmd.isPending(knob.1 + ".pull"), minWidth: 70, accessibilityName: "Pull \(title) knob (selected)") {
                    cmd.send(FenixA320.inc(knob.1), key: knob.1 + ".pull", label: "Pull \(title)")
                }
                Spacer(minLength: 4)
                extra()
            }
        }
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
    @ObservedObject var cmd: FenixCommander
    let compact: Bool

    var body: some View {
        AdaptiveStack(compact: compact) {
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
                    Text(title(s.title)).font(.system(size: 15)).foregroundColor(theme.text).lineLimit(2).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    // Panel order is top → bottom (ON first); read left → right as OFF … ON.
                    Segmented(options: s.positions.reversed().map { ($0.label, $0.value) }, value: int(vars, s.v),
                              pending: cmd.pendingTargets[s.v], accessibilityName: title(s.title)) {
                        cmd.set(s.v, $0, label: title(s.title))
                    }
                    .frame(maxWidth: CGFloat(s.positions.count) * 72)
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
