import SwiftUI

/// Bottom toolbar. Left/centre tools depend on the module; the right pill switches modules
/// (Charts / Map / Annotate), the selected one filled blue as in mPilot.
struct BottomToolbar: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    var chartNav: ChartNavigation?
    @State private var showTaxi = false
    @State private var showText = false
    @Namespace private var moduleSelection
    @Namespace private var chartSelection

    var body: some View {
        HStack(spacing: 12) {
            switch app.module {
            case .map: mapLeft
            case .charts: chartsLeft
            case .aircraft: EmptyView()
            }
            Spacer()
            switch app.module {
            case .map: mapTools
            case .charts: chartTools
            case .aircraft: EmptyView()
            }
            Spacer()
            PillGroup {
                PillIcon(systemName: "doc", selected: app.module == .charts, selectionNamespace: moduleSelection) {
                    if app.chartsAirport == nil { app.chartsAirport = app.ofp?.origin.icao }
                    app.module = .charts
                }
                PillIcon(systemName: "map", selected: app.module == .map, selectionNamespace: moduleSelection) { app.module = .map }
                PillIcon(systemName: "airplane", selected: app.module == .aircraft, selectionNamespace: moduleSelection) { app.module = .aircraft }
                PillIcon(systemName: "pencil.tip", selected: app.annotating) {
                    if app.module != .charts {
                        if app.chartsAirport == nil { app.chartsAirport = app.ofp?.origin.icao }
                        app.module = .charts
                    }
                    app.annotating.toggle()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.bar)
        .animation(Motion.layout, value: app.module)
    }

    private var mapLeft: some View {
        HStack(spacing: 0) {
            segment("Low", selected: !app.enrouteHigh) { app.enrouteHigh = false }
            segment("High", selected: app.enrouteHigh) { app.enrouteHigh = true }
        }
        .padding(3)
        .background(Capsule().fill(theme.pill))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.snappy, action) } label: {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(theme.text)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Group {
                    if selected { Capsule().fill(theme.pillStrong).matchedGeometryEffect(id: "chart", in: chartSelection) }
                })
        }
        .buttonStyle(.pressable)
    }

    private var mapTools: some View {
        PillGroup {
            Button { withAnimation(Motion.layout) { app.showVerticalProfile.toggle() } } label: {
                MountainIcon()
                    .stroke(app.showVerticalProfile ? Color.white : theme.text, lineWidth: 1.6)
                    .frame(width: 20, height: 14)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(app.showVerticalProfile ? Theme.selectedBlue : Color.clear))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Vertical profile")
            PillIcon(systemName: "arrow.triangle.turn.up.right.diamond", selected: !app.taxiRoute.isEmpty) { showTaxi = true }
                .popover(isPresented: $showTaxi) { TaxiRoutePanel().environmentObject(app) }
                .accessibilityLabel("Taxi route")
            PillIcon(systemName: "info.circle") { app.showOfp = true }
            PillIcon(systemName: "textformat.size", selected: showText) { showText = true }
                .accessibilityLabel("Map text size")
                .popover(isPresented: $showText) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Map text").font(.headline)
                        Picker("Map text size", selection: $app.mapTextSize) {
                            ForEach(MapTextSize.allCases) { Text($0.shortTitle).tag($0) }
                        }.pickerStyle(.segmented)
                        Text("EGSS  CLN  D 114.55").font(.system(size: 16 * app.mapTextSize.scale))
                            .animation(Motion.snappy, value: app.mapTextSize)
                    }.padding().frame(width: 300).themed(theme)
                }
            PillIcon(systemName: "ruler", selected: app.rulerActive) {
                withAnimation(Motion.bouncy) { app.rulerActive.toggle() }
            }.accessibilityLabel(app.rulerActive ? "Close ruler" : "Measure distance and bearing")
        }
    }

    @ViewBuilder private var chartsLeft: some View {
        if let nav = chartNav {
            PillGroup {
                PillIcon(systemName: "arrow.left") { nav.previous() }.disabled(!nav.hasPrevious)
                Rectangle().fill(theme.separator).frame(width: 1, height: 18)
                Text(nav.currentType ?? "–")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.text)
                    .padding(.horizontal, 6)
                    .crossfadeOnChange(of: nav.currentType ?? "–")
                PillIcon(systemName: "arrow.right") { nav.next() }.disabled(!nav.hasNext)
            }
        } else {
            EmptyView()
        }
    }

    private var chartTools: some View {
        PillGroup {
            PillIcon(systemName: "info.circle") { app.showOfp = true }
            PillIcon(systemName: app.night ? "moon.fill" : "sun.max") { app.toggleNight() }
            PillIcon(systemName: "rectangle.split.2x1", selected: app.splitView) { app.splitView.toggle() }
        }
    }
}

/// Previous/next chart navigation exposed by the charts module to the toolbar.
struct ChartNavigation {
    var currentType: String?
    var hasPrevious: Bool
    var hasNext: Bool
    var previous: () -> Void
    var next: () -> Void
}

/// Two-peak mountain glyph used for the vertical profile button (SF Symbols' mountain needs iOS 16).
struct MountainIcon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.35, y: r.minY + r.height * 0.15))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.3))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
