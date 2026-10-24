import SwiftUI

/// The mPilot top bar: menu + cycle title, centre tool pill, aircraft pill, search and sync status.
struct TopBar: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme
    @State private var showSearch = false
    @State private var showHelp = false
    @State private var showBriefing = false

    var body: some View {
        HStack(spacing: 12) {
            RoundIconButton(systemName: "line.3.horizontal") {
                withAnimation(Motion.layout) { app.sidebarVisible.toggle() }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer(minLength: 8)

            PillGroup {
                WeatherTimeMenu()
                PillIcon(systemName: "questionmark.circle") { showHelp = true }
                PillIcon(systemName: app.night ? "moon.zzz" : "sun.max") { app.toggleNight() }
                    .accessibilityLabel("Day or night appearance")
                PillIcon(systemName: "character.bubble") { showBriefing = true }
                    .accessibilityLabel("ATIS and weather")
                    .popover(isPresented: $showBriefing) {
                        WeatherBriefingView(vatsim: app.vatsim).environmentObject(app).themed(theme)
                    }
                if app.showUtcClock {
                    TimelineView(.everyMinute) { context in
                        Text(WeatherDecoder.clock(context.date))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(theme.text)
                            .padding(.horizontal, 6)
                            .accessibilityLabel("UTC time \(WeatherDecoder.clock(context.date))")
                    }
                } else {
                    Text("v \(Bundle.main.shortVersion)")
                        .font(.system(size: 9))
                        .foregroundColor(theme.textSecondary)
                        .padding(.horizontal, 6)
                }
            }

            Spacer(minLength: 8)

            PillGroup {
                Text(aircraftLabel)
                    .font(.system(size: 15))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                    .padding(.leading, 8)
                PillIcon(systemName: "airplane") { app.showSettings = true }
            }
            .frame(maxWidth: 260)

            RoundIconButton(systemName: "magnifyingglass") { showSearch = true }
            SyncStatusButton()
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(theme.bar)
        .transaction {
            // Keep the header static when an ancestor animates layout.
            $0.animation = nil
            $0.disablesAnimations = true
        }
        .sheet(isPresented: $showSearch) { AirportSearchSheet().environmentObject(app).themed(theme) }
        .sheet(isPresented: $showHelp) { HelpSheet().themed(theme) }
    }

    private var title: String {
        if app.module == .charts, let icao = app.chartsAirport { return "\(icao): \(app.cycleTitle.replacingOccurrences(of: "Cycle: ", with: ""))" }
        return app.cycleTitle
    }

    private var subtitle: String {
        app.ofp == nil ? "Route not saved" : app.routeSubtitle
    }

    private var aircraftLabel: String {
        if let title = bridge.status?.sim.aircraftTitle, !title.isEmpty { return title.uppercased() }
        if let name = app.ofp?.aircraft.name, !name.isEmpty { return name.uppercased() }
        return "NO AIRCRAFT"
    }
}

/// The `+00:00` pill (mPilot's weather time): weather layers and the ATIS & weather briefing show the forecast for
/// now plus this many hours. Each row shows the resulting UTC time; the pill turns accent-coloured while offset.
private struct WeatherTimeMenu: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        // Rebuilt every minute so the rows' UTC times stay current.
        TimelineView(.everyMinute) { context in
            Menu {
                Section(header: Text("Weather time (UTC)")) {
                    Picker("Weather time", selection: offset) {
                        ForEach(0...12, id: \.self) { h in
                            Text(h == 0 ? "+00:00   Now" : "\(Self.offset(h))   \(WeatherDecoder.time(context.date.addingTimeInterval(Double(h) * 3600), context.date))")
                                .tag(h)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.system(size: 16))
                    Text(Self.offset(app.wxOffsetHours)).font(.system(size: 15)).monospacedDigit()
                }
                .foregroundColor(app.wxOffsetHours > 0 ? theme.accentColor : theme.text)
                .padding(.horizontal, 6)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(app.wxOffsetHours == 0 ? "Weather time: now"
                                : "Weather time: plus \(app.wxOffsetHours) hours, \(WeatherDecoder.time(context.date.addingTimeInterval(Double(app.wxOffsetHours) * 3600), context.date))")
        }
    }

    private var offset: Binding<Int> {
        Binding(get: { app.wxOffsetHours }, set: { app.wxOffsetHours = $0 })
    }

    private static func offset(_ hours: Int) -> String { String(format: "+%02d:00", hours) }
}

/// Green ✓ when the sim and in-sim link are both connected; orange when only partly; grey when offline.
struct SyncStatusButton: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme

    var body: some View {
        Button { app.showSettings = true } label: {
            ZStack {
                Circle().fill(theme.pill).frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(color)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private var level: Int {
        guard bridge.isConnected, let s = bridge.status else { return 0 }
        return s.sim.connected && s.link.connected ? 2 : 1
    }

    private var symbol: String { level == 0 ? "wifi.exclamationmark" : level == 1 ? "exclamationmark.circle.fill" : "checkmark.circle.fill" }
    private var color: Color { level == 0 ? theme.textSecondary : level == 1 ? Theme.warnOrange : Theme.okGreen }
    private var accessibility: String {
        switch level {
        case 0: return "Bridge not connected"
        case 1: return "Bridge connected, sim or link missing"
        default: return "All connected"
        }
    }
}

struct AirportSearchSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.theme) private var theme
    @State private var query = ""

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("Opens the Lido charts for an airport. The SimPilot Link panel must be open in the sim the first time an airport is loaded.")) {
                    TextField("ICAO code, e.g. EDDF", text: $query)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .onSubmit(open)
                }
                if !app.flightAirports.isEmpty {
                    Section(header: Text("This flight")) {
                        ForEach(app.flightAirports, id: \.icao) { apt in
                            Button { query = apt.icao; open() } label: {
                                HStack {
                                    Text(apt.icao).font(.system(size: 17, weight: .semibold))
                                    Text(apt.name).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { presentationMode.wrappedValue.dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Open", action: open).disabled(icao == nil) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var icao: String? {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        return q.range(of: "^[A-Z0-9]{4}$", options: .regularExpression) != nil ? q : nil
    }

    private func open() {
        guard let icao else { return }
        app.openCharts(icao)
        presentationMode.wrappedValue.dismiss()
    }
}

struct HelpSheet: View {
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Getting connected")) {
                    Text("1. On the PC, open github.com/footfungus2/simpilot-efb/releases. Download SimPilot-for-PC.zip, choose Extract All, open SimPilot for PC and double-click SimPilot Bridge. Leave its window open.")
                    Text("2. Allow Private networks in the Windows firewall prompt; it may call the app Node.js JavaScript Runtime. Keep both devices on the same local network, by Wi-Fi or Ethernet. Allow SimPilot EFB to find local devices on the iPad.")
                    Text("3. Optional, for charts: install the free MSFS 2024 SDK as explained in Read me.txt. Close MSFS, open Chart panel (optional) and run Install SimPilot Link. Start MSFS again and open SimPilot Link from its toolbar once per flight.")
                    Text("If discovery fails, enter the PC's Wi-Fi or Ethernet address in Settings → Bridge. Settings → Help → Diagnostics shows which connection is missing.")
                }
                Section(header: Text("Not connecting?")) {
                    Text("Windows: Settings → Network & internet → your home Wi-Fi or Ethernet network → Private. If you cancelled the firewall prompt, open Windows Security → Firewall & network protection → Allow an app through firewall, then allow Node.js JavaScript Runtime on Private networks.")
                    Text("iPad: Settings → Privacy → Local Network → SimPilot EFB on. Avoid guest networks. If selecting text pauses the PC bridge window, press Esc to resume.")
                }
                Section(header: Text("Status icon")) {
                    Label("Bridge, sim and link connected", systemImage: "checkmark.circle.fill").foregroundColor(Theme.okGreen)
                    Label("Bridge connected, sim or link missing", systemImage: "exclamationmark.circle.fill").foregroundColor(Theme.warnOrange)
                    Label("Bridge not found", systemImage: "wifi.exclamationmark")
                }
                Section(header: Text("Top bar")) {
                    Label("Menu opens the Flight Folder.", systemImage: "line.3.horizontal")
                    Label("+00:00 selects the weather time, up to 12 hours ahead using TAF forecasts.", systemImage: "calendar")
                    Label("Help explains the controls and connection steps.", systemImage: "questionmark.circle")
                    Label("Sun/moon switches appearance; Match iPad is in Customization.", systemImage: "moon")
                    Label("ATIS & weather opens airport reports, with a Decoded switch.", systemImage: "character.bubble")
                    Label("The version number can be replaced with a UTC clock in Customization.", systemImage: "clock")
                    Label("Aircraft opens Settings; search opens an airport's charts.", systemImage: "airplane")
                }
                Section(header: Text("Map layers")) {
                    Text("NAV filters the route, airports, FIR boundaries, navaids and frequency labels.")
                    Text("CMPY shows VATSIM flights of your airline; enter a three-letter code or use your SimBrief callsign.")
                    Text("WX enables METAR/TAF indicators and SIGMETs. Its panel shows update status, retry and a color legend.")
                    Text("VATSIM controls traffic and ATC layers. The FL box chooses the altitude used for sector ownership.")
                }
                Section(header: Text("Bottom toolbar")) {
                    Text("Low/High changes the flight-level choices and map detail. High hides NDBs and small airfields.")
                    Label("Vertical profile opens the planned climb, cruise and descent.", systemImage: "chart.bar")
                    Label("Taxi route highlights the taxiways you select.", systemImage: "arrow.triangle.turn.up.right.diamond")
                    Label("Flight info opens your OFP.", systemImage: "info.circle")
                    Label("AA changes map text size, also available in Customization.", systemImage: "textformat.size")
                    Label("Ruler measures distance and bearing: tap two points; a third starts again. From aircraft follows your position.", systemImage: "ruler")
                    Text("In Charts: arrows change chart, sun/moon changes appearance, split view shows the map alongside, and the pencil enables finger annotations. Apple Pencil always draws.")
                    Text("The right-hand icons switch Charts, Map and Aircraft. Pin a chart in ★ FLIGHT to keep it offline, or choose Show on map on a georeferenced page.")
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presentationMode.wrappedValue.dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
