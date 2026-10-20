import SwiftUI

struct EnrouteMapScreen: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient

    var body: some View {
        EnrouteMapContent(ownshipStore: bridge.ownship, vatsim: app.vatsim)
    }
}

private struct EnrouteMapContent: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme
    @ObservedObject var ownshipStore: OwnshipStore
    @ObservedObject var vatsim: VatsimStore
    @State private var wxVisible = false
    @State private var recenterToken = 0
    @State private var selectedFl: Int?

    var body: some View {
        ZStack {
            EnrouteMapView(night: app.night,
                           ofp: app.ofp,
                           ownship: ownshipStore.ownship,
                           follow: $app.followOwnship,
                           mapFilters: app.mapFilters,
                           wxVisible: wxVisible,
                           recenterToken: recenterToken,
                           bridge: bridge,
                           vatsimVisible: vatsim.enabled,
                           vatsimVersion: vatsim.version,
                           vatsimData: vatsim.geojson,
                           vatsimFocus: vatsim.focus,
                           vatsimFocusToken: vatsim.focusToken,
                           onVatsimTap: { vatsim.selection = $0 },
                           chartOverlay: app.chartOverlay,
                           chartOverlayOpacity: app.chartOverlayOpacity,
                           onAirportData: { icao, feats in app.setAirportData(icao: icao, features: feats) },
                           taxiRoute: app.taxiRoute,
                           taxiRouteAirport: app.taxiRouteAirport,
                           activeRunwayRefs: app.runwayStatus(ownshipStore.ownship)?.activeRefs ?? [],
                           onMapTap: { app.mapPick = $0 })
                .edgesIgnoringSafeArea(.all)

            if let status = app.runwayStatus(ownshipStore.ownship) {
                VStack {
                    RunwayBanner(status: status).padding(.top, 14)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            Color.clear
                .onAppear { vatsim.myAirports = Set(app.flightAirports.map(\.icao)) }
                .onChange(of: app.ofp?.fetchedAt) { _ in vatsim.myAirports = Set(app.flightAirports.map(\.icao)) }
                // Sector ownership is per altitude band: show it at the level picked in the FL box.
                .onChange(of: selectedFl) { fl in vatsim.displayLevel = fl ?? flightLevels[1] }
                .onChange(of: app.ofp?.cruiseFl) { _ in vatsim.displayLevel = selectedFl ?? flightLevels[1] }

            if let overlay = app.chartOverlay {
                VStack {
                    Spacer()
                    ChartOverlayChip(title: overlay.title, opacity: $app.chartOverlayOpacity) { app.chartOverlay = nil }
                        .padding(.bottom, app.showVerticalProfile && app.ofp != nil ? 240 : 16)
                }
            }

            // Top-left: flight progress (when flying the loaded route), then any VATSIM info card under it.
            VStack(alignment: .leading, spacing: 10) {
                if let ofp = app.ofp, let o = ownshipStore.ownship, let progress = RouteProgress(ofp: ofp, ownship: o) {
                    FlightProgressStrip(progress: progress)
                }
                if let pick = app.mapPick {
                    WaypointInfoCard(pick: pick, ownship: ownshipStore.ownship) { app.mapPick = nil }
                }
                if vatsim.enabled, let selection = vatsim.selection {
                    VatsimInfoCard(store: vatsim, selection: selection)
                }
                Spacer()
            }
            .padding(.top, 12)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .trailing, spacing: 8) {
                LayerBox(filters: $app.mapFilters, wxVisible: $wxVisible, vatsim: vatsim)
                FlightLevelSelector(levels: flightLevels, selected: $selectedFl)
                Spacer()
                Button {
                    app.followOwnship = true
                    recenterToken += 1
                } label: {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 20))
                        .rotationEffect(.degrees(45))
                        .foregroundColor(app.followOwnship ? Theme.ownshipBlue : theme.text)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.overlay))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.bottom, app.showVerticalProfile && app.ofp != nil ? 230 : 0)

            if app.showVerticalProfile, let ofp = app.ofp {
                VStack {
                    Spacer()
                    VerticalProfileView(ofp: ofp, ownship: ownshipStore.ownship)
                        .frame(height: 220)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    /// Three levels around the planned cruise level, like the FL box on the mPilot map.
    private var flightLevels: [Int] {
        let cruise = app.ofp?.cruiseFl ?? 350
        return [cruise + 30, cruise, cruise - 60].map { $0 - $0 % 10 }
    }
}

/// NAV / CMPY / WX layer switches in the top-right corner.
struct LayerBox: View {
    @Environment(\.theme) private var theme
    @Binding var filters: MapFilters
    @Binding var wxVisible: Bool
    @ObservedObject var vatsim: VatsimStore
    @State private var showNav = false
    @State private var showVatsim = false
    @State private var showWx = false

    var body: some View {
        HStack(spacing: 0) {
            cell(title: "NAV", count: filters.activeCount, icon: true) { showNav = true }
                .popover(isPresented: $showNav) { NavFilterPanel(filters: $filters) }
            divider
            cell(title: "CMPY", count: 0, icon: true) {}
                .opacity(0.5)
            divider
            cell(title: "WX", count: wxVisible ? 2 : 0, icon: false) { showWx = true }
                .popover(isPresented: $showWx) { toggles(title: "Weather", isOn: $wxVisible, label: "METAR indicators and SIGMETs") }
            divider
            Button { showVatsim = true } label: {
                VStack(spacing: 2) {
                    Text("VATSIM").font(.system(size: 8, weight: .semibold)).foregroundColor(theme.textSecondary)
                    Image(systemName: "airplane").font(.system(size: 15, weight: .semibold))
                        .foregroundColor(vatsim.enabled ? Theme.ownshipBlue : theme.text)
                }
                .frame(width: 54, height: 50)
                .overlay(
                    Text(vatsim.enabled ? (vatsim.feed.map { "\($0.pilots.count)" } ?? "…") : "off")
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(theme.text).padding(3),
                    alignment: .bottomTrailing
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showVatsim) { VatsimFilterPanel(store: vatsim) }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.overlay))
    }

    private var divider: some View { Rectangle().fill(theme.separator).frame(width: 1, height: 40) }

    private func cell(title: String, count: Int, icon: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 8, weight: .semibold)).foregroundColor(theme.textSecondary).opacity(icon ? 1 : 0)
                if icon {
                    Image(systemName: "square.3.stack.3d").font(.system(size: 16, weight: .semibold)).foregroundColor(theme.text)
                } else {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(theme.text)
                }
            }
            .frame(width: 54, height: 50)
            .overlay(
                Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundColor(theme.text).padding(4),
                alignment: .bottomTrailing
            )
        }
        .buttonStyle(.plain)
    }

    private func toggles(title: String, isOn: Binding<Bool>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Toggle(label, isOn: isOn)
        }
        .padding()
        .frame(width: 320)
    }
}

/// FL box below the layer switches; the selected level drives level-dependent weather.
struct FlightLevelSelector: View {
    @Environment(\.theme) private var theme
    let levels: [Int]
    @Binding var selected: Int?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(levels, id: \.self) { fl in
                Button { selected = fl } label: {
                    Text("FL\(fl)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor((selected ?? levels[safe: 1]) == fl ? theme.text : theme.textSecondary)
                        .frame(width: 62, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.overlay))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Controls for a chart laid over the map: title, opacity, remove.
struct ChartOverlayChip: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var opacity: Double
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext").foregroundColor(theme.textSecondary)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(theme.text).lineLimit(1)
            Slider(value: $opacity, in: 0.2...1).frame(width: 140)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.pill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove chart from map")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Capsule().fill(theme.overlay))
        .overlay(Capsule().stroke(theme.separator))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .frame(maxWidth: 520)
    }
}

/// mPilot runway awareness: dark "ON RWY 04-22" on the runway, orange "APRCH RWY 22" on final.
struct RunwayBanner: View {
    let status: RunwayAwareness.Status

    var body: some View {
        let approaching: Bool = { if case .approaching = status { return true }; return false }()
        Text(status.text)
            .font(.system(size: approaching ? 26 : 16, weight: approaching ? .regular : .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, approaching ? 30 : 16)
            .padding(.vertical, approaching ? 12 : 7)
            .background(RoundedRectangle(cornerRadius: 3).fill(approaching ? Color(hex: 0xE97C4B) : Color(hex: 0x1F3550)))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .accessibilityLabel(status.text)
    }
}

/// NAV layer filters: route, airports, FIRs and navaid types.
struct NavFilterPanel: View {
    @Binding var filters: MapFilters

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Navigation").font(.headline)
            Toggle("Route and route waypoints", isOn: $filters.route)
            Toggle("Airports", isOn: $filters.airports)
            Toggle("FIR boundaries", isOn: $filters.firs)
            Divider()
            Text("NAVAIDS").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            Toggle("VOR / VOR-DME / VORTAC", isOn: $filters.vor)
            Toggle("NDB", isOn: $filters.ndb)
            Toggle("DME / TACAN", isOn: $filters.dme)
            Toggle("Show frequencies", isOn: $filters.navaidFrequencies)
                .disabled(!(filters.vor || filters.ndb || filters.dme))
            Text("Named enroute waypoints (intersections) will come from the sim's navdata once the bridge is connected. Tap any waypoint, navaid or airport for details.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 340)
    }
}
