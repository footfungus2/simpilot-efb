import SwiftUI

/// Building blocks drawn like real Airbus cockpit hardware: panel plates, 7-segment windows, square
/// pushbuttons with annunciators, rotary knobs, overhead toggle switches and rotary selectors.
enum Cockpit {
    static let panel = Color(hex: 0x4A5561)
    static let panelDark = Color(hex: 0x3B4550)
    static let engraving = Color(white: 0.93)
    static let amber = Color(hex: 0xFF9F1A)
    static let green = Color(hex: 0x3BE26B)
    static let white = Color(hex: 0xF4F1E6)
    static let buttonFace = Color(hex: 0x2A2E33)

    static func segment(_ size: CGFloat) -> Font { .custom("DSEG7Classic-Bold", size: size) }
    static func label(_ size: CGFloat = 11, weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight) }
}

/// A grey panel plate with screws in the corners and an optional engraved title.
struct PanelPlate<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) {
            if let title {
                Text(title).font(Cockpit.label(12, weight: .heavy)).foregroundColor(Cockpit.engraving).tracking(1.5)
            }
            content
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Cockpit.panel, Cockpit.panelDark], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.55), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
        )
        .overlay(screws)
    }

    private var screws: some View {
        GeometryReader { g in
            ForEach(0..<4, id: \.self) { i in
                Screw().position(x: i % 2 == 0 ? 9 : g.size.width - 9, y: i < 2 ? 9 : g.size.height - 9)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Screw: View {
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.75), Color(white: 0.35)], center: .topLeading, startRadius: 0, endRadius: 8))
            Rectangle().fill(Color.black.opacity(0.6)).frame(width: 6, height: 1.2).rotationEffect(.degrees(35))
        }
        .frame(width: 8, height: 8)
    }
}

/// Black LCD window with amber 7-segment digits; unlit segments show faintly like the real displays.
struct SegmentDisplay: View {
    var text: String
    var ghost: String
    var size: CGFloat = 30
    var color: Color = Cockpit.amber
    var trailing: String? = nil // e.g. the managed-mode dot

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .trailing) {
                Text(ghost).foregroundColor(color.opacity(0.07))
                Text(text).foregroundColor(color).shadow(color: color.opacity(0.6), radius: 4)
            }
            .font(Cockpit.segment(size))
            .lineLimit(1)
            .fixedSize()
            if let trailing {
                Text(trailing).font(.system(size: size * 0.5, weight: .bold)).foregroundColor(color).frame(width: size * 0.4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x0B0C0D)))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black, lineWidth: 2))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.08), lineWidth: 1).padding(1))
    }
}

/// Square Airbus pushbutton: engraved legend, green/white annunciator bar when lit. Calls `action` on press.
struct AirbusButton: View {
    var label: String
    var lit = false
    var light: Color = Cockpit.green
    var width: CGFloat = 54
    var height: CGFloat = 46
    var fontSize: CGFloat? = nil
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 4) {
            Capsule().fill(lit ? light : Color.black.opacity(0.45))
                .frame(width: width * 0.55, height: 4)
                .shadow(color: lit ? light : .clear, radius: 4)
            Text(label).font(Cockpit.label(fontSize ?? (label.count > 5 ? 9 : 11))).foregroundColor(Cockpit.white)
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(hex: 0x3A3F45), Cockpit.buttonFace], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(pressed ? 0.2 : 0.7), radius: pressed ? 1 : 3, y: pressed ? 0 : 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.8), lineWidth: 1))
        .scaleEffect(pressed ? 0.96 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            pressed = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

/// Rotary knob: drag around it (or up/down) to turn, tap the left/right half for one step.
/// With `inner`, the centre cap is a second concentric knob (RMP frequency selector).
struct RotaryKnob: View {
    var size: CGFloat = 70
    var onStep: (Int) -> Void
    var inner: ((Int) -> Void)? = nil
    var caption: String? = nil

    @State private var outerAngle: Double = 0
    @State private var innerAngle: Double = 0
    @State private var lastAngle: Double?
    @State private var accumulated: Double = 0
    @State private var draggingInner = false

    private let degreesPerStep = 24.0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                knob(diameter: size, angle: outerAngle, ridges: 18)
                if inner != nil {
                    knob(diameter: size * 0.56, angle: innerAngle, ridges: 12)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(drag)
            .simultaneousGesture(SpatialTapGestureCompat { location in
                let center = CGPoint(x: size / 2, y: size / 2)
                let isInner = inner != nil && hypot(location.x - center.x, location.y - center.y) < size * 0.28
                step(location.x < center.x ? -1 : 1, inner: isInner)
            })
            if let caption {
                Text(caption).font(Cockpit.label(9, weight: .heavy)).foregroundColor(Cockpit.engraving)
            }
        }
    }

    private func knob(diameter: CGFloat, angle: Double, ridges: Int) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0x50565D), Color(hex: 0x16181B)], center: .topLeading, startRadius: 2, endRadius: diameter))
            ForEach(0..<ridges, id: \.self) { i in
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: 2, height: diameter * 0.12)
                    .offset(y: -diameter * 0.44).rotationEffect(.degrees(Double(i) / Double(ridges) * 360))
            }
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 2.5, height: diameter * 0.2).offset(y: -diameter * 0.28)
        }
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(angle))
        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let c = CGPoint(x: size / 2, y: size / 2)
                if lastAngle == nil {
                    draggingInner = inner != nil && hypot(v.startLocation.x - c.x, v.startLocation.y - c.y) < size * 0.28
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
private struct SpatialTapGestureCompat: Gesture {
    var action: (CGPoint) -> Void
    init(_ action: @escaping (CGPoint) -> Void) { self.action = action }

    var body: some Gesture {
        DragGesture(minimumDistance: 0).onEnded { v in
            if hypot(v.translation.width, v.translation.height) < 4 { action(v.location) }
        }
    }
}

/// Overhead toggle switch: positions top to bottom; tap a legend to move the lever there.
struct ToggleSwitch: View {
    var title: String
    var positions: [(label: String, value: Int)]
    var value: Int?
    var onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(Cockpit.label(10, weight: .heavy)).foregroundColor(Cockpit.engraving)
                .multilineTextAlignment(.center).frame(height: 26, alignment: .bottom)
            HStack(spacing: 8) {
                lever
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(positions.indices, id: \.self) { i in
                        let p = positions[i]
                        Text(p.label)
                            .font(Cockpit.label(10, weight: value == p.value ? .heavy : .semibold))
                            .foregroundColor(value == p.value ? Cockpit.white : Cockpit.engraving.opacity(0.65))
                            .frame(height: rowHeight, alignment: .center)
                            .frame(minWidth: 40, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { select(p.value) }
                    }
                }
            }
        }
        .frame(minWidth: 82)
    }

    private var rowHeight: CGFloat { 26 }

    private var lever: some View {
        let idx = positions.firstIndex { $0.value == value }
        let count = CGFloat(positions.count)
        let h = rowHeight * count
        let y = idx.map { CGFloat($0) * rowHeight + rowHeight / 2 } ?? h / 2
        return ZStack(alignment: .top) {
            Capsule().fill(Color.black.opacity(0.55)).frame(width: 12, height: h)
            Circle().fill(RadialGradient(colors: [Color(white: 0.95), Color(white: 0.55)], center: .topLeading, startRadius: 1, endRadius: 16))
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
                .offset(y: y - 10)
                .animation(.easeOut(duration: 0.15), value: value)
        }
        .frame(width: 22, height: h)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the lever steps it to the next position, like flicking a switch.
            let next = ((idx ?? -1) + 1) % positions.count
            select(positions[next].value)
        }
    }

    private func select(_ v: Int) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onSelect(v)
    }
}

/// Rotary selector with a pointer and legends around it (transponder/TCAS mode knobs).
struct RotarySelector: View {
    var title: String
    var positions: [(label: String, value: Int)]
    var value: Int?
    var onSelect: (Int) -> Void
    var size: CGFloat = 58

    private var sweep: Double { positions.count > 3 ? 120 : 90 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                ForEach(positions.indices, id: \.self) { i in
                    let p = positions[i]
                    let a = angle(i)
                    Text(p.label)
                        .font(Cockpit.label(9, weight: value == p.value ? .heavy : .semibold))
                        .foregroundColor(value == p.value ? Cockpit.white : Cockpit.engraving.opacity(0.65))
                        .fixedSize()
                        .offset(x: sin(a * .pi / 180) * (size * 0.5 + 18), y: -cos(a * .pi / 180) * (size * 0.5 + 12))
                        .onTapGesture { select(p.value) }
                }
                ZStack {
                    Circle().fill(RadialGradient(colors: [Color(hex: 0x50565D), Color(hex: 0x16181B)], center: .topLeading, startRadius: 2, endRadius: size))
                    Capsule().fill(Color(hex: 0x24282C)).frame(width: size * 0.26, height: size * 0.92)
                    Rectangle().fill(Color.white).frame(width: 2.5, height: size * 0.3).offset(y: -size * 0.3)
                }
                .frame(width: size, height: size)
                .rotationEffect(.degrees(positions.firstIndex { $0.value == value }.map(angle) ?? 0))
                .animation(.easeOut(duration: 0.15), value: value)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                .onTapGesture {
                    let idx = positions.firstIndex { $0.value == value } ?? -1
                    select(positions[(idx + 1) % positions.count].value)
                }
            }
            .frame(width: size + 70, height: size + 44)
            Text(title).font(Cockpit.label(10, weight: .heavy)).foregroundColor(Cockpit.engraving)
        }
    }

    private func angle(_ i: Int) -> Double {
        guard positions.count > 1 else { return 0 }
        return -sweep / 2 + sweep * Double(i) / Double(positions.count - 1)
    }

    private func select(_ v: Int) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onSelect(v)
    }
}
