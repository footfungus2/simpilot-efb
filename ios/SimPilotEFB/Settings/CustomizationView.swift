import SwiftUI

/// Settings → Customization: theme, accent colour, animations, how the map and charts look, and what opens at launch.
struct CustomizationView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section(header: Text("Appearance"),
                    footer: Text("Match iPad follows Dark Mode in iPad Settings; the night/day button switches back to a fixed theme.")) {
                ThemeCards(selection: $app.themeChoice, accent: app.accent, routeColor: app.routeColor.swatchColor)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Accent colour")
                        Spacer()
                        Text(app.accent.title).foregroundColor(.secondary)
                    }
                    HStack(spacing: 12) {
                        ColorSwatches(choices: AccentChoice.allCases, selection: $app.accent)
                        Spacer(minLength: 0)
                        accentPreview
                    }
                }
                .padding(.vertical, 6)
            }

            Section(header: Text("Animations"),
                    footer: Text(reduceMotion ? "Reduce Motion is on in iPad Settings, so Full plays as Reduced."
                                              : "Reduce Motion in iPad Settings caps Full at Reduced.")) {
                Picker("Animations", selection: $app.motion) {
                    ForEach(MotionLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)
            }

            Section(header: Text("Top bar")) {
                Toggle("UTC clock instead of version number", isOn: $app.showUtcClock)
            }

            Section(header: Text("Map"), footer: Text("Text size is the same setting as the AA button on the map.")) {
                MapPreview(theme: theme, routeColor: app.routeColor.swatchColor,
                           textScale: CGFloat(app.mapTextSize.scale), graticule: app.showGraticule)
                    .animation(Motion.snappy, value: app.mapTextSize)
                    .animation(Motion.smooth, value: app.routeColor)
                    .animation(Motion.smooth, value: app.showGraticule)
                segmentedRow("Text size", selection: $app.mapTextSize, options: MapTextSize.allCases, width: 240) { $0.shortTitle }
                HStack {
                    Text("Route colour")
                    Spacer(minLength: 12)
                    ColorSwatches(choices: RouteColorChoice.allCases, selection: $app.routeColor)
                }
                Toggle("3D globe when zoomed out", isOn: $app.globeView)
                Toggle("Latitude/longitude grid", isOn: $app.showGraticule)
            }

            Section(header: Text("Charts"), footer: Text("Off keeps charts white at night, like paper.")) {
                Toggle("Dark charts in night mode", isOn: $app.invertChartsAtNight)
            }

            Section(header: Text("Startup"),
                    footer: Text("Takes effect the next time SimPilot opens; Charts starts at the flight's departure airport.")) {
                segmentedRow("Start screen", selection: $app.startModule, options: StartModule.allCases, width: 330) { $0.title }
                Toggle("Show Flight Folder at launch", isOn: $app.flightFolderAtLaunch)
            }

            Section(footer: Text("Bridge, SimBrief and map layer settings stay as they are.")) {
                Button(role: .destructive) { confirmReset = true } label: {
                    Text("Reset to defaults").frame(maxWidth: .infinity)
                }
                .disabled(app.customization == .defaults)
                .confirmationDialog("Reset customization?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset to defaults", role: .destructive) {
                        withAnimation(Motion.smooth) { app.customization = .defaults }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Theme, colours, animations and the map, chart and startup options go back to their defaults.")
                }
            }
        }
        .navigationTitle("Customization")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The module switcher pill as it looks with the chosen accent.
    private var accentPreview: some View {
        PillGroup {
            PillIcon(systemName: "doc") {}
            PillIcon(systemName: "map", selected: true) {}
            PillIcon(systemName: "airplane") {}
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Title on the left, segmented control on the right.
    private func segmentedRow<Value: Hashable & Identifiable>(_ title: String, selection: Binding<Value>, options: [Value],
                                                             width: CGFloat, label: @escaping (Value) -> String) -> some View {
        HStack(spacing: 16) {
            Text(title).accessibilityHidden(true)
            Spacer(minLength: 0)
            Picker(title, selection: selection) {
                ForEach(options) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: width)
        }
    }
}

// MARK: - Theme

/// Night / Day / Match iPad as little screen previews, like iPad Settings → Display & Brightness.
private struct ThemeCards: View {
    @Binding var selection: ThemeChoice
    let accent: AccentChoice
    let routeColor: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ThemeChoice.allCases) { choice in
                let selected = choice == selection
                Button { selection = choice } label: {
                    VStack(spacing: 9) {
                        preview(choice)
                            .frame(width: 116, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.14), lineWidth: 1))
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(accent.swatchColor, lineWidth: 2.5)
                                .opacity(selected ? 1 : 0))
                        Text(choice.title)
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .foregroundColor(.primary)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundColor(selected ? accent.swatchColor : Color.secondary.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pressableSoft)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 10)
        .animation(Motion.snappy, value: selection)
    }

    @ViewBuilder private func preview(_ choice: ThemeChoice) -> some View {
        switch choice {
        case .night:
            MiniScreen(theme: Theme(night: true, accent: accent), routeColor: routeColor)
        case .day:
            MiniScreen(theme: Theme(night: false, accent: accent), routeColor: routeColor)
        case .system:
            ZStack {
                MiniScreen(theme: Theme(night: false, accent: accent), routeColor: routeColor)
                MiniScreen(theme: Theme(night: true, accent: accent), routeColor: routeColor).clipShape(LeftHalf())
            }
        }
    }
}

/// A tiny SimPilot screen in a theme's colours: top bar, Flight Folder, map with the route, bottom bar.
private struct MiniScreen: View {
    let theme: Theme
    let routeColor: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(theme.pill).frame(width: 7, height: 7)
                Capsule().fill(theme.textSecondary.opacity(0.7)).frame(width: 16, height: 3)
                Spacer(minLength: 0)
                Capsule().fill(theme.pill).frame(width: 26, height: 7)
                Spacer(minLength: 0)
                Circle().fill(theme.pill).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 5)
            .frame(height: 13)
            .background(theme.bar)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(theme.text.opacity(0.8)).frame(width: 17, height: 3)
                    Capsule().fill(theme.textSecondary.opacity(0.6)).frame(width: 21, height: 2.5)
                    Capsule().fill(theme.textSecondary.opacity(0.6)).frame(width: 13, height: 2.5)
                    Capsule().fill(theme.pillStrong).frame(width: 21, height: 5).padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .padding(5)
                .frame(width: 32, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(theme.sidebar)
                ZStack {
                    Color(theme.mapLand)
                    MiniSea().fill(Color(theme.mapBackground))
                    MiniRoute().stroke(routeColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Circle().fill(theme.textSecondary.opacity(0.6)).frame(width: 4, height: 4)
                    Circle().fill(theme.accentColor).frame(width: 6, height: 6)
                    Circle().fill(theme.textSecondary.opacity(0.6)).frame(width: 4, height: 4)
                }
                .padding(.horizontal, 4)
                .frame(height: 8)
                .background(Capsule().fill(theme.pill))
            }
            .padding(.horizontal, 5)
            .frame(height: 12)
            .background(theme.bar)
        }
    }
}

private struct LeftHalf: Shape {
    func path(in r: CGRect) -> Path {
        Path(CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height))
    }
}

/// Sea in the top-right corner of the mini map.
private struct MiniSea: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var p = Path()
        p.move(to: pt(0.42, 0))
        p.addCurve(to: pt(1, 0.66), control1: pt(0.56, 0.42), control2: pt(0.80, 0.30))
        p.addLine(to: pt(1, 0))
        p.closeSubpath()
        return p
    }
}

private struct MiniRoute: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var p = Path()
        p.move(to: pt(0.16, 0.80))
        p.addLine(to: pt(0.48, 0.46))
        p.addLine(to: pt(0.86, 0.22))
        return p
    }
}

// MARK: - Colour swatches

/// 30 pt colour circles; the selected one gets a ring (which slides over to a new choice) and a checkmark.
private struct ColorSwatches<Choice: SwatchChoice>: View {
    let choices: [Choice]
    @Binding var selection: Choice
    @Namespace private var ring

    var body: some View {
        HStack(spacing: 8) {
            ForEach(choices) { choice in
                let selected = choice == selection
                Button {
                    withAnimation(Motion.snappy) { selection = choice }
                } label: {
                    ZStack {
                        if selected {
                            Circle()
                                .strokeBorder(choice.isLight ? Color.secondary : choice.swatchColor, lineWidth: 2)
                                .matchedGeometryEffect(id: "ring", in: ring)
                        }
                        Circle()
                            .fill(choice.swatchColor)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                            .frame(width: 30, height: 30)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(choice.isLight ? Color.black.opacity(0.7) : .white)
                                .transition(.pop)
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

// MARK: - Map preview

/// Live sample of the map settings — route colour, label size, grid — in the current night/day colours.
private struct MapPreview: View {
    let theme: Theme
    let routeColor: Color
    let textScale: CGFloat
    let graticule: Bool

    private struct Fix: Identifiable {
        let id: String
        let at: CGPoint // unit coordinates in the preview
        var airport = false
    }

    private static let fixes = [Fix(id: "EGSS", at: CGPoint(x: 0.15, y: 0.68), airport: true),
                                Fix(id: "CLN", at: CGPoint(x: 0.42, y: 0.42)),
                                Fix(id: "KOK", at: CGPoint(x: 0.82, y: 0.30))]

    var body: some View {
        GeometryReader { g in
            let size = g.size
            ZStack {
                Color(theme.mapBackground)
                PreviewLand().fill(Color(theme.mapLand))
                PreviewGraticule(spacing: 36).stroke(Color(theme.mapGraticule), lineWidth: 0.8).opacity(graticule ? 1 : 0)
                PreviewRoute(points: Self.fixes.map(\.at))
                    .stroke(routeColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                ForEach(Self.fixes) { fix in
                    let p = CGPoint(x: fix.at.x * size.width, y: fix.at.y * size.height)
                    symbol(fix).position(p)
                    label(fix)
                        .frame(width: 140, alignment: .leading)
                        .position(x: p.x + (fix.airport ? 12 : 11) + 70, y: p.y + (fix.airport ? 9 : 0))
                }
            }
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map preview")
    }

    @ViewBuilder private func symbol(_ fix: Fix) -> some View {
        if fix.airport {
            AirportGear().stroke(Theme.originGreen, style: StrokeStyle(lineWidth: 2.4, lineCap: .round)).frame(width: 22, height: 22)
        } else {
            ZStack {
                WaypointTriangle().fill(theme.night ? Color(hex: 0x1B1E23) : .white)
                WaypointTriangle().stroke(routeColor, lineWidth: 1.8)
            }
            .frame(width: 13, height: 12)
        }
    }

    private func label(_ fix: Fix) -> some View {
        let halo = Color(theme.mapLabelHalo)
        return Text(fix.id)
            .modifier(AnimatedFontSize(size: 12 * textScale))
            .foregroundColor(fix.airport ? Color(hex: 0x3D8BFF) : Color(theme.mapLabel))
            .fixedSize()
            .shadow(color: halo, radius: 0.8)
            .shadow(color: halo, radius: 0.8)
    }
}

/// Bold map-label font whose size animates smoothly (re-rendered every frame, so it stays sharp).
private struct AnimatedFontSize: ViewModifier, Animatable {
    var size: CGFloat
    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .bold))
    }
}

/// England on the left, the continent top right, the sea between.
private struct PreviewLand: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var p = Path()
        p.move(to: pt(0, 0))
        p.addLine(to: pt(0.30, 0))
        p.addCurve(to: pt(0.45, 0.40), control1: pt(0.36, 0.12), control2: pt(0.48, 0.24))
        p.addCurve(to: pt(0.36, 0.80), control1: pt(0.42, 0.56), control2: pt(0.33, 0.64))
        p.addCurve(to: pt(0.31, 1), control1: pt(0.39, 0.90), control2: pt(0.33, 0.95))
        p.addLine(to: pt(0, 1))
        p.closeSubpath()
        p.move(to: pt(1, 0.06))
        p.addCurve(to: pt(0.76, 0.58), control1: pt(0.86, 0.14), control2: pt(0.79, 0.36))
        p.addCurve(to: pt(0.69, 1), control1: pt(0.73, 0.78), control2: pt(0.67, 0.90))
        p.addLine(to: pt(1, 1))
        p.closeSubpath()
        return p
    }
}

private struct PreviewGraticule: Shape {
    let spacing: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = r.minX + spacing / 2
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.minY))
            p.addLine(to: CGPoint(x: x, y: r.maxY))
            x += spacing
        }
        var y = r.minY + spacing / 2
        while y < r.maxY {
            p.move(to: CGPoint(x: r.minX, y: y))
            p.addLine(to: CGPoint(x: r.maxX, y: y))
            y += spacing
        }
        return p
    }
}

private struct PreviewRoute: Shape {
    let points: [CGPoint] // unit coordinates

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addLines(points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) })
        return p
    }
}

/// The route's waypoint triangle (as `MapIcons.waypointTriangle`).
private struct WaypointTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Lido "gear" airport symbol (as `MapIcons.airport`).
private struct AirportGear: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 4
        var p = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            p.move(to: CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius))
            p.addLine(to: CGPoint(x: c.x + cos(a) * radius * 1.65, y: c.y + sin(a) * radius * 1.65))
        }
        return p
    }
}
