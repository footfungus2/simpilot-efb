import SwiftUI

/// Building blocks drawn after photos of real A320 panels: glareshield (FCU), pedestal (RMP, ATC/TCAS) and
/// overhead (lights) plates, LCD windows, black keys with green annunciators, silver knurled knobs, round
/// pushbuttons, bat-handle toggle switches on chrome nuts and pointer selectors.
enum Cockpit {
    enum Area {
        case glareshield, pedestal, overhead

        var plate: Color {
            switch self {
            case .glareshield: return Color(hex: 0x2E3237)
            case .pedestal: return Color(hex: 0x4D5B6B)
            case .overhead: return Color(hex: 0x6C7F94)
            }
        }

        var plateDark: Color {
            switch self {
            case .glareshield: return Color(hex: 0x25282C)
            case .pedestal: return Color(hex: 0x435060)
            case .overhead: return Color(hex: 0x617488)
            }
        }
    }

    static let engraving = Color(hex: 0xF2F2EE)
    static let amber = Color(hex: 0xFF9A1F)
    static let green = Color(hex: 0x37E26A)
    static let key = Color(hex: 0x15171A)
    static let lcd = Color(hex: 0x0A0B0C)

    static func segment(_ size: CGFloat) -> Font { .custom("DSEG7Classic-Bold", size: size) }
    /// Airbus panel lettering is a condensed sans; Avenir Next Condensed ships with iOS 15.
    static func label(_ size: CGFloat = 11, heavy: Bool = false) -> Font {
        .custom(heavy ? "AvenirNextCondensed-Bold" : "AvenirNextCondensed-DemiBold", size: size)
    }
}

/// Engraved panel text.
struct Engraved: View {
    var text: String
    var size: CGFloat = 11
    var heavy = false
    var color: Color = Cockpit.engraving

    init(_ text: String, size: CGFloat = 11, heavy: Bool = false, color: Color = Cockpit.engraving) {
        self.text = text
        self.size = size
        self.heavy = heavy
        self.color = color
    }

    var body: some View {
        Text(text).font(Cockpit.label(size, heavy: heavy)).foregroundColor(color).fixedSize()
    }
}

/// A cockpit panel plate with screws in the corners.
struct PanelPlate<Content: View>: View {
    var area: Cockpit.Area
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 26).padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [area.plate, area.plateDark], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.07), lineWidth: 1).padding(1.5))
                    .shadow(color: .black.opacity(0.55), radius: 8, y: 4)
            )
            .overlay(screws)
    }

    private var screws: some View {
        GeometryReader { g in
            ForEach(0..<4, id: \.self) { i in
                Screw().position(x: i % 2 == 0 ? 10 : g.size.width - 10, y: i < 2 ? 10 : g.size.height - 10)
            }
        }
        .allowsHitTesting(false)
    }
}

struct Screw: View {
    var size: CGFloat = 9

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.82), Color(white: 0.38)], center: .topLeading, startRadius: 0, endRadius: size))
            Rectangle().fill(Color.black.opacity(0.55)).frame(width: size * 0.75, height: 1.3).rotationEffect(.degrees(40))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 0.5, y: 0.5)
    }
}

/// Group heading as engraved on the overhead: title centred on a white line, with short drops at both ends.
struct GroupHeading: View {
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            line
            Engraved(title, size: 14, heavy: true)
            line
        }
    }

    private var line: some View {
        Rectangle().fill(Cockpit.engraving.opacity(0.85)).frame(height: 1.4)
    }
}

/// LCD window: amber 7-segment digits; unlit segments show faintly like the real displays.
struct LCDText: View {
    var text: String
    var ghost: String
    var size: CGFloat = 30
    var color: Color = Cockpit.amber

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(ghost).foregroundColor(color.opacity(0.06))
            Text(text).foregroundColor(color).shadow(color: color.opacity(0.55), radius: 4)
        }
        .font(Cockpit.segment(size))
        .lineLimit(1)
        .fixedSize()
    }
}

/// LCD in a screwed bezel (RMP and ATC windows).
struct BezelLCD: View {
    var text: String
    var ghost: String
    var size: CGFloat = 30

    var body: some View {
        LCDText(text: text, ghost: ghost, size: size)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 3).fill(Cockpit.lcd))
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0x2A3038))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.7)))
            )
            .overlay(GeometryReader { g in
                ForEach(0..<4, id: \.self) { i in
                    Screw(size: 6).position(x: i % 2 == 0 ? 6 : g.size.width - 6, y: i < 2 ? 6 : g.size.height - 6)
                }
            })
    }
}

/// Black key with white legend. `bars` draws the FCU-style green annunciator inside the key;
/// `led` draws the RMP-style green light above it, over a small engraved ▼.
struct BlackKey: View {
    var label: String
    var width: CGFloat = 54
    var height: CGFloat = 32
    var fontSize: CGFloat = 13
    var bars: Bool? = nil
    var led: Bool? = nil
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 3) {
            if let led {
                ZStack {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 6)).foregroundColor(Cockpit.engraving.opacity(0.75))
                        .offset(y: 3)
                    Capsule().fill(led ? Cockpit.green : .clear).frame(width: 9, height: 4)
                        .shadow(color: led ? Cockpit.green : .clear, radius: 4).offset(y: -3)
                }
                .frame(height: 12)
            }
            VStack(spacing: 3) {
                if let bars {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule().fill(bars ? Cockpit.green : Color.white.opacity(0.08)).frame(width: 8, height: 3)
                        }
                    }
                    .shadow(color: bars ? Cockpit.green : .clear, radius: 3)
                }
                Text(label).font(Cockpit.label(fontSize, heavy: true)).foregroundColor(Cockpit.engraving)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(hex: 0x24272B), Cockpit.key], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(pressed ? 0.15 : 0.75), radius: pressed ? 0.5 : 2.5, y: pressed ? 0 : 2)
            )
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.08)))
            .scaleEffect(pressed ? 0.95 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        pressed = true
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
    }
}

/// Small round pushbutton in a chrome ring (SPD MACH, HDG-V/S TRK-FPA, METRIC ALT, IDENT).
struct RoundButton: View {
    var label: String? = nil
    var size: CGFloat = 30
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().fill(RadialGradient(colors: [Color(hex: 0x2B2E32), Color(hex: 0x070808)], center: .topLeading, startRadius: 1, endRadius: size))
                    .padding(3)
            }
            .frame(width: size, height: size)
            .scaleEffect(pressed ? 0.92 : 1)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
            if let label {
                Text(label).font(Cockpit.label(10, heavy: true)).foregroundColor(Cockpit.engraving)
                    .multilineTextAlignment(.center).fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            pressed = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
        }
    }
}

/// Silver knurled knob (FCU, RMP). Drag around it (or up/down) to turn; tap the left/right half for one step.
/// With `inner`, the silver cap is a second concentric knob (RMP kHz).
struct KnurledKnob: View {
    var size: CGFloat = 64
    var onStep: (Int) -> Void
    var inner: ((Int) -> Void)? = nil

    @State private var outerAngle: Double = 0
    @State private var innerAngle: Double = 0
    @State private var lastAngle: Double?
    @State private var accumulated: Double = 0
    @State private var draggingInner = false

    private let degreesPerStep = 22.0
    private var innerRadius: CGFloat { size * (inner == nil ? 0.31 : 0.3) }

    var body: some View {
        ZStack {
            // Outer knurled ring.
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(hex: 0x5E646B), Color(hex: 0x1C1E21)], center: .topLeading, startRadius: 2, endRadius: size))
                ForEach(0..<40, id: \.self) { i in
                    Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1.2, height: size * 0.11)
                        .offset(y: -size * 0.445).rotationEffect(.degrees(Double(i) * 9))
                }
            }
            .rotationEffect(.degrees(outerAngle))
            // Silver cap.
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.96), Color(white: 0.62)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: innerRadius * 1.6))
                Circle().stroke(Color(white: 0.45), lineWidth: 1)
                if inner != nil {
                    ForEach(0..<24, id: \.self) { i in
                        Rectangle().fill(Color.black.opacity(0.18)).frame(width: 1, height: innerRadius * 0.25)
                            .offset(y: -innerRadius * 0.85).rotationEffect(.degrees(Double(i) * 15))
                    }
                }
            }
            .frame(width: innerRadius * 2, height: innerRadius * 2)
            .rotationEffect(.degrees(inner == nil ? outerAngle : innerAngle))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1.5)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
        .contentShape(Circle())
        .gesture(drag)
        .simultaneousGesture(TapWithLocation { location in
            let c = CGPoint(x: size / 2, y: size / 2)
            let isInner = inner != nil && hypot(location.x - c.x, location.y - c.y) < innerRadius
            step(location.x < c.x ? -1 : 1, inner: isInner)
        })
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let c = CGPoint(x: size / 2, y: size / 2)
                if lastAngle == nil {
                    draggingInner = inner != nil && hypot(v.startLocation.x - c.x, v.startLocation.y - c.y) < innerRadius
                }
                let a = atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi
                if let last = lastAngle {
                    var d = a - last
                    if d > 180 { d -= 360 }
                    if d < -180 { d += 360 }
                    accumulated += d
                    if draggingInner { innerAngle += d } else { outerAngle += d }
                    while accumulated >= degreesPerStep { accumulated -= degreesPerStep; fire(1) }
                    while accumulated <= -degreesPerStep { accumulated += degreesPerStep; fire(-1) }
                }
                lastAngle = a
            }
            .onEnded { _ in lastAngle = nil; accumulated = 0 }
    }

    private func step(_ dir: Int, inner isInner: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if isInner { innerAngle += Double(dir) * degreesPerStep } else { outerAngle += Double(dir) * degreesPerStep }
        }
        UISelectionFeedbackGenerator().selectionChanged()
        if isInner { inner?(dir) } else { onStep(dir) }
    }

    private func fire(_ dir: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        if draggingInner { inner?(dir) } else { onStep(dir) }
    }
}

/// iOS 15 has no SpatialTapGesture: a zero-distance drag that ends where it started acts as a tap with a location.
struct TapWithLocation: Gesture {
    var action: (CGPoint) -> Void
    init(_ action: @escaping (CGPoint) -> Void) { self.action = action }

    var body: some Gesture {
        DragGesture(minimumDistance: 0).onEnded { v in
            if hypot(v.translation.width, v.translation.height) < 4 { action(v.location) }
        }
    }
}

/// Bat-handle toggle on a chrome nut, as on the A320 overhead and pedestal. Positions are top → bottom; the top
/// legend sits above the switch, the bottom one below, a middle one to the right. Tap a legend, or the upper/lower
/// half of the switch, to move it.
struct BatToggle: View {
    var title: String? = nil
    var positions: [(label: String, value: Int)]
    var value: Int?
    var onSelect: (Int) -> Void

    private let nut: CGFloat = 30

    var body: some View {
        VStack(spacing: 3) {
            if let title {
                Engraved(title, size: 11, heavy: true).frame(height: 15)
            }
            legend(0)
            HStack(spacing: 4) {
                Color.clear.frame(width: middleLabel == nil ? 0 : middleWidth, height: 1)
                toggle
                if let m = middleLabel {
                    legendText(m.label, value: m.value).frame(width: middleWidth, alignment: .leading)
                }
            }
            legend(positions.count - 1)
        }
    }

    private var middleLabel: (label: String, value: Int)? { positions.count == 3 ? positions[1] : nil }
    private var middleWidth: CGFloat { 34 }

    private func legend(_ i: Int) -> some View {
        legendText(positions[i].label, value: positions[i].value)
    }

    private func legendText(_ s: String, value v: Int) -> some View {
        Text(s).font(Cockpit.label(11, heavy: value == v))
            .foregroundColor(value == v ? Cockpit.engraving : Cockpit.engraving.opacity(0.72))
            .fixedSize()
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .onTapGesture { select(v) }
    }

    private var index: Int? { positions.firstIndex { $0.value == value } }

    private var toggle: some View {
        // Lever direction: up, towards the viewer (middle), or down.
        let dir: CGFloat = {
            guard let i = index else { return 0 }
            if positions.count == 3 && i == 1 { return 0 }
            return i == 0 ? -1 : 1
        }()
        return ZStack {
            // Chrome nut.
            Circle().fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: nut, height: nut)
            Circle().fill(Color(white: 0.2)).frame(width: nut * 0.55, height: nut * 0.55)
            // Bat handle.
            if dir == 0 {
                Circle().fill(RadialGradient(colors: [Color(hex: 0x4A4E54), Color.black], center: .topLeading, startRadius: 1, endRadius: 14))
                    .frame(width: nut * 0.62, height: nut * 0.62)
            } else {
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x50555B), Color(hex: 0x0E0F10)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: nut * 0.42, height: nut * 0.95)
                    .offset(y: dir * nut * 0.42)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: dir * 2)
            }
        }
        .frame(width: nut + 6, height: nut + 20)
        .animation(.easeOut(duration: 0.12), value: value)
        .contentShape(Rectangle())
        .simultaneousGesture(TapWithLocation { p in
            let h = nut + 20
            if positions.count == 3, abs(p.y - h / 2) < h * 0.17 { select(positions[1].value) }
            else { select(p.y < h / 2 ? positions[0].value : positions[positions.count - 1].value) }
        })
    }

    private func select(_ v: Int) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onSelect(v)
    }
}

/// Grey pointer knob with legends around it (transponder and TCAS mode selectors).
struct PointerSelector: View {
    var title: String? = nil
    var positions: [(label: String, value: Int)]
    var value: Int?
    var onSelect: (Int) -> Void
    var size: CGFloat = 44

    private var sweep: Double { positions.count > 3 ? 120 : 90 }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                ForEach(positions.indices, id: \.self) { i in
                    let p = positions[i]
                    let a = angle(i) * .pi / 180
                    Text(p.label)
                        .font(Cockpit.label(11, heavy: value == p.value))
                        .foregroundColor(value == p.value ? Cockpit.engraving : Cockpit.engraving.opacity(0.72))
                        .fixedSize()
                        .offset(x: sin(a) * (size * 0.5 + 20), y: -cos(a) * (size * 0.5 + 12))
                        .onTapGesture { select(p.value) }
                }
                ZStack {
                    Circle().fill(RadialGradient(colors: [Color(white: 0.86), Color(white: 0.5)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: size))
                    Capsule().fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: size * 0.28, height: size * 0.95)
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                    Rectangle().fill(Color.black).frame(width: 2, height: size * 0.36).offset(y: -size * 0.26)
                }
                .frame(width: size, height: size)
                .rotationEffect(.degrees(index.map(angle) ?? 0))
                .animation(.easeOut(duration: 0.15), value: value)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                .onTapGesture { select(positions[((index ?? -1) + 1) % positions.count].value) }
            }
            .frame(width: size + 84, height: size + 40)
            if let title { Engraved(title, size: 11, heavy: true) }
        }
    }

    private var index: Int? { positions.firstIndex { $0.value == value } }

    private func angle(_ i: Int) -> Double {
        guard positions.count > 1 else { return 0 }
        return -sweep / 2 + sweep * Double(i) / Double(positions.count - 1)
    }

    private func select(_ v: Int) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onSelect(v)
    }
}
